import SwiftUI

enum Format {
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// "45 min", "1 hour", "1 hour 30 min", "2 hours".
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        guard hours > 0 else { return "\(minutes) min" }
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        return rest == 0 ? hourText : "\(hourText) \(rest) min"
    }

    /// "4:59" under an hour, "1:29:59" from an hour up, and a leading "+" once over time.
    static func countdown(_ seconds: Int) -> String {
        let value = abs(seconds)
        let text = value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value % 3600 / 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
        return seconds < 0 ? "+\(text)" : text
    }

    static func dayTitle(_ planDate: String) -> String {
        planDateFormatter.date(from: planDate).map { dayTitleFormatter.string(from: $0) } ?? planDate
    }

    private static let clockFormatter = formatter("HH:mm")
    private static let planDateFormatter: DateFormatter = {
        let gregorian = formatter("yyyy-MM-dd")
        gregorian.locale = Locale(identifier: "en_US_POSIX")
        gregorian.calendar = Calendar(identifier: .gregorian)
        return gregorian
    }()
    private static let dayTitleFormatter = formatter("EEE d MMM")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }
}

/// Rounded square by default, a circle in the card view.
struct SquareCheckbox: View {
    let status: StepStatus
    var isRound = false

    var body: some View {
        ZStack {
            shape.fill(status == .done ? Color.accentColor : .clear)
            shape.stroke(borderColor, lineWidth: 1.2).padding(0.6)
            switch status {
            case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            case .blocked: Image(systemName: "hand.raised.fill").font(.system(size: 8)).foregroundStyle(.orange)
            case .skipped: Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            case .todo: EmptyView()
            }
        }
        .frame(width: 15, height: 15)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }

    private var shape: AnyShape {
        isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var borderColor: Color {
        switch status {
        case .done: return .accentColor
        case .blocked: return .orange
        case .todo, .skipped: return Color.secondary.opacity(0.7)
        }
    }
}

struct CapsuleBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 12)).foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

struct BlockTitle: View {
    let block: Block
    var isCentered = false

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(block.title)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(isCentered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = block.link, let url = URL(string: link) {
                    Link(destination: url) { Image(systemName: "link").font(.system(size: 12)) }
                        .help("Open the ticket or pull request")
                }
                if let sessionId = block.sessionId {
                    SmallIconButton(symbol: "arrow.up.forward.app", label: "Open the Claude session this came from") {
                        SessionOpener.open(sessionId: sessionId, folder: block.folder)
                    }
                }
            }
            if let people = block.peopleWaiting {
                Text("\(people) waiting on you")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("People who need this block from you")
            }
        }
    }
}

/// Start or Done, then quiet icons for more time, snooze, blocked and skip. Blocked asks who inline.
struct BlockActions: View {
    @ObservedObject var store: PlanStore
    let block: Block
    let blockIndex: Int
    var isCentered = false
    @State private var isParking = false

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 8) {
            HStack(spacing: 6) {
                if block.status == .todo {
                    Button { store.start(blockIndex) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Start the timer for this block")
                } else if block.pausedAt != nil {
                    Button { store.resume(blockIndex) } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Carry on with the time that was left")
                    actionIcon("checkmark", "Mark this block done") { store.finish(blockIndex) }
                } else {
                    Button { store.finish(blockIndex) } label: { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(PrimaryButtonStyle())
                        .help("Mark this block done and bring up the next one")
                    actionIcon("pause", "Pause the timer") { store.pause(blockIndex) }
                    if block.extraMinutes == 0 {
                        actionIcon("goforward.15", "Add 15 minutes, once per block") { store.extend(blockIndex) }
                    }
                }
                if store.isLoud && store.canSnooze {
                    actionIcon("bell.slash", "Quiet for 10 minutes, \(2 - block.snoozes) left") { store.snooze() }
                }
                if !isCentered {
                    Spacer()
                }
                actionIcon("hand.raised", "I'm blocked on this block") { isParking = true }
                actionIcon("arrow.down.to.line", "Later: set this block aside. It waits in Later until you bring it back") { store.moveToLater(blockIndex) }
            }
            if isParking {
                ParkField(
                    onPark: { person in
                        store.park(blockIndex, blockedBy: person)
                        isParking = false
                    },
                    onCancel: { isParking = false }
                )
            }
        }
    }

    private func actionIcon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(IconButtonStyle())
            .help(label)
            .accessibilityLabel(label)
    }
}

