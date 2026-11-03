import CryptoKit
import Foundation

/// Reads and writes the plan file for both the panel and the `ise` command, with a lock so they never write at once.
/// Every write keeps the plan from before it, so Undo works from either place.
final class PlanFile {
    static let planName = "plan.json"
    static let undoName = "plan.undo.json"
    static let tomorrowName = "tomorrow.json"
    /// Each one holds a full copy of the day, so only the latest few are kept.
    static let undoLimit = 20

    let url: URL
    private var undoURL: URL {
        url.deletingPathExtension().appendingPathExtension("undo.json")
    }

    private var lockURL: URL {
        url.deletingPathExtension().appendingPathExtension("lock")
    }

    init(url: URL) {
        self.url = url
    }

    /// The plan file in the folder the settings point to.
    convenience init(settings: Settings) {
        self.init(url: IseFolder.dataFolder(for: settings).appendingPathComponent(Self.planName))
    }

    func load() -> Plan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Plan.self, from: data)
    }

    /// Tomorrow's plan, made ahead of time, which becomes the plan when the day starts.
    var tomorrowURL: URL {
        url.deletingLastPathComponent().appendingPathComponent(Self.tomorrowName)
    }

    /// Today's plan. On a new day it first writes one. See `startDay`.
    func todaysPlan(settings: Settings, now: Date = Date()) throws -> Plan {
        try withLock { try lockedTodaysPlan(settings: settings, now: now) }
    }

    /// Loads, changes and saves today's plan under one lock, so two writers never lose each other's change.
    /// `edit` returns false when it changed nothing, and then nothing is written.
    @discardableResult
    func change(settings: Settings, now: Date = Date(), _ edit: (inout Plan) throws -> Bool) throws -> Plan {
        try withLock {
            var plan = try lockedTodaysPlan(settings: settings, now: now)
            if try edit(&plan) {
                try lockedSave(plan)
            }
            return plan
        }
    }

    /// Writes the plan and keeps the one it replaces for Undo.
    func save(_ plan: Plan) throws {
        try withLock { try lockedSave(plan) }
    }

    /// Replaces today's plan with a new one. The day is started first, so Undo goes back to the day as it began,
    /// including a plan made ahead for it. Any plan made ahead for today is then out of date, so it is dropped.
    /// Returns true when the old file could not be read: Undo cannot bring that back, so it is kept as plan.unreadable.json.
    @discardableResult
    func replaceToday(with plan: Plan, settings: Settings, now: Date = Date()) throws -> Bool {
        try withLock {
            let isUnreadable = load() == nil && FileManager.default.fileExists(atPath: url.path)
            if isUnreadable {
                let keptCopy = url.deletingLastPathComponent().appendingPathComponent("plan.unreadable.json")
                try? FileManager.default.removeItem(at: keptCopy)
                try FileManager.default.moveItem(at: url, to: keptCopy)
            }
            _ = try lockedTodaysPlan(settings: settings, now: now)
            try lockedSave(plan)
            if let madeAhead = loadMadeAhead(), madeAhead.date <= plan.date {
                try? FileManager.default.removeItem(at: tomorrowURL)
            }
            return isUnreadable
        }
    }

    private func loadMadeAhead() -> Plan? {
        (try? Data(contentsOf: tomorrowURL)).flatMap { try? Self.decoder.decode(Plan.self, from: $0) }
    }

    /// Keeps a plan for tomorrow, so it does not replace today's.
    func saveTomorrow(_ plan: Plan) throws {
        try withLock {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(plan).write(to: tomorrowURL, options: .atomic)
        }
    }

    private func lockedTodaysPlan(settings: Settings, now: Date) throws -> Plan {
        let today = Plan.dayString(now)
        let existing = load()
        if let existing, existing.date >= today {
            return existing
        }
        if existing == nil, FileManager.default.fileExists(atPath: url.path) {
            throw IseError("The plan file could not be read, so it was left as it is: \(url.path)\n"
                + "Fix it, delete it to start an empty day, or replace it with: ise save-plan <file>")
        }
        let plan = startDay(today, from: existing, settings: settings, now: now)
        // A new day is a fresh start: Undo must not reach back into yesterday or drop a plan made ahead.
        try write(plan)
        saveUndoHistory([])
        return plan
    }

    /// A new day's plan: the plan made ahead for it, if any, then yesterday's unfinished work when carry-over is on.
    /// With neither, an empty day. A plan made ahead for a day the Mac was not used is still used, like unfinished work,
    /// but one for a day that did get its own plan is out of date and is dropped.
    private func startDay(_ today: String, from yesterday: Plan?, settings: Settings, now: Date) -> Plan {
        let carriedOver = settings.carriesOverUnfinishedWork ? yesterday?.carriedOver(to: today, settings: settings, now: now) : nil
        guard let prepared = loadMadeAhead(), prepared.date <= today else {
            return carriedOver ?? Plan.newDay(today, settings: settings, now: now)
        }
        try? FileManager.default.removeItem(at: tomorrowURL)
        if let yesterday, prepared.date <= yesterday.date {
            return carriedOver ?? Plan.newDay(today, settings: settings, now: now)
        }
        var plan = prepared.date == today ? prepared : prepared.carriedOver(to: today, settings: settings, now: now)
        let plannedTitles = Set(plan.blocks.map(\.title))
        plan.blocks += (carriedOver?.blocks ?? []).filter { $0.fixedStart == nil && !plannedTitles.contains($0.title) }
        return plan
    }

    private func lockedSave(_ plan: Plan) throws {
        var history = loadUndoHistory()
        if let before = load() {
            let written = try write(plan)
            history.append(UndoEntry(before: before, afterHash: Self.hash(written)))
            saveUndoHistory(Array(history.suffix(Self.undoLimit)))
        } else {
            try write(plan)
        }
    }

    var canUndo: Bool {
        guard let last = loadUndoHistory().last, let current = try? Data(contentsOf: url) else { return false }
        return last.afterHash == Self.hash(current)
    }

    /// Puts back the plan from before the last change. Returns false when there is nothing to undo,
    /// including when something else, such as a morning stand-up, wrote the file since.
    @discardableResult
    func undo() throws -> Bool {
        try withLock {
            var history = loadUndoHistory()
            guard let last = history.popLast(), let current = try? Data(contentsOf: url), last.afterHash == Self.hash(current) else {
                saveUndoHistory([])
                return false
            }
            try write(last.before)
            saveUndoHistory(history)
            return true
        }
    }

    @discardableResult
    private func write(_ plan: Plan) throws -> Data {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(plan)
        try data.write(to: url, options: .atomic)
        return data
    }

    // MARK: - Undo history

    private struct UndoEntry: Codable {
        let before: Plan
        let afterHash: String
    }

    private func loadUndoHistory() -> [UndoEntry] {
        guard let data = try? Data(contentsOf: undoURL) else { return [] }
        return (try? Self.decoder.decode([UndoEntry].self, from: data)) ?? []
    }

    private func saveUndoHistory(_ history: [UndoEntry]) {
        guard let data = try? Self.encoder.encode(history) else { return }
        try? data.write(to: undoURL, options: .atomic)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func withLock<Result>(_ work: () throws -> Result) throws -> Result {
        try FileLock.run(lockURL, work)
    }

    // MARK: - Coding

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Sorted keys keep the bytes the same for the same plan, which Undo relies on to spot outside changes.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()
}
