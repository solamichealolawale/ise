import Foundation

/// The `ise` commands that change the plan: add, add-step, done, later and reopen.
struct PlanCommands {
    let planFile: PlanFile
    let settings: Settings
    let input: ParsedInput

    private var sessionId: String? {
        input.options["session"]
    }

    func run() throws -> String {
        var message = ""
        try planFile.change(settings: settings) { plan in
            switch input.command {
            case "add": message = try add(to: &plan)
            case "add-step": message = try addStep(to: &plan)
            case "done": message = try finish(in: &plan)
            case "later": message = try setAside(in: &plan)
            default: message = try reopen(in: &plan)
            }
            return true
        }
        return message
    }

    private func add(to plan: inout Plan) throws -> String {
        let title = input.text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { throw IseError("Say what the task is: ise add <task>") }
        var block = Block(title: title, minutes: max(Int(input.options["minutes"] ?? "") ?? 30, 5))
        block.sessionId = sessionId
        block.folder = sessionId == nil ? nil : FileManager.default.currentDirectoryPath
        if input.flags.contains("next") {
            let afterCurrent = plan.currentIndex(at: Date()).map { $0 + 1 } ?? 0
            plan.blocks.insert(block, at: min(afterCurrent, plan.blocks.count))
        } else {
            plan.insertByClock(block)
        }
        return "Added \"\(title)\" (\(Format.duration(block.minutes))) to today."
    }

    private func addStep(to plan: inout Plan) throws -> String {
        let text = input.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { throw IseError("Say what the step is: ise add-step <step>") }
        let blockIndex = try targetBlock(in: plan)
        plan.blocks[blockIndex].steps.append(Step(text: text))
        return "Added the step to \"\(plan.blocks[blockIndex].title)\"."
    }

    private func finish(in plan: inout Plan) throws -> String {
        let item = try input.text.isEmpty
            ? PlanItem(block: blockToFinish(in: plan), step: nil)
            : onlyMatch(in: plan) { !plan.isFinished($0) }
        if let step = item.step {
            plan.blocks[item.block].steps[step].status = .done
            return "Done: \(plan.text(of: item))."
        }
        plan.blocks[item.block].status = .done
        plan.blocks[item.block].pausedAt = nil
        return "Done: \(plan.blocks[item.block].title). \(Summary.whatIsNext(plan))"
    }

    /// Moves a task or step to Later: not done, still in the plan, and with carry-over on, moved to tomorrow if it is still there.
    private func setAside(in plan: inout Plan) throws -> String {
        guard !input.text.isEmpty else { throw IseError("Say which task or step to move to Later: ise later <words or number>") }
        let item = try onlyMatch(in: plan) { !plan.isFinished($0) && !plan.isInLater($0) }
        guard !plan.isFinished(item), !plan.isInLater(item) else {
            let state = plan.isFinished(item) ? "done" : "already in Later"
            throw IseError("\"\(plan.text(of: item))\" is \(state), so it was left as it is.")
        }
        if let step = item.step {
            plan.blocks[item.block].steps[step].status = .skipped
        } else {
            plan.blocks[item.block].status = .skipped
            plan.blocks[item.block].clearTimer()
        }
        return "Moved to Later: \(plan.text(of: item)). Bring it back with: ise reopen \(Summary.number(of: item))"
    }

    /// Brings back a task or step that is done or in Later, with a fresh timer.
    private func reopen(in plan: inout Plan) throws -> String {
        guard !input.text.isEmpty else { throw IseError("Say which task or step to reopen: ise reopen <words or number>") }
        let item = try onlyMatch(in: plan) { plan.isFinished($0) || plan.isInLater($0) }
        guard plan.isFinished(item) || plan.isInLater(item) else {
            throw IseError("\"\(plan.text(of: item))\" is not done or in Later, so there is nothing to reopen.")
        }
        if let step = item.step {
            plan.blocks[item.block].steps[step].status = .todo
        } else {
            plan.blocks[item.block].status = .todo
            plan.blocks[item.block].clearTimer()
        }
        return "Reopened: \(plan.text(of: item))."
    }