struct ParkField: View {
    let onPark: (String) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Waiting on who?", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { onPark(name) }
            Button("Park") { onPark(name) }
                .buttonStyle(PrimaryButtonStyle(isCompact: true))
                .help("Move it to Waiting and remind you to chase in 2 hours")
            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)
                .help("Keep it where it is")
        }
        .controlSize(.small)
        .onAppear { isFocused = true }
    }
}

struct StepList: View {
    @ObservedObject var store: PlanStore
    let block: Block
    let blockIndex: Int
    var isRound = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(block.steps.indices, id: \.self) { stepIndex in
                StepRow(store: store, step: block.steps[stepIndex], blockIndex: blockIndex, stepIndex: stepIndex, isRound: isRound)
            }
        }
    }
}

/// One step: click the box or the text for done (or to bring it back from Later), or use the menu for blocked, Later, or back to to-do.
struct StepRow: View {
    @ObservedObject var store: PlanStore
    let step: Step
    let blockIndex: Int
    let stepIndex: Int
    var isRound = false
    @State private var isParking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Button { store.toggleStepDone(stepIndex, in: blockIndex) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        SquareCheckbox(status: step.status, isRound: isRound)
                            .padding(.top, -3)
                            .padding(.horizontal, -4)
                        Text(step.text)
                            .font(.system(size: 13))
                            .strikethrough(step.status == .done)
                            .foregroundStyle(step.status == .todo ? Color.primary : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(step.status == .done ? "Mark as not done" : step.status == .skipped ? "Bring it back from Later" : "Mark as done")
                statusTag
                menu
            }
            .padding(.vertical, 4)
            .reorderable(dragText: DragText.step(stepIndex, in: blockIndex), title: step.text) {
                store.moveDraggedStep($0, to: stepIndex, in: blockIndex)
            }
            if isParking {
                ParkField(
                    onPark: { person in
                        store.blockStep(stepIndex, in: blockIndex, blockedBy: person)
                        isParking = false
                    },
                    onCancel: { isParking = false }
                )
                .padding(.leading, 25)
            }
        }
    }

    @ViewBuilder
    private var statusTag: some View {
        switch step.status {
        case .blocked:
            Label(step.blockedBy ?? "Waiting", systemImage: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
        case .skipped:
            Text("Later")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .help("Set aside for later. Click the step, or choose Back to to-do in its menu, to bring it back")
                .background(Color.primary.opacity(0.06), in: Capsule())
        case .todo, .done:
            EmptyView()
        }
    }

    private var menu: some View {
        Menu {
            Button("Done", systemImage: "checkmark") { store.setStep(stepIndex, in: blockIndex, to: .done) }
            Button("I'm blocked on this", systemImage: "hand.raised") { isParking = true }
            Button("Later", systemImage: "arrow.down.to.line") { store.setStep(stepIndex, in: blockIndex, to: .skipped) }
            if step.status != .todo {
                Divider()
                Button("Back to to-do", systemImage: "arrow.uturn.backward") { store.setStep(stepIndex, in: blockIndex, to: .todo) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Done, blocked, or later")
    }
}

/// A later block. Click its title to open its steps; click its length to change it.
struct UpNextRow: View {
    @ObservedObject var store: PlanStore
    let block: Block
    let blockIndex: Int
    let start: Date?
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Button { store.finish(blockIndex) } label: { SquareCheckbox(status: .todo) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, -4)
                    .help("Mark as done")
                Button { isOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(block.title).font(.system(size: 13)).lineLimit(1)
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Hide steps" : "Show steps")
                LengthMenu(minutes: block.minutes, onChange: { store.setMinutes($0, for: blockIndex) }) {
                    Text(Format.duration(block.minutes)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(start.map { Format.clock($0) } ?? "")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, alignment: .trailing)
                    .help("When this should start if the day runs in order")
            }
            .frame(minHeight: 26)
            .reorderable(dragText: DragText.block(blockIndex), title: block.title) { store.moveDraggedBlock($0, to: blockIndex) }
            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    StepList(store: store, block: block, blockIndex: blockIndex)
                    AddField(placeholder: "Add step") { store.addStep($0, to: blockIndex) }
                }
                .padding(.leading, 25)
                .padding(.bottom, 6)
            }
        }
        .contextMenu {
            Button("Do next", systemImage: "arrow.up.to.line") { store.moveToNext(blockIndex) }
            Button("Done", systemImage: "checkmark") { store.finish(blockIndex) }
            Button("Later", systemImage: "arrow.down.to.line") { store.moveToLater(blockIndex) }
        }
    }
}

