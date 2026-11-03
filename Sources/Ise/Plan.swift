import Foundation

enum StepStatus: String, Codable {
    case todo, done, blocked, skipped
}

struct Step: Codable {
    var text: String
    var status: StepStatus
    var blockedBy: String?
    var chaseAt: Date?

    init(text: String) {
        self.text = text
        status = .todo
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        status = try values.decodeIfPresent(StepStatus.self, forKey: .status) ?? .todo
        blockedBy = try values.decodeIfPresent(String.self, forKey: .blockedBy)
        chaseAt = try values.decodeIfPresent(Date.self, forKey: .chaseAt)
    }
}

enum BlockStatus: String, Codable {
    case todo, doing, done, waiting, skipped
}

/// One block of work. `minutes` is a length, not a clock time, so the day can reflow.
/// Only blocks with a `fixedStart` (meetings, lunch) are tied to the clock.
struct Block: Codable {
    var title: String
    var minutes: Int
    var fixedStart: String?
    var peopleWaiting: String?
    var link: String?
    var steps: [Step]
    var status: BlockStatus
    var startedAt: Date?
    var extraMinutes: Int
    var pausedAt: Date?
    var pausedSeconds: Int
    var snoozes: Int
    var blockedBy: String?
    var chaseAt: Date?
    /// The Claude session this block came from, so finishing work there ticks it here.
    var sessionId: String?
    /// The project folder of that session, used to reopen it.
    var folder: String?

    init(title: String, minutes: Int, fixedStart: String? = nil) {
        self.title = title
        self.minutes = minutes
        self.fixedStart = fixedStart
        steps = []
        status = .todo
        extraMinutes = 0
        pausedSeconds = 0
        snoozes = 0
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        minutes = try values.decode(Int.self, forKey: .minutes)
        fixedStart = try values.decodeIfPresent(String.self, forKey: .fixedStart)
        peopleWaiting = try values.decodeIfPresent(String.self, forKey: .peopleWaiting)
        link = try values.decodeIfPresent(String.self, forKey: .link)
        steps = try values.decodeIfPresent([Step].self, forKey: .steps) ?? []
        status = try values.decodeIfPresent(BlockStatus.self, forKey: .status) ?? .todo
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        extraMinutes = try values.decodeIfPresent(Int.self, forKey: .extraMinutes) ?? 0
        pausedAt = try values.decodeIfPresent(Date.self, forKey: .pausedAt)
        pausedSeconds = try values.decodeIfPresent(Int.self, forKey: .pausedSeconds) ?? 0
        snoozes = try values.decodeIfPresent(Int.self, forKey: .snoozes) ?? 0
        blockedBy = try values.decodeIfPresent(String.self, forKey: .blockedBy)
        chaseAt = try values.decodeIfPresent(Date.self, forKey: .chaseAt)
        sessionId = try values.decodeIfPresent(String.self, forKey: .sessionId)
        folder = try values.decodeIfPresent(String.self, forKey: .folder)
    }
}

/// A parked block, or a blocked step inside any block.
struct WaitingItem: Identifiable {
    let blockIndex: Int
    let stepIndex: Int?
    let title: String
    let blockedBy: String?
    let chaseAt: Date?

    var id: String { "\(blockIndex)-\(stepIndex ?? -1)" }
}

struct Plan: Codable {
    var date: String
    var link: String?
    var dayEnd: String?
    var blocks: [Block]
}