    /// With no words, `done` only ever finishes this session's own block, or without a session the one in progress,
    /// so it never ticks a block nobody named.
    private func blockToFinish(in plan: Plan) throws -> Int {
        if let sessionId {
            guard let linked = plan.blocks.firstIndex(where: { $0.sessionId == sessionId && $0.status != .done }) else {
                throw IseError("This session has no task in today's plan. Name it: ise done <words or number from ise list>")
            }
            return linked
        }
        guard let doing = plan.blocks.firstIndex(where: { $0.status == .doing }) else {
            throw IseError("Nothing is in progress. Name the task: ise done <words or number from ise list>")
        }
        return doing
    }

    /// The block named by --to, else the one linked to this Claude session, else the one in progress or up next.
    private func targetBlock(in plan: Plan) throws -> Int {
        if let words = input.options["to"] {
            return try onlyMatch(words, in: plan) { !plan.isFinished($0) }.block
        }
        if let sessionId, let linked = plan.blocks.firstIndex(where: { $0.sessionId == sessionId && $0.status != .done }) {
            return linked
        }
        guard let current = plan.currentIndex(at: Date()) else {
            throw IseError("Nothing is in progress. Say which task the step is for: ise add-step <step> --to <task>")
        }
        return current
    }

    private func onlyMatch(in plan: Plan, preferring fits: (PlanItem) -> Bool) throws -> PlanItem {
        try onlyMatch(input.text, in: plan, preferring: fits)
    }

    private func onlyMatch(_ words: String, in plan: Plan, preferring fits: (PlanItem) -> Bool) throws -> PlanItem {
        let matches = plan.find(words, preferring: fits)
        guard !matches.isEmpty else { throw IseError("Nothing in today's plan matches \"\(words)\". Run `ise list` to see it.") }
        guard matches.count == 1 else {
            let choices = matches.prefix(8).map { "  \(Summary.number(of: $0))  \(plan.text(of: $0))" }.joined(separator: "\n")
            throw IseError("\(matches.count) items match \"\(words)\". Say which by number:\n\(choices)")
        }
        return matches[0]
    }
}

/// Plain-text views of the day for the terminal and for Claude.
enum Summary {
    static func now(_ plan: Plan, settings: Settings, at date: Date = Date()) -> String {
        var lines: [String] = []
        if let index = plan.currentIndex(at: date) {
            let block = plan.blocks[index]
            lines.append("Now: \(block.title) \(timeNote(block, at: date))")
            let openSteps = block.steps.filter { $0.status == .todo }.prefix(3)
            lines += openSteps.map { "  [ ] \($0.text)" }
        } else {
            lines.append(whatIsNext(plan, at: date))
        }
        let current = plan.currentIndex(at: date)
        let next = plan.blocks.indices.filter { plan.blocks[$0].status == .todo && $0 != current }.prefix(3).map { plan.blocks[$0].title }
        if !next.isEmpty {
            lines.append("Next: \(next.joined(separator: ", "))")
        }
        let done = plan.blocks.filter { $0.status == .done }.count
        let later = plan.blocks.filter { $0.status == .skipped }.count
        if later > 0, current != nil || !next.isEmpty {
            lines.append("Later: \(later) set aside. `ise list` shows them.")
        }
        lines.append("Done: \(done) of \(plan.blocks.count).")
        return lines.joined(separator: "\n")
    }

    /// One line on what comes next. It never calls the day finished while a meeting is ahead,
    /// or while work waits in Later or on someone else.
    static func whatIsNext(_ plan: Plan, at date: Date = Date()) -> String {
        if let index = plan.currentIndex(at: date) {
            return "Next: \(plan.blocks[index].title)."
        }
        if plan.blocks.contains(where: { $0.status == .todo }) {
            return "Free until the next fixed block."
        }
        let later = plan.blocks.filter { $0.status == .skipped }.count
        if later > 0 {
            return "Only Later is left: \(later) set aside. Bring one back with ise reopen."
        }
        if plan.blocks.contains(where: { $0.status == .waiting || $0.steps.contains { $0.status == .blocked } }) {
            return "Only work waiting on someone is left."
        }
        return "That was the last one today."
    }