/// A quiet "+ Add" field. Return adds the text and keeps the field ready for the next one.
struct AddField: View {
    let placeholder: String
    let onAdd: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .help("Type, then press Return to add")
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    onAdd(text)
                    text = ""
                }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The text a drag carries, so a drop knows what moved: "ise-block:3", or "ise-step:3:1" for step 1 of block 3.
enum DragText {
    private static let blockPrefix = "ise-block:"

    static func block(_ index: Int) -> String {
        blockPrefix + String(index)
    }

    static func step(_ step: Int, in blockIndex: Int) -> String {
        stepPrefix(blockIndex) + String(step)
    }

    static func blockIndex(from text: String) -> Int? {
        text.hasPrefix(blockPrefix) ? Int(text.dropFirst(blockPrefix.count)) : nil
    }

    /// Only steps dragged from the same block count, so steps never jump between blocks.
    static func stepIndex(from text: String, in blockIndex: Int) -> Int? {
        let prefix = stepPrefix(blockIndex)
        return text.hasPrefix(prefix) ? Int(text.dropFirst(prefix.count)) : nil
    }

    private static func stepPrefix(_ blockIndex: Int) -> String {
        "ise-step:\(blockIndex):"
    }
}

extension PlanStore {
    /// Moves the block a drag carries to `target`. Returns false when the drag held something else.
    func moveDraggedBlock(_ dragText: String, to target: Int) -> Bool {
        guard let index = DragText.blockIndex(from: dragText) else { return false }
        moveBlock(index, to: target)
        return true
    }

    /// Moves the step a drag carries to `target`. Returns false when the drag held something else.
    func moveDraggedStep(_ dragText: String, to target: Int, in blockIndex: Int) -> Bool {
        guard let step = DragText.stepIndex(from: dragText, in: blockIndex) else { return false }
        moveStep(step, to: target, in: blockIndex)
        return true
    }
}

extension View {
    /// Lets a row be dragged by a grip that shows on hover, and tints the row a dragged one would land on.
    /// Pass no drag text for a row that takes drops but cannot move, such as a finished block.
    func reorderable(dragText: String?, title: String, onDrop: @escaping (String) -> Bool) -> some View {
        modifier(ReorderableRow(dragText: dragText, title: title, onDrop: onDrop))
    }
}

private struct ReorderableRow: ViewModifier {
    let dragText: String?
    let title: String
    let onDrop: (String) -> Bool
    @State private var isHovering = false
    @State private var isDropTarget = false

    func body(content: Content) -> some View {
        let row = content
            .overlay(alignment: .leading) { grip }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .dropDestination(for: String.self) { texts, _ in
                texts.first.map(onDrop) ?? false
            } isTargeted: { isDropTarget = $0 }
            .background(dropTint)
        if let dragText {
            row.draggable(dragText) { preview }
        } else {
            row
        }
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 12, height: 22)
            .contentShape(Rectangle())
            .offset(x: -15)
            .opacity(isHovering && dragText != nil ? 1 : 0)
            .help("Drag to move")
    }

    private var dropTint: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.accentColor.opacity(isDropTarget ? 0.15 : 0))
            .padding(.horizontal, -6)
    }

    private var preview: some View {
        Text(title)
            .font(.system(size: 13))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Picks a block's length from common choices.
struct LengthMenu<Content: View>: View {
    let minutes: Int
    let onChange: (Int) -> Void
    @ViewBuilder let label: () -> Content

    private static var choices: [Int] { [15, 30, 45, 60, 90, 120] }

    var body: some View {
        Menu {
            ForEach(Self.choices, id: \.self) { choice in
                Button {
                    onChange(choice)
                } label: {
                    if choice == minutes {
                        Label(Format.duration(choice), systemImage: "checkmark")
                    } else {
                        Text(Format.duration(choice))
                    }
                }
            }
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change how long this takes")
    }
}

struct WaitingRow: View {
    @ObservedObject var store: PlanStore
    let item: WaitingItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .frame(width: 15)
                .help(item.stepIndex == nil ? "A block waiting on someone" : "A step waiting on someone")
            Text(item.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 6)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(isDue ? Color.orange : Color.secondary)
                .help(isDue ? "Time to chase them" : "Who you are waiting on, and when to chase")
            if isDue {
                SmallIconButton(symbol: "clock.arrow.circlepath", label: "Still waiting, remind me in 2 hours") { store.chaseLater(item) }
            }
            SmallIconButton(symbol: "arrow.uturn.backward", label: "Unblocked, put it back") { store.unblock(item) }
        }
        .frame(minHeight: 26)
    }

    private var isDue: Bool {
        store.isChaseDue(item)
    }

    private var detail: String {
        let person = item.blockedBy ?? "someone"
        if isDue {
            return "Chase \(person)"
        }
        return item.chaseAt.map { "\(person) · \(Format.clock($0))" } ?? person
    }
}

