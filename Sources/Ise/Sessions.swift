import Foundation

/// What Ise knows about one Claude session, taken from its hooks.
/// It keeps short fields only (a title, open task names, the last reply), never the conversation.
struct SessionRecord: Codable, Identifiable, Equatable {
    struct OpenTask: Codable, Equatable {
        let id: String
        let subject: String
    }

    let id: String
    var title: String?
    var folder: String?
    var machine: String
    var openTasks: [OpenTask] = []
    var lastMessage: String?
    var isWaitingOnYou = false
    var hasEnded = false
    var isDismissed = false
    var updatedAt: Date

    /// Open tasks, a question back to you, or a wait for your input mean the session stopped with work left.
    var hasWorkLeft: Bool {
        guard !isDismissed else { return false }
        let endsWithQuestion = lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") ?? false
        return !openTasks.isEmpty || isWaitingOnYou || endsWithQuestion
    }

    var displayTitle: String {
        title ?? folder.map { "Work in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "A Claude session"
    }

    var isOnThisMac: Bool {
        machine == SessionsFile.thisMachine
    }
}

/// The list of recent sessions, shared by every Claude session's hooks and the panel.
final class SessionsFile {
    static let fileName = "sessions.json"
    /// Sessions untouched this long are dropped, which keeps the file small.
    static let keepDays = 7
    static let maximumCount = 200

    let url: URL

    init(folder: URL) {
        url = folder.appendingPathComponent(Self.fileName)
    }

    func load() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? PlanFile.decoder.decode([SessionRecord].self, from: data)) ?? []
    }

    /// Changes one session's record under the lock, creating it when new, and drops old sessions.
    func update(_ sessionId: String, folder: String?, now: Date = Date(), change: (inout SessionRecord) -> Void) throws {
        try FileLock.run(url.deletingPathExtension().appendingPathExtension("lock")) {
            var records = load()
            let index = records.firstIndex { $0.id == sessionId } ?? {
                records.append(SessionRecord(id: sessionId, folder: folder, machine: Self.thisMachine, updatedAt: now))
                return records.count - 1
            }()
            change(&records[index])
            records[index].updatedAt = now
            let oldest = now.addingTimeInterval(-Double(Self.keepDays) * 24 * 60 * 60)
            records = Array(records.filter { $0.updatedAt >= oldest }.suffix(Self.maximumCount))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PlanFile.encoder.encode(records).write(to: url, options: .atomic)
        }
    }

    /// This Mac's name, so a shared list can tell which sessions can be reopened here.
    static let thisMachine: String = {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        let name = String(cString: buffer)
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }()
}

/// Holds an exclusive lock on a small file while work runs, so the panel and many Claude sessions take turns.
enum FileLock {
    static func run<Result>(_ lockURL: URL, _ work: () throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return try work() }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }
}

/// The JSON Claude Code sends a hook on standard input. Each event fills only some fields.
struct HookInput: Decodable {
    let sessionId: String
    let hookEventName: String
    let cwd: String?
    let prompt: String?
    let lastAssistantMessage: String?
    let taskId: String?
    let taskSubject: String?
    let notificationType: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case prompt
        case lastAssistantMessage = "last_assistant_message"
        case taskId = "task_id"
        case taskSubject = "task_subject"
        case notificationType = "notification_type"
    }
}

/// Turns hook events into session records, and ticks plan steps when a linked session finishes a task.
enum SessionHooks {
    static let titleLength = 80
    static let messageLength = 280

    /// Records the event. For a session start it returns the JSON that gives Claude this session's id and its block.
    static func handle(_ input: HookInput, settings: Settings, now: Date = Date()) throws -> String? {
        let folder = IseFolder.dataFolder(for: settings)
        if settings.tracksClaudeSessions {
            try SessionsFile(folder: folder).update(input.sessionId, folder: input.cwd, now: now) { apply(input, to: &$0) }
        }
        if input.hookEventName == "TaskCompleted", let subject = input.taskSubject {
            try tickLinkedStep(shortSubject(subject), sessionId: input.sessionId, planFile: PlanFile(settings: settings), settings: settings)
        }
        guard input.hookEventName == "SessionStart" else { return nil }
        return try startContext(sessionId: input.sessionId, plan: PlanFile(settings: settings).load())
    }

    private static func apply(_ input: HookInput, to record: inout SessionRecord) {
        switch input.hookEventName {
        case "UserPromptSubmit":
            record.isWaitingOnYou = false
            record.hasEnded = false
            if record.title == nil, let title = title(from: input.prompt) {
                record.title = title
            }
        case "TaskCreated":
            if let id = input.taskId, let subject = input.taskSubject {
                record.openTasks.append(.init(id: id, subject: shortSubject(subject)))
            }
        case "TaskCompleted":
            record.openTasks.removeAll { $0.id == input.taskId }
        case "Notification":
            // A permission prompt stops Claude mid-task until you answer; an idle reminder after a finished reply does not.
            if input.notificationType != "idle_prompt" {
                record.isWaitingOnYou = true
            }
        case "Stop":
            record.isWaitingOnYou = false
            record.lastMessage = input.lastAssistantMessage.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).suffix(messageLength)) }
        case "SessionEnd":
            record.hasEnded = true
        default:
            break
        }
    }

    /// The first line of the first real prompt. Slash commands and pasted tags make poor titles, so they are skipped.
    private static func title(from prompt: String?) -> String? {
        guard let line = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first,
              !line.isEmpty, !line.hasPrefix("/"), !line.hasPrefix("<") else { return nil }
        return line.count > titleLength ? String(line.prefix(titleLength - 1)) + "…" : line
    }

    /// Task names are kept short, and a step made from one has the same short text, so both sides compare alike.
    static func shortSubject(_ subject: String) -> String {
        String(subject.trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleLength))
    }

    private static func tickLinkedStep(_ subject: String, sessionId: String, planFile: PlanFile, settings: Settings) throws {
        guard planFile.load()?.blocks.contains(where: { $0.sessionId == sessionId }) == true else { return }
        try planFile.change(settings: settings) { plan in
            guard let blockIndex = plan.blocks.firstIndex(where: { $0.sessionId == sessionId }),
                  let stepIndex = plan.blocks[blockIndex].steps.firstIndex(where: {
                      $0.status != .done && $0.text.caseInsensitiveCompare(subject) == .orderedSame
                  }) else { return false }
            plan.blocks[blockIndex].steps[stepIndex].status = .done
            return true
        }
    }

    private static func startContext(sessionId: String, plan: Plan?) throws -> String {
        var context = "Ise (the user's focus panel) is installed. This Claude session's id is \(sessionId). "
            + "When the user finishes, adds or reopens a task or step for their day, run the `ise` command "
            + "(see `ise help`) and pass --session \(sessionId)."
        if let block = plan?.blocks.first(where: { $0.sessionId == sessionId }) {
            context += " This session is linked to today's block \"\(block.title)\"."
        }
        let output = ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": context]]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