    static func list(_ plan: Plan) -> String {
        var lines = ["Today, \(plan.date)"]
        for (blockIndex, block) in plan.blocks.enumerated() {
            let time = block.fixedStart.map { "\($0), " } ?? ""
            lines.append("\(blockIndex + 1). \(mark(block.status)) \(block.title) (\(time)\(Format.duration(block.minutes)))")
            for (stepIndex, step) in block.steps.enumerated() {
                lines.append("   \(blockIndex + 1).\(stepIndex + 1) \(mark(step.status)) \(step.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func number(of item: PlanItem) -> String {
        item.step.map { "\(item.block + 1).\($0 + 1)" } ?? "\(item.block + 1)"
    }

    private static func timeNote(_ block: Block, at date: Date) -> String {
        guard let startedAt = block.startedAt else { return "(\(Format.duration(block.minutes)), not started)" }
        if block.pausedAt != nil {
            return "(paused)"
        }
        let end = startedAt.addingTimeInterval(Double((block.minutes + block.extraMinutes) * 60 + block.pausedSeconds))
        let minutesLeft = Int((end.timeIntervalSince(date) / 60).rounded(.up))
        return minutesLeft >= 0 ? "(\(Format.duration(minutesLeft)) left)" : "(\(Format.duration(-minutesLeft)) over)"
    }

    private static func mark(_ status: BlockStatus) -> String {
        switch status {
        case .todo: return "[ ]"
        case .doing: return "[>]"
        case .done: return "[x]"
        case .waiting: return "[w]"
        case .skipped: return "[later]"
        }
    }

    private static func mark(_ status: StepStatus) -> String {
        switch status {
        case .todo: return "[ ]"
        case .done: return "[x]"
        case .blocked: return "[w]"
        case .skipped: return "[later]"
        }
    }
}

/// `ise settings`: shows the choices, or changes one by name.
enum SettingsCommand {
    static func run(_ words: [String]) throws -> String {
        guard words.count >= 2 else { return describe(IseFolder.loadSettings()) }
        let name = words[0]
        let value = words.dropFirst().joined(separator: " ")
        if name == "sync" {
            try IseFolder.changeSync(to: try onOff(value, on: "icloud"))
            return "Plans are now kept \(value == "icloud" ? "in iCloud Drive, shared by your Macs" : "on this Mac only")."
        }
        if name == "open-at-login" {
            try LoginItem.set(try onOff(value))
            return LoginItem.isOn ? "Ise will open when you log in." : "Ise will not open at login."
        }
        var settings = IseFolder.loadSettings()
        try change(&settings, name: name, value: value)
        try IseFolder.save(settings)
        return describe(settings)
    }

    private static func change(_ settings: inout Settings, name: String, value: String) throws {
        switch name {
        case "day-start": settings.dayStart = try clock(value)
        case "day-end": settings.dayEnd = try clock(value)
        case "lunch": settings.lunch = value == "none" ? nil : try clock(value)
        case "lunch-minutes": settings.lunchMinutes = max(Int(value) ?? settings.lunchMinutes, 5)
        case "carry-over": settings.carriesOverUnfinishedWork = try onOff(value)
        case "day-report": settings.showsEndOfDayReport = try onOff(value)
        case "track-sessions": settings.tracksClaudeSessions = try onOff(value)
        default: throw IseError("Unknown setting \"\(name)\".\n\n\(describe(settings))")
        }
    }

    static func describe(_ settings: Settings) -> String {
        """
        day-start       \(settings.dayStart)
        day-end         \(settings.dayEnd)
        lunch           \(settings.lunch ?? "none")
        lunch-minutes   \(settings.lunchMinutes)
        carry-over      \(settings.carriesOverUnfinishedWork ? "on" : "off")   Each morning, bring over what is not done
        day-report      \(settings.showsEndOfDayReport ? "on" : "off")   At day end, show what got done and what moves on
        track-sessions  \(settings.tracksClaudeSessions ? "on" : "off")   Notice Claude sessions that stop with work left
        sync            \(settings.syncsWithICloud ? "icloud" : "off")   Share the plan between your Macs through iCloud Drive
        open-at-login   \(LoginItem.isOn ? "on" : "off")   Open Ise when you log in

        Change one with: ise settings <name> <value>
        """
    }

    private static func clock(_ value: String) throws -> String {
        guard let minute = Plan.minuteOfDay(value) else { throw IseError("Use a 24-hour time such as 09:00 or 17:30.") }
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private static func onOff(_ value: String, on onWord: String = "on") throws -> Bool {
        switch value {
        case onWord: return true
        case "off": return false
        default: throw IseError("Use \(onWord) or off.")
        }
    }
}
