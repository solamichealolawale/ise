import AppKit

/// `ise` in a terminal or a Claude session. It runs inside the app's own program, so both use the same plan code.
enum CommandLineTool {
    static let showPanelNotification = Notification.Name("io.github.solamichealolawale.ise.show")

    static let usage = """
    ise                            What to do now, and bring up the panel
    ise list                       The whole day, numbered
    ise add <task> [--minutes 30] [--next] [--session <id>]
    ise add-step <step> [--to <task>] [--session <id>]
    ise done [<task or step>] [--session <id>]
    ise later <task or step>       Set it aside: not done, waits in Later
    ise reopen <task or step>      Bring back a task or step that is done or in Later
    ise undo                       Undo the last change, made here or in the panel
    ise settings [<name> <value>]
    ise json                       The plan and unfinished Claude sessions, for Claude to read
    ise save-plan <file>           Save a JSON plan for today, or for a later day (use - for standard input)
    ise open                       Bring up the panel

    A task or step can be named by words in it, or by its number from `ise list` (2 or 2.1).
    With no words, `done` finishes the task linked to --session, else the one in progress.
    """

    /// True when started with a command word. A launch from Finder or `open` passes none, so it shows the panel.
    static func isCommand(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        return !arguments[1].hasPrefix("-") || ["-h", "--help"].contains(arguments[1])
    }

    static func run(_ arguments: [String]) -> Int32 {
        let input = ParsedInput(Array(arguments.dropFirst()))
        if input.command == "hook" {
            runHook()
            return 0
        }
        do {
            print(try perform(input))
            return 0
        } catch {
            FileHandle.standardError.write(Data(((error as? LocalizedError)?.errorDescription ?? "\(error)").appending("\n").utf8))
            return 1
        }
    }

    private static func perform(_ input: ParsedInput) throws -> String {
        let settings = IseFolder.loadSettings()
        let planFile = PlanFile(settings: settings)
        switch input.command {
        case "show", "now":
            showPanel()
            return Summary.now(try planFile.todaysPlan(settings: settings), settings: settings)
        case "list":
            return Summary.list(try planFile.todaysPlan(settings: settings))
        case "add", "add-step", "done", "later", "reopen":
            return try PlanCommands(planFile: planFile, settings: settings, input: input).run()
        case "undo":
            return try planFile.undo() ? "Undid the last change." : "Nothing to undo."
        case "settings":
            return try SettingsCommand.run(input.words)
        case "json":
            return try planJSON(planFile: planFile, settings: settings)
        case "save-plan":
            return try savePlan(from: input.text, planFile: planFile, settings: settings)
        case "open":
            showPanel()
            return "Opened the panel."
        case "help", "-h", "--help":
            return usage
        default:
            throw IseError("Unknown command \"\(input.command)\".\n\n\(usage)")
        }
    }

    /// Hooks must never fail or slow a Claude session, so every problem here is ignored.
    private static func runHook() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = try? JSONDecoder().decode(HookInput.self, from: data) else { return }
        if let output = try? SessionHooks.handle(input, settings: IseFolder.loadSettings()) {
            print(output)
        }
    }

    private static func planJSON(planFile: PlanFile, settings: Settings) throws -> String {
        struct Snapshot: Encodable {
            let plan: Plan
            let sessionsWithWorkLeft: [SessionRecord]
            let settings: Settings
        }
        let plan = try planFile.todaysPlan(settings: settings)
        let linked = Set(plan.blocks.compactMap(\.sessionId))
        let sessions = SessionsFile(folder: planFile.url.deletingLastPathComponent()).load().filter { $0.hasWorkLeft && !linked.contains($0.id) }
        let data = try PlanFile.encoder.encode(Snapshot(plan: plan, sessionsWithWorkLeft: sessions, settings: settings))
        return String(decoding: data, as: UTF8.self)
    }

    /// Saves a plan for today over today's, or a plan for a later day to start that morning.
    private static func savePlan(from path: String, planFile: PlanFile, settings: Settings) throws -> String {
        guard !path.isEmpty else { throw IseError("Give a JSON file, or - to read standard input.") }
        let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: path))
        let plan: Plan
        do {
            plan = try PlanFile.decoder.decode(Plan.self, from: data)
        } catch {
            throw IseError("That is not a plan Ise can read: \(error.localizedDescription)")
        }
        guard Plan.isDayString(plan.date) else {
            throw IseError("The plan's date must look like \(Plan.dayString(Date())).")
        }
        let today = Plan.dayString(Date())
        if plan.date < today {
            throw IseError("That plan is for \(plan.date), which has passed. Use today's date, \(today), or a later one.")
        }
        if plan.date > today {
            try planFile.saveTomorrow(plan)
            return "Saved the plan for \(plan.date). It starts that morning, with anything left unfinished added after it."
        }
        if try planFile.replaceToday(with: plan, settings: settings) {
            return "Saved today's plan with \(plan.blocks.count) blocks. The old file could not be read, so it was kept as plan.unreadable.json."
        }
        return "Saved today's plan with \(plan.blocks.count) blocks. Run `ise undo` to go back."
    }

    /// Brings the panel forward if the app is running, else starts it.
    static func showPanel() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.solamichealolawale.ise").filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(showPanelNotification, object: nil, deliverImmediately: true)
            return
        }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [bundle.path]
        try? opener.run()
        opener.waitUntilExit()
    }
}

/// The command word, its free text, and any --name value options.
struct ParsedInput {
    let command: String
    let words: [String]
    let options: [String: String]
    let flags: Set<String>

    var text: String {
        words.joined(separator: " ")
    }

    private static let valueOptions: Set<String> = ["session", "minutes", "to"]

    init(_ arguments: [String]) {
        command = arguments.first ?? "show"
        var words: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let name = String(argument.drop { $0 == "-" })
            if argument.hasPrefix("--"), Self.valueOptions.contains(name), index + 1 < arguments.count {
                options[name] = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--") {
                flags.insert(name)
            } else {
                words.append(argument)
            }
            index += 1
        }
        self.words = words
        self.options = options
        self.flags = flags
    }
}
