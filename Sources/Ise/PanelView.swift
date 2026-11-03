import AppKit
import SwiftUI

/// The open panel: a title row beside the window buttons, the chosen view, and the day's progress.
struct PanelView: View {
    @ObservedObject var store: PlanStore
    @ObservedObject var window: FloatingController
    @State private var isShowingSettings = false
    /// The most the panel's content may take up, set by dragging the grip. Anything taller scrolls.
    @AppStorage("panelContentHeight") private var contentHeightLimit = 620.0
    @State private var shownContentHeight = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !window.corner.isTop {
                HeightGrip(limit: $contentHeightLimit, shownHeight: shownContentHeight, tallest: tallestContentHeight, growsDownward: false)
            }
            if store.isShowingDayReport {
                DayReportCard(store: store).padding(.horizontal, 10).padding(.bottom, 10)
            }
            ScrollView {
                content
            }
            .frame(maxHeight: min(contentHeightLimit, tallestContentHeight))
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { shownContentHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in shownContentHeight = height }
            })
            if window.corner.isTop {
                HeightGrip(limit: $contentHeightLimit, shownHeight: shownContentHeight, tallest: tallestContentHeight, growsDownward: true)
            } else {
                Divider()
            }
            footer
        }
        .frame(width: 360)
        .background(background)
        .overlay(alertTint.allowsHitTesting(false))
    }

    /// Room on the panel's own screen, less the day report when it shows, so the panel never runs off the screen.
    private var tallestContentHeight: Double {
        max(window.tallestContentHeight - (store.isShowingDayReport ? 220 : 0), 160)
    }

    @ViewBuilder
    private var content: some View {
        if !store.isForToday {
            EmptyMessage(text: notTodayMessage, icon: "calendar.badge.exclamationmark")
        } else {
            switch window.mode {
            case .list: ListModeView(store: store)
            case .focus: FocusModeView(store: store)
            case .card: CardModeView(store: store)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Today").font(.system(size: 14, weight: .semibold))
            if let date = store.plan?.date {
                Text(Format.dayTitle(date)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.canUndo {
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo the last change (⌘Z)")
            }
            Picker("View", selection: $window.mode) {
                Image(systemName: "checklist").help("List").tag(ViewMode.list)
                Image(systemName: "timer").help("Focus timer").tag(ViewMode.focus)
                Image(systemName: "rectangle.stack").help("Card").tag(ViewMode.card)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch view: List, Focus timer or Card")
        }
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: 38)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.isForToday {
                let doneCount = store.blocks.filter { $0.status == .done }.count
                Group {
                    Text("\(doneCount) of \(store.blocks.count) done").font(.system(size: 12, weight: .medium))
                    CapsuleBar(fraction: store.blocks.isEmpty ? 0 : Double(doneCount) / Double(store.blocks.count))
                        .frame(width: 60)
                }
                .help("Blocks done today")
                Spacer()
                Text(workLeftText)
                    .font(.system(size: 12))
                    .foregroundStyle(workFitsInDay ? Color.secondary : Color.orange)
                    .help(workFitsInDay ? "Work left today" : "Work left runs past the end of your day")
            } else {
                Spacer()
            }
            if let link = store.plan?.link, let url = URL(string: link) {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .help("Open the page this plan came from")
            }
            Button { isShowingSettings.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Settings: your hours, mornings, Claude sessions, and sharing between Macs")
                .popover(isPresented: $isShowingSettings, arrowEdge: .top) { SettingsView(store: store) }
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Quit Ise")
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    @ViewBuilder
    private var background: some View {
        if window.mode == .card {
            VisualEffectBackground()
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private var alertTint: Color {
        switch store.alert {
        case .overrun: return Color.red.opacity(0.10)
        case .notStarted, .pausedTooLong: return Color.orange.opacity(0.08)
        case .none, .chase: return .clear
        }
    }

    private var notTodayMessage: String {
        guard let date = store.plan?.date else {
            return "Today's plan file could not be read. Run `ise list` in a terminal to see why."
        }
        return "The plan file is dated \(date), so there is nothing to show for today."
    }

    private var workFitsInDay: Bool {
        guard let minutesUntilEnd = store.minutesUntilDayEnd else { return true }
        return store.minutesOfWorkLeft <= minutesUntilEnd
    }

    private var workLeftText: String {
        let workLeft = store.minutesOfWorkLeft
        guard let minutesUntilEnd = store.minutesUntilDayEnd, let dayEnd = store.plan?.dayEnd else {
            return "\(Format.duration(workLeft)) left"
        }
        return workLeft > minutesUntilEnd
            ? "\(Format.duration(workLeft - minutesUntilEnd)) over \(dayEnd)"
            : "\(Format.duration(workLeft)) left"
    }
}

/// A: the current block in a card, then Up next and Waiting as plain rows.
struct ListModeView: View {
    @ObservedObject var store: PlanStore

    /// Keeps the panel shorter than a laptop screen; the full day is one click away in the Card view.
    private static let upNextShown = 5

    var body: some View {
        let starts = store.estimatedStarts()
        VStack(alignment: .leading, spacing: 0) {
            if let index = store.currentIndex {
                currentCard(store.blocks[index], index: index)
                    .padding(.horizontal, 10)
            } else {
                EmptyMessage(text: store.nothingCurrentMessage, icon: store.nothingCurrentIcon)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !store.upNextIndices.isEmpty {
                    SectionHeader(title: "Up next", count: store.upNextIndices.count).padding(.bottom, 4)
                    ForEach(store.upNextIndices.prefix(Self.upNextShown), id: \.self) { index in
                        UpNextRow(store: store, block: store.blocks[index], blockIndex: index, start: starts[index])
                    }
                    if store.upNextIndices.count > Self.upNextShown {
                        Text("\(store.upNextIndices.count - Self.upNextShown) more later today")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 25)
                            .frame(minHeight: 22)
                    }
                }
                AddField(placeholder: "Add task") { store.addBlock($0) }
                    .padding(.top, 6)
                LaterSection(store: store)
                FromClaudeSection(store: store)
                if !store.waitingItems.isEmpty {
                    SectionHeader(title: "Waiting", count: store.waitingItems.count).padding(.top, 12).padding(.bottom, 4)
                    ForEach(store.waitingItems) { WaitingRow(store: store, item: $0) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
    }

    private func currentCard(_ block: Block, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusText(store: store, block: block)
                Spacer()
                LengthMenu(minutes: block.minutes, onChange: { store.setMinutes($0, for: index) }) {
                    TimerPill(store: store, block: block)
                }
            }
            BlockTitle(block: block)
            if block.status == .doing {
                TimeLeftBar(store: store, block: block)
            }
            StepList(store: store, block: block, blockIndex: index)
            AddField(placeholder: "Add step") { store.addStep($0, to: index) }
            BlockActions(store: store, block: block, blockIndex: index)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// B: one big countdown ring for the current block, its steps, the next block, and anything waiting or in Later.
struct FocusModeView: View {
    @ObservedObject var store: PlanStore

    var body: some View {
        if let index = store.currentIndex {
            let block = store.blocks[index]
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    LengthMenu(minutes: block.minutes, onChange: { store.setMinutes($0, for: index) }) {
                        FocusRing(store: store, block: block)
                    }
                    BlockTitle(block: block, isCentered: true)
                    BlockActions(store: store, block: block, blockIndex: index, isCentered: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Steps", count: block.steps.count).padding(.bottom, 4)
                    StepList(store: store, block: block, blockIndex: index)
                    AddField(placeholder: "Add step") { store.addStep($0, to: index) }
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                if let nextIndex = store.upNextIndices.first {
                    Divider()
                    HStack(spacing: 8) {
                        Text("Next").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text(store.blocks[nextIndex].title).font(.system(size: 13)).lineLimit(1)
                        Spacer()
                        Text(store.estimatedStarts()[nextIndex].map { Format.clock($0) } ?? "")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 36)
                }
                if !store.waitingItems.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(title: "Waiting", count: store.waitingItems.count).padding(.bottom, 4)
                        ForEach(store.waitingItems) { WaitingRow(store: store, item: $0) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                laterList
            }
        } else {
            EmptyMessage(text: store.nothingCurrentMessage, icon: store.nothingCurrentIcon)
            laterList
        }
    }

    @ViewBuilder
    private var laterList: some View {
        if !store.laterIndices.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                LaterSection(store: store)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }
}

/// C: the earlier card: a status pill and large countdown, round checkboxes, and the whole day underneath.
struct CardModeView: View {
    @ObservedObject var store: PlanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let index = store.currentIndex {
                let block = store.blocks[index]
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        StatusPill(store: store, block: block)
                        Spacer()
                        LengthMenu(minutes: block.minutes, onChange: { store.setMinutes($0, for: index) }) {
                            LargeCountdown(store: store, block: block)
                        }
                    }
                    BlockTitle(block: block)
                    if block.status == .doing {
                        TimeLeftBar(store: store, block: block)
                    }
                    StepList(store: store, block: block, blockIndex: index, isRound: true)
                    AddField(placeholder: "Add step") { store.addStep($0, to: index) }
                    BlockActions(store: store, block: block, blockIndex: index)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            } else {
                EmptyMessage(text: store.nothingCurrentMessage, icon: store.nothingCurrentIcon)
            }
            if !store.waitingItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Waiting", count: store.waitingItems.count).padding(.bottom, 4)
                    ForEach(store.waitingItems) { WaitingRow(store: store, item: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            Divider()
            dayPlan.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    /// The whole day scrolls inside a fixed height, so a long day never makes the panel taller than the screen.
    private static let planListHeight: CGFloat = 200

    private var dayPlan: some View {
        let starts = store.estimatedStarts()
        let currentIndex = store.currentIndex
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Plan", count: store.blocks.count)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.blocks.indices, id: \.self) { index in
                            planRow(index, start: starts[index], isCurrent: index == currentIndex).id(index)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .padding(.horizontal, -6)
                .frame(maxHeight: Self.planListHeight)
                .onAppear { currentIndex.map { scroller.scrollTo($0, anchor: .center) } }
            }
            AddField(placeholder: "Add task") { store.addBlock($0) }
                .padding(.top, 4)
            FromClaudeSection(store: store)
        }
    }

    private func planRow(_ index: Int, start: Date?, isCurrent: Bool) -> some View {
        let block = store.blocks[index]
        let isLater = block.status == .skipped
        return HStack(spacing: 8) {
            Text(dayTime(block, start: start, isCurrent: isCurrent))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Image(systemName: dayIcon(block.status))
                .font(.system(size: 11))
                .foregroundStyle(dayColor(block.status))
                .help(statusName(block.status))
            Text(block.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .strikethrough(block.status == .done)
                .foregroundStyle(block.status == .todo || block.status == .doing ? Color.primary : Color.secondary)
            Spacer()
            if isLater {
                SmallIconButton(symbol: "arrow.uturn.up", label: "Bring back as the next task") { store.putBackAsNext(index) }
            }
            LengthMenu(minutes: block.minutes, onChange: { store.setMinutes($0, for: index) }) {
                Text(Format.duration(block.minutes)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .reorderable(dragText: block.status == .todo ? DragText.block(index) : nil, title: block.title) {
            store.moveDraggedBlock($0, to: index)
        }
    }

    private func dayTime(_ block: Block, start: Date?, isCurrent: Bool) -> String {
        switch block.status {
        case .done: return "Done"
        case .waiting: return "Waiting"
        case .skipped: return "Later"
        case .doing: return "Now"
        case .todo: return isCurrent ? "Now" : start.map { Format.clock($0) } ?? ""
        }
    }

    private func statusName(_ status: BlockStatus) -> String {
        switch status {
        case .todo: return "To do"
        case .doing: return "In progress"
        case .done: return "Done"
        case .waiting: return "Waiting on someone"
        case .skipped: return "Set aside for later, not done"
        }
    }

    private func dayIcon(_ status: BlockStatus) -> String {
        switch status {
        case .todo: return "circle"
        case .doing: return "play.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .waiting: return "hand.raised.circle.fill"
        case .skipped: return "arrow.down.circle"
        }
    }

    private func dayColor(_ status: BlockStatus) -> Color {
        switch status {
        case .todo, .skipped: return .secondary
        case .doing: return .accentColor
        case .done: return .green
        case .waiting: return .orange
        }
    }
}

// MARK: - Pieces shared by the modes

struct StatusText: View {
    @ObservedObject var store: PlanStore
    let block: Block

    var body: some View {
        let (label, color) = statusLabel(store: store, block: block)
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .help(statusExplanation(store: store, block: block))
    }
}

struct StatusPill: View {
    @ObservedObject var store: PlanStore
    let block: Block

    var body: some View {
        let (label, color) = statusLabel(store: store, block: block)
        Text(label)
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
            .help(statusExplanation(store: store, block: block))
    }
}

private func statusExplanation(store: PlanStore, block: Block) -> String {
    if block.pausedAt != nil {
        return "Paused. The countdown and the alarms are frozen."
    }
    switch store.alert {
    case .overrun: return "This block has run past its time."
    case .notStarted: return "This block came up a while ago and has not started."
    case .none, .chase, .pausedTooLong: return block.status == .doing ? "The block you are working on" : "The next block to start"
    }
}

private func statusLabel(store: PlanStore, block: Block) -> (String, Color) {
    if let minutesPaused = store.minutesPaused(block) {
        return ("PAUSED \(Format.duration(minutesPaused).uppercased())", store.alert == .pausedTooLong ? .orange : .secondary)
    }
    switch store.alert {
    case .overrun: return ("OVER TIME", .red)
    case .notStarted: return ("NOT STARTED", .orange)
    case .none, .chase, .pausedTooLong: return block.status == .doing ? ("NOW", .accentColor) : ("UP NOW", .accentColor)
    }
}

struct LargeCountdown: View {
    @ObservedObject var store: PlanStore
    let block: Block

    var body: some View {
        if block.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = store.secondsLeft(block, at: context.date) ?? 0
                Text(Format.countdown(seconds))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(block.pausedAt != nil ? Color.secondary : seconds < 0 ? Color.red : Color.primary)
            }
        } else {
            Text(Format.duration(block.minutes)).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct TimeLeftBar: View {
    @ObservedObject var store: PlanStore
    let block: Block

    var body: some View {
        let seconds = store.secondsLeft(block, at: store.now) ?? 0
        let total = Double((block.minutes + block.extraMinutes) * 60)
        let color: Color = block.pausedAt != nil ? .secondary : seconds <= 0 ? .red : .accentColor
        CapsuleBar(fraction: seconds <= 0 ? 1 : Double(seconds) / total, color: color)
    }
}

struct FocusRing: View {
    @ObservedObject var store: PlanStore
    let block: Block

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = store.secondsLeft(block, at: context.date)
            let total = Double((block.minutes + block.extraMinutes) * 60)
            let isOver = (seconds ?? 1) <= 0
            let isPaused = block.pausedAt != nil
            ZStack {
                Circle().stroke(Color.primary.opacity(0.07), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: seconds.map { $0 <= 0 ? 1 : Double($0) / total } ?? 1)
                    .stroke(ringColor(seconds: seconds, isOver: isOver, isPaused: isPaused), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(Format.countdown(seconds ?? block.minutes * 60))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isPaused ? Color.secondary : isOver ? Color.red : Color.primary)
                    Text(caption(seconds: seconds, isOver: isOver))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, height: 150)
        }
    }

    private func ringColor(seconds: Int?, isOver: Bool, isPaused: Bool) -> Color {
        if isPaused { return Color.secondary.opacity(0.5) }
        if isOver { return .red }
        return Color.accentColor.opacity(seconds == nil ? 0.35 : 1)
    }

    private func caption(seconds: Int?, isOver: Bool) -> String {
        if let minutesPaused = store.minutesPaused(block) { return "paused \(Format.duration(minutesPaused))" }
        if seconds == nil { return "ready to start" }
        return isOver ? "over time" : "of \(Format.duration(block.minutes + block.extraMinutes))"
    }
}
