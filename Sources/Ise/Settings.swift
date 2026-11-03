import Foundation

/// The choices made at setup, which can be changed later in the panel. Each Mac keeps its own copy.
struct Settings: Codable, Equatable {
    var dayStart = "09:00"
    var dayEnd = "17:30"
    /// Lunch start as "HH:mm", or nil for no lunch block.
    var lunch: String? = "13:00"
    var lunchMinutes = 60
    /// Each morning, start the day with yesterday's unfinished blocks.
    var carriesOverUnfinishedWork = true
    /// At day end, open the panel with what got done and what moves to tomorrow.
    var showsEndOfDayReport = false
    /// Hooks record which Claude sessions stop with work left, so it can be added to the day.
    var tracksClaudeSessions = true
    /// Keep the plan in iCloud Drive so every Mac signed in to it sees the same day.
    var syncsWithICloud = false

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        dayStart = try values.decodeIfPresent(String.self, forKey: .dayStart) ?? defaults.dayStart
        dayEnd = try values.decodeIfPresent(String.self, forKey: .dayEnd) ?? defaults.dayEnd
        lunch = try values.decodeIfPresent(String.self, forKey: .lunch)
        lunchMinutes = try values.decodeIfPresent(Int.self, forKey: .lunchMinutes) ?? defaults.lunchMinutes
        carriesOverUnfinishedWork = try values.decodeIfPresent(Bool.self, forKey: .carriesOverUnfinishedWork) ?? defaults.carriesOverUnfinishedWork
        showsEndOfDayReport = try values.decodeIfPresent(Bool.self, forKey: .showsEndOfDayReport) ?? defaults.showsEndOfDayReport
        tracksClaudeSessions = try values.decodeIfPresent(Bool.self, forKey: .tracksClaudeSessions) ?? defaults.tracksClaudeSessions
        syncsWithICloud = try values.decodeIfPresent(Bool.self, forKey: .syncsWithICloud) ?? defaults.syncsWithICloud
    }
}

/// Where Ise keeps its files. Setting ISE_HOME moves all of them, which tests use so they never touch the real plan.
enum IseFolder {
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["ISE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ise", isDirectory: true)
    }

    static var settingsURL: URL {
        home.appendingPathComponent("settings.json")
    }

    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// The folder that holds the plan: iCloud Drive when shared between Macs and it is turned on, else the home folder.
    static func dataFolder(for settings: Settings) -> URL {
        let isTesting = ProcessInfo.processInfo.environment["ISE_HOME"] != nil
        if settings.syncsWithICloud, !isTesting, FileManager.default.fileExists(atPath: iCloudDrive.path) {
            return iCloudDrive.appendingPathComponent("Ise", isDirectory: true)
        }
        return home
    }

    static func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    static func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// Moves to or from iCloud Drive.
    /// Turning sharing on keeps a plan already in iCloud Drive, so another Mac's day is never overwritten.
    /// Turning it off brings the shared plan back to this Mac, since that was the one in use.
    static func changeSync(to syncs: Bool) throws {
        var settings = loadSettings()
        let oldFolder = dataFolder(for: settings)
        settings.syncsWithICloud = syncs
        let newFolder = dataFolder(for: settings)
        guard newFolder != oldFolder else {
            if syncs, oldFolder == home {
                throw IseError("iCloud Drive is not turned on for this Mac.")
            }
            try save(settings)
            return
        }
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        for name in [PlanFile.planName, PlanFile.undoName, PlanFile.tomorrowName, SessionsFile.fileName] {
            let from = oldFolder.appendingPathComponent(name)
            let to = newFolder.appendingPathComponent(name)
            let destinationExists = FileManager.default.fileExists(atPath: to.path)
            guard FileManager.default.fileExists(atPath: from.path), !syncs || !destinationExists else { continue }
            if destinationExists {
                try FileManager.default.removeItem(at: to)
            }
            try FileManager.default.copyItem(at: from, to: to)
        }
        try save(settings)
    }
}

/// Opens Ise when you log in, through a small launch agent that opens the installed app.
enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/io.github.solamichealolawale.ise.plist")
    }

    static var isOn: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func set(_ isOn: Bool) throws {
        guard isOn else {
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        let bundle = Bundle.main.bundleURL
        let appPath = bundle.pathExtension == "app"
            ? bundle.path
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Ise.app").path
        let agent: [String: Any] = [
            "Label": "io.github.solamichealolawale.ise",
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }
}

struct IseError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
