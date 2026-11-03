import AppKit
import SwiftUI

/// Claude sessions that stopped with work left. Each can be added to today, reopened, or hidden.
struct FromClaudeSection: View {
    @ObservedObject var store: PlanStore

    /// A short list keeps the panel calm; the rest wait until these are handled.
    private static let shownCount = 3

    var body: some View {
        let sessions = store.sessionsWithWorkLeft
        if !sessions.isEmpty {
            SectionHeader(title: "From Claude", count: sessions.count)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .help("Claude sessions that stopped with work left")
            ForEach(sessions.prefix(Self.shownCount)) { SessionRow(store: store, session: $0) }
            if sessions.count > Self.shownCount {
                Text("\(sessions.count - Self.shownCount) more after these")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 25)
                    .frame(minHeight: 22)
            }
        }
    }
}

struct SessionRow: View {
    @ObservedObject var store: PlanStore
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.isWaitingOnYou ? "exclamationmark.bubble" : "text.bubble")
                .font(.system(size: 11))
                .foregroundStyle(session.isWaitingOnYou ? Color.orange : Color.secondary)
                .frame(width: 15)
                .help(session.isWaitingOnYou ? "This session is waiting for your answer" : "A Claude session with work left")
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle).font(.system(size: 13)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(session.lastMessage.map { "Claude's last reply: \($0)" } ?? session.displayTitle)
            Spacer(minLength: 6)
            if session.isOnThisMac {
                SmallIconButton(symbol: "arrow.up.forward.app", label: "Open this session in Terminal") {
                    SessionOpener.open(sessionId: session.id, folder: session.folder)
                }
            }
            SmallIconButton(symbol: "plus.circle", label: "Add to today, with its open tasks as steps") { store.addToToday(session) }
            SmallIconButton(symbol: "xmark", label: "Not needed, hide it") { store.dismiss(session) }
        }
        .frame(minHeight: 30)
    }

    private var detail: String {
        var parts: [String] = []
        if !session.openTasks.isEmpty {
            parts.append(session.openTasks.count == 1 ? "1 open task" : "\(session.openTasks.count) open tasks")
        } else if session.isWaitingOnYou {
            parts.append("Waiting on you")
        } else {
            parts.append("Asked you a question")
        }
        if let folder = session.folder {
            parts.append(URL(fileURLWithPath: folder).lastPathComponent)
        }
        if !session.isOnThisMac {
            parts.append("on \(session.machine)")
        }
        return parts.joined(separator: " · ")
    }
}

/// A quiet icon button with a tooltip and a spoken label.
struct SmallIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Reopens a Claude session in Terminal, in its own folder, with the Claude command line.
enum SessionOpener {
    static func open(sessionId: String, folder: String?) {
        let directory = folder.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
        let script = "#!/bin/zsh -il\ncd \(quoted(directory)) && exec claude --resume \(quoted(sessionId))\n"
        let scriptURL = IseFolder.home.appendingPathComponent("resume.command")
        do {
            try FileManager.default.createDirectory(at: IseFolder.home, withIntermediateDirectories: true)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            NSWorkspace.shared.open(scriptURL)
        } catch {
            NSSound.beep()
        }
    }

    /// Wraps text in single quotes for the shell, so folder names with spaces or quotes are safe.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
