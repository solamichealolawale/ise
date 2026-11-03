import Foundation

/// Changes to a plan that both the panel and the `ise` command make the same way.
extension Plan {
    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// True for a real "yyyy-MM-dd" date such as 2026-11-04, which can then be compared as text.
    static func isDayString(_ text: String) -> Bool {
        dayFormatter.date(from: text).map(dayString) == text
    }

    /// An empty day with lunch, for when there is no plan yet.
    static func newDay(_ date: String, settings: Settings, now: Date = Date()) -> Plan {
        var plan = Plan(date: date, dayEnd: settings.dayEnd, blocks: [])
        plan.addLunch(settings, now: now)
        return plan
    }

    /// The next day's plan: unfinished blocks keep their order and finished steps, with their timers reset.
    /// Meetings and lunch belong to their own day, so they are left behind and today's lunch is added.
    func carriedOver(to date: String, settings: Settings, now: Date = Date()) -> Plan {
        let unfinished = blocks.filter { $0.fixedStart == nil && $0.status != .done }
        var plan = Plan(date: date, link: link, dayEnd: settings.dayEnd, blocks: unfinished.map(\.resetForNewDay))
        plan.addLunch(settings, now: now)
        return plan
    }

    /// Adds lunch in clock order, unless it is already over, as on a day first opened in the afternoon.
    mutating func addLunch(_ settings: Settings, now: Date) {
        guard let lunch = settings.lunch, let lunchStart = clockTime(lunch) else { return }
        let lunchBlock = Block(title: "Lunch", minutes: settings.lunchMinutes, fixedStart: lunch)
        guard lunchStart.addingTimeInterval(Double(settings.lunchMinutes) * 60) > now else { return }
        let dayStart = clockTime(settings.dayStart) ?? now
        var running = max(dayStart, now)
        var position = blocks.count
        for (index, block) in blocks.enumerated() where block.status == .todo || block.status == .doing {
            if running >= lunchStart {
                position = index
                break
            }
            running.addTimeInterval(Double(block.minutes) * 60)
        }
        blocks.insert(lunchBlock, at: position)
    }

    /// Adds a flexible block before the first later meeting or lunch it fits ahead of, else at the end,
    /// so the list keeps reading in clock order.
    mutating func insertByClock(_ block: Block, now: Date = Date()) {
        var running = now
        for (index, existing) in blocks.enumerated() where existing.status == .todo || existing.status == .doing {
            let length = Double(existing.minutes) * 60
            guard let fixed = clockTime(existing.fixedStart) else {
                running.addTimeInterval(length)
                continue
            }
            if running.addingTimeInterval(Double(block.minutes) * 60) <= fixed {
                blocks.insert(block, at: index)
                return
            }
            running = max(running, fixed.addingTimeInterval(length))
        }
        blocks.append(block)
    }

    /// The blocks and steps a person means, by number from `ise list` ("2" or "2.1") or by words in their text.
    /// Among several matches it keeps the ones the command fits, so "done login" finds the open one
    /// and "reopen login" finds the one that is done or in Later.
    func find(_ words: String, preferring fits: (PlanItem) -> Bool) -> [PlanItem] {
        if let numbered = item(numbered: words) {
            return [numbered]
        }
        let needle = words.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let all = allItems
        let exact = all.filter { text(of: $0).lowercased() == needle }
        let matches = exact.isEmpty ? all.filter { text(of: $0).lowercased().contains(needle) } : exact
        let preferred = matches.filter(fits)
        return preferred.isEmpty ? matches : preferred
    }

    func isInLater(_ item: PlanItem) -> Bool {
        if let step = item.step {
            return blocks[item.block].steps[step].status == .skipped
        }
        return blocks[item.block].status == .skipped
    }

    func text(of item: PlanItem) -> String {
        item.step.map { blocks[item.block].steps[$0].text } ?? blocks[item.block].title
    }

    /// Only done counts as finished. Work moved to Later is still to do.
    func isFinished(_ item: PlanItem) -> Bool {
        if let step = item.step {
            return blocks[item.block].steps[step].status == .done
        }
        return blocks[item.block].status == .done
    }

    private var allItems: [PlanItem] {
        blocks.indices.flatMap { block in
            [PlanItem(block: block, step: nil)] + blocks[block].steps.indices.map { PlanItem(block: block, step: $0) }
        }
    }

    private func item(numbered text: String) -> PlanItem? {
        let parts = text.split(separator: ".").map { Int($0) }
        guard (1...2).contains(parts.count), let blockNumber = parts[0], blocks.indices.contains(blockNumber - 1) else { return nil }
        guard parts.count == 2 else { return PlanItem(block: blockNumber - 1, step: nil) }
        guard let stepNumber = parts[1], blocks[blockNumber - 1].steps.indices.contains(stepNumber - 1) else { return nil }
        return PlanItem(block: blockNumber - 1, step: stepNumber - 1)
    }

    /// The block in progress, else a meeting whose time has come, else the next flexible block.
    func currentIndex(at now: Date) -> Int? {
        if let doing = blocks.firstIndex(where: { $0.status == .doing }) {
            return doing
        }
        if let dueMeeting = blocks.firstIndex(where: { $0.status == .todo && (clockTime($0.fixedStart).map { $0 <= now } ?? false) }) {
            return dueMeeting
        }
        return blocks.firstIndex { $0.status == .todo && $0.fixedStart == nil }
    }

    /// A "HH:mm" time on this plan's day.
    func clockTime(_ hoursAndMinutes: String?) -> Date? {
        guard let hoursAndMinutes else { return nil }
        return Self.timeFormatter.date(from: "\(date) \(hoursAndMinutes)")
    }

    private static let timeFormatter = fileDateFormatter("yyyy-MM-dd HH:mm")

    /// Plan files always use Gregorian dates, whatever calendar the Mac shows, so every writer agrees on the day.
    private static func fileDateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    static func minuteOfDay(_ hoursAndMinutes: String) -> Int? {
        let parts = hoursAndMinutes.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private static let dayFormatter = fileDateFormatter("yyyy-MM-dd")
}

/// A block, or one step inside it.
struct PlanItem: Equatable {
    let block: Int
    let step: Int?
}

extension Block {
    /// Forgets when the block started, its pause, extra time and snoozes, so it starts fresh next time.
    mutating func clearTimer() {
        startedAt = nil
        extraMinutes = 0
        pausedAt = nil
        pausedSeconds = 0
        snoozes = 0
    }

    /// Work in progress or moved to Later starts the new day as to do, and so do its Later steps.
    fileprivate var resetForNewDay: Block {
        var block = self
        if block.status == .doing || block.status == .skipped {
            block.status = .todo
        }
        for index in block.steps.indices where block.steps[index].status == .skipped {
            block.steps[index].status = .todo
        }
        block.clearTimer()
        return block
    }
}