/// Countdown for a started block, or its length before it starts.
struct TimerPill: View {
    @ObservedObject var store: PlanStore
    let block: Block

    var body: some View {
        if block.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = store.secondsLeft(block, at: context.date) ?? 0
                if block.pausedAt != nil {
                    pill(Format.countdown(seconds), symbol: "pause.fill", color: .secondary)
                } else {
                    pill(Format.countdown(seconds), symbol: "timer", color: seconds < 0 ? .red : .accentColor)
                }
            }
        } else {
            pill(Format.duration(block.minutes), symbol: "timer", color: .secondary)
        }
    }

    private func pill(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct EmptyMessage: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
    }
}

/// Blocks set aside with Later. They stay unfinished and come back with one click.
struct LaterSection: View {
    @ObservedObject var store: PlanStore

    /// A short list keeps the panel calm; the rest stay in the plan.
    private static let shownCount = 3

    var body: some View {
        let indices = store.laterIndices
        if !indices.isEmpty {
            SectionHeader(title: "Later", count: indices.count)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .help("Set aside, not done. Bring one back when you are ready")
            ForEach(indices.prefix(Self.shownCount), id: \.self) { index in
                LaterRow(store: store, block: store.blocks[index], blockIndex: index)
            }
            if indices.count > Self.shownCount {
                Text("\(indices.count - Self.shownCount) more in the Card view's plan")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 25)
                    .frame(minHeight: 22)
            }
        }
    }
}

struct LaterRow: View {
    @ObservedObject var store: PlanStore
    let block: Block
    let blockIndex: Int

    var body: some View {
        HStack(spacing: 10) {
            Button { store.finish(blockIndex) } label: { SquareCheckbox(status: .todo) }
                .buttonStyle(.plain)
                .padding(.horizontal, -4)
                .help("Mark as done")
            Text(block.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(Format.duration(block.minutes)).font(.system(size: 12)).foregroundStyle(.tertiary)
            SmallIconButton(symbol: "arrow.uturn.up", label: "Bring back as the next task") { store.putBackAsNext(blockIndex) }
        }
        .frame(minHeight: 26)
    }
}

/// A bar on the panel's free edge. Dragging it sets how tall the panel may grow; content that does not fit scrolls.
struct HeightGrip: View {
    @Binding var limit: Double
    /// How tall the content is right now, which the drag starts from.
    let shownHeight: Double
    /// The most the content may take on the panel's screen.
    let tallest: Double
    /// True when the panel hangs from a top corner, so dragging down makes it taller.
    let growsDownward: Bool
    @State private var dragStart: (mouseY: CGFloat, height: Double)?
    @State private var isHovering = false

    private static let shortest = 160.0

    var body: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(Color.secondary.opacity(isHovering || dragStart != nil ? 0.6 : 0.3))
                .frame(width: 36, height: 4)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in resize() }
                .onEnded { _ in dragStart = nil }
        )
        .help("Drag to make the panel taller or shorter. Anything that does not fit scrolls.")
    }

    /// Follows the mouse on screen, not in the view, because the window itself moves while it resizes.
    private func resize() {
        let mouseY = NSEvent.mouseLocation.y
        let start = dragStart ?? (mouseY, shownHeight)
        dragStart = start
        let movedDown = Double(start.mouseY - mouseY)
        limit = min(max(start.height + (growsDownward ? movedDown : -movedDown), Self.shortest), tallest)
    }
}
