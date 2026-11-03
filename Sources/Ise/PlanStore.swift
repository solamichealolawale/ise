import AppKit

/// Reads the day's plan, writes ticks back, starts each new day, and decides when to ring.
final class PlanStore: ObservableObject {
    @Published private(set) var plan: Plan?
    @Published private(set) var now = Date()
    @Published private(set) var alert: Alert = .none
    @Published private(set) var canUndo = false
    @Published private(set) var settings: Settings
    @Published private(set) var sessions: [SessionRecord] = []
    @Published var isShowingDayReport = false
    @Published var settingsProblem: String?
    @Published var showDay = false
    /// Called when a new block comes up or an alarm rings, so the bubble can open itself.
    var onNeedsAttention: (() -> Void)?

    private var planFile: PlanFile
    private var sessionsFile: SessionsFile
    private var folderWatcher: FolderWatcher?
    private var loadedModificationDate: Date?
    private var loadedSessionsDate: Date?
    private var loadedSettingsDate: Date?
    private var currentTitle: String?
    private var becameCurrentAt = Date()
    private var snoozedUntil: Date?
    private var lastRing: (alert: Alert, at: Date)?
    private var timer: Timer?

    private static let dayReportShownKey = "dayReportShownOn"

    /// The plan in the folder the settings choose.
    convenience init() {
        self.init(fileURL: PlanFile(settings: IseFolder.loadSettings()).url)
    }

    init(fileURL: URL) {
        settings = IseFolder.loadSettings()
        planFile = PlanFile(url: fileURL)
        sessionsFile = SessionsFile(folder: fileURL.deletingLastPathComponent())
        watchFolder()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    // MARK: - Reading the plan

    var isForToday: Bool {
        plan?.date == Plan.dayString(now)
    }

    var blocks: [Block] {
        plan?.blocks ?? []
    }

    var currentIndex: Int? {
        plan?.currentIndex(at: now)
    }

    /// Claude sessions that stopped with work left and are not already in today's plan, newest first.
    var sessionsWithWorkLeft: [SessionRecord] {
        let linked = Set(blocks.compactMap(\.sessionId))
        return sessions.filter { $0.hasWorkLeft && !linked.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var isLoud: Bool {
        alert == .notStarted || alert == .overrun
    }

    /// Blocks still to do after the current one, in plan order.
    var upNextIndices: [Int] {
        let current = currentIndex
        return blocks.indices.filter { blocks[$0].status == .todo && $0 != current }
    }

    func secondsLeft(_ block: Block, at date: Date) -> Int? {
        plannedEnd(block, at: date).map { Int($0.timeIntervalSince(date)) }
    }

    func minutesPaused(_ block: Block) -> Int? {
        block.pausedAt.map { Int(now.timeIntervalSince($0) / 60) }
    }

    /// Parked blocks and blocked steps, in plan order.
    var waitingItems: [WaitingItem] {
        blocks.indices.flatMap { blockIndex -> [WaitingItem] in
            let block = blocks[blockIndex]
            var items: [WaitingItem] = []
            if block.status == .waiting {
                items.append(WaitingItem(blockIndex: blockIndex, stepIndex: nil, title: block.title, blockedBy: block.blockedBy, chaseAt: block.chaseAt))
            }
            for stepIndex in block.steps.indices where block.steps[stepIndex].status == .blocked {
                let step = block.steps[stepIndex]
                items.append(WaitingItem(blockIndex: blockIndex, stepIndex: stepIndex, title: step.text, blockedBy: step.blockedBy, chaseAt: step.chaseAt))
            }
            return items
        }
    }

    func isChaseDue(_ item: WaitingItem) -> Bool {
        guard let chaseAt = item.chaseAt else { return false }
        return chaseAt <= now
    }

    /// When a started block's time runs out. While paused it moves with the clock, so the time left stays frozen.
    func plannedEnd(_ block: Block, at date: Date? = nil) -> Date? {
        guard let startedAt = block.startedAt else { return nil }
        let pausedNow = block.pausedAt.map { (date ?? now).timeIntervalSince($0) } ?? 0
        return startedAt.addingTimeInterval(Double((block.minutes + block.extraMinutes) * 60 + block.pausedSeconds) + pausedNow)
    }

    func minutesLeft(_ block: Block) -> Int? {
        plannedEnd(block).map { Int(($0.timeIntervalSince(now) / 60).rounded(.up)) }
    }

    var minutesSinceBlockCameUp: Int {
        Int(now.timeIntervalSince(becameCurrentAt) / 60)
    }

    var canSnooze: Bool {
        guard let index = currentIndex else { return false }
        return blocks[index].snoozes < 2
    }

    /// Where each remaining block lands if the day runs in list order from now.
    func estimatedStarts() -> [Int: Date] {
        var cursor = now
        if let index = currentIndex {
            let block = blocks[index]
            cursor = max(now, plannedEnd(block) ?? now.addingTimeInterval(Double(block.minutes) * 60))
        }
        var starts: [Int: Date] = [:]
        for index in blocks.indices where blocks[index].status == .todo && index != currentIndex {
            let block = blocks[index]
            let length = Double(block.minutes) * 60
            if let fixed = clockTime(block.fixedStart) {
                starts[index] = fixed
                cursor = max(cursor, fixed.addingTimeInterval(length))
            } else {
                starts[index] = cursor
                cursor = cursor.addingTimeInterval(length)
            }
        }
        return starts
    }

    var minutesOfWorkLeft: Int {
        blocks.reduce(0) { total, block in
            switch block.status {
            case .doing: return total + max(0, minutesLeft(block) ?? block.minutes)
            case .todo, .skipped: return total + block.minutes
            case .done, .waiting: return total
            }
        }
    }

    var dayEnd: String {
        plan?.dayEnd ?? settings.dayEnd
    }

    var minutesUntilDayEnd: Int? {
        clockTime(dayEnd).map { Int($0.timeIntervalSince(now) / 60) }
    }

    func clockTime(_ hoursAndMinutes: String?) -> Date? {
        plan?.clockTime(hoursAndMinutes)
    }

    // MARK: - Actions

    func start(_ index: Int) {
        update(index) {
            $0.status = .doing
            $0.startedAt = now
        }
    }

    func finish(_ index: Int) {
        update(index) {
            $0.status = .done
            $0.pausedAt = nil
        }
        Sound.play("Hero")
    }

    /// What the panel says when no block is up: never "all done" while work waits in Later.
    var nothingCurrentMessage: String {
        if !upNextIndices.isEmpty {
            return "Free until the next fixed block"
        }
        if !laterIndices.isEmpty {
            return "Only Later is left. Bring one back when you are ready."
        }
        return waitingItems.isEmpty ? "All done for today" : "Only work waiting on someone is left."
    }

    var nothingCurrentIcon: String {
        if !upNextIndices.isEmpty { return "clock" }
        if !laterIndices.isEmpty { return "arrow.down.circle" }
        return waitingItems.isEmpty ? "checkmark.seal.fill" : "hand.raised"
    }

    func pause(_ index: Int) {
        update(index) { $0.pausedAt = now }
    }

    func resume(_ index: Int) {
        update(index) { block in
            guard let pausedAt = block.pausedAt else { return }
            block.pausedSeconds += Int(now.timeIntervalSince(pausedAt))
            block.pausedAt = nil
        }
    }

    func extend(_ index: Int) {
        update(index) { $0.extraMinutes += 15 }
    }

    /// Changes a block's length. Later blocks start earlier or later to match, because the plan runs in order.
    func setMinutes(_ minutes: Int, for index: Int) {
        update(index) { $0.minutes = max(minutes, 5) }
    }

    func addStep(_ text: String, to index: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(index) { $0.steps.append(Step(text: trimmed)) }
    }

    func addBlock(_ title: String, minutes: Int = 30) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = now
        change { plan in
            plan.insertByClock(Block(title: trimmed, minutes: minutes), now: now)
            return true
        }
    }

    /// Moves a block to straight after the one in progress, so it comes up next.
    func moveToNext(_ index: Int) {
        let shown = shownTitle(at: index)
        change { plan in
            guard Self.block(at: index, in: plan, isTitled: shown) else { return false }
            Self.insertAsNext(plan.blocks.remove(at: index), into: &plan.blocks)
            return true
        }
    }

    private static func insertAsNext(_ block: Block, into blocks: inout [Block]) {
        let afterBlockInProgress = blocks.firstIndex { $0.status == .doing }.map { $0 + 1 }
        let firstWaitingToStart = blocks.firstIndex { $0.status == .todo }
        blocks.insert(block, at: afterBlockInProgress ?? firstWaitingToStart ?? blocks.count)
    }

    /// Moves a dragged block into the place of the block it was dropped on.
    func moveBlock(_ index: Int, to target: Int) {
        let shown = shownTitle(at: index)
        let shownTarget = shownTitle(at: target)
        guard index != target else { return }
        change { plan in
            guard Self.block(at: index, in: plan, isTitled: shown), Self.block(at: target, in: plan, isTitled: shownTarget) else { return false }
            plan.blocks.insert(plan.blocks.remove(at: index), at: target)
            return true
        }
    }

    /// Moves a dragged step into the place of the step it was dropped on, within one block.
    func moveStep(_ step: Int, to target: Int, in index: Int) {
        guard step != target else { return }
        update(index) { block in
            guard block.steps.indices.contains(step), block.steps.indices.contains(target) else { return }
            block.steps.insert(block.steps.remove(at: step), at: target)
        }
    }

    /// Puts the plan back to how it was before the last change, made here or by the `ise` command.
    func undo() {
        _ = try? planFile.undo()
        reload()
    }

    // MARK: - Claude sessions

    /// Adds a session's unfinished work as a block, with its open tasks as steps.
    func addToToday(_ session: SessionRecord) {
        var block = Block(title: session.displayTitle, minutes: 30)
        block.steps = session.openTasks.map { Step(text: $0.subject) }
        block.sessionId = session.id
        block.folder = session.folder
        let now = now
        change { plan in
            plan.insertByClock(block, now: now)
            return true
        }
    }

    func dismiss(_ session: SessionRecord) {
        try? sessionsFile.update(session.id, folder: session.folder) { $0.isDismissed = true }
        reloadSessions()
    }

    // MARK: - Settings

    /// Saves new choices. Turning sync on or off moves the plan to or from iCloud Drive first.
    func updateSettings(_ newSettings: Settings) {
        let movesFolder = newSettings.syncsWithICloud != settings.syncsWithICloud
        do {
            if movesFolder {
                try IseFolder.changeSync(to: newSettings.syncsWithICloud)
            }
            try IseFolder.save(newSettings)
            settingsProblem = nil
        } catch {
            settingsProblem = error.localizedDescription
            return
        }
        settings = newSettings
        loadedSettingsDate = modificationDate(of: IseFolder.settingsURL)
        if movesFolder {
            useFolderFromSettings()
            reload()
        }
    }

    func snooze() {
        guard canSnooze, let index = currentIndex else { return }
        update(index) { $0.snoozes += 1 }
        snoozedUntil = now.addingTimeInterval(10 * 60)
        tick()
    }

    func park(_ index: Int, blockedBy person: String) {
        update(index) {
            $0.status = .waiting
            $0.blockedBy = person.isEmpty ? nil : person
            $0.chaseAt = now.addingTimeInterval(2 * 60 * 60)
        }
    }

    func chaseLater(_ item: WaitingItem) {
        let later = now.addingTimeInterval(2 * 60 * 60)
        update(item.blockIndex) { block in
            if let stepIndex = item.stepIndex {
                guard block.steps.indices.contains(stepIndex) else { return }
                block.steps[stepIndex].chaseAt = later
            } else {
                block.chaseAt = later
            }
        }
    }

    func unblock(_ item: WaitingItem) {
        if let stepIndex = item.stepIndex {
            setStep(stepIndex, in: item.blockIndex, to: .todo)
        } else {
            putBackAsNext(item.blockIndex)
        }
    }

    /// Puts a parked block, or one moved to Later, back as the next one up, so it is not lost at the bottom.
    func putBackAsNext(_ index: Int) {
        let shown = shownTitle(at: index)
        change { plan in
            guard Self.block(at: index, in: plan, isTitled: shown) else { return false }
            var block = plan.blocks.remove(at: index)
            block.status = .todo
            block.clearTimer()
            block.blockedBy = nil
            block.chaseAt = nil
            Self.insertAsNext(block, into: &plan.blocks)
            return true
        }
    }

    /// Sets a block aside without finishing it. It waits in Later, still counted as work left, until brought back.
    func moveToLater(_ index: Int) {
        update(index) {
            $0.status = .skipped
            $0.clearTimer()
        }
    }

    /// Blocks moved to Later, in plan order.
    var laterIndices: [Int] {
        blocks.indices.filter { blocks[$0].status == .skipped }
    }

    func toggleStepDone(_ step: Int, in index: Int) {
        guard blocks.indices.contains(index), blocks[index].steps.indices.contains(step) else { return }
        // Clicking a done step undoes it, and clicking a Later step brings it back rather than ticking it.
        let status = blocks[index].steps[step].status
        setStep(step, in: index, to: status == .done || status == .skipped ? .todo : .done)
    }

    func setStep(_ step: Int, in index: Int, to status: StepStatus) {
        update(index) { block in
            guard block.steps.indices.contains(step) else { return }
            block.steps[step].status = status
            block.steps[step].blockedBy = nil
            block.steps[step].chaseAt = nil
        }
    }

    func blockStep(_ step: Int, in index: Int, blockedBy person: String) {
        let chaseAt = now.addingTimeInterval(2 * 60 * 60)
        update(index) { block in
            guard block.steps.indices.contains(step) else { return }
            block.steps[step].status = .blocked
            block.steps[step].blockedBy = person.isEmpty ? nil : person
            block.steps[step].chaseAt = chaseAt
        }
    }

    /// Changes one block, but only if it is still the block the panel showed at that place.
    private func update(_ index: Int, _ edit: (inout Block) -> Void) {
        let shown = shownTitle(at: index)
        change { plan in
            guard Self.block(at: index, in: plan, isTitled: shown) else { return false }
            edit(&plan.blocks[index])
            return true
        }
    }

    /// Changes the plan as it is on disk right now, under the shared lock, so a change made
    /// by the `ise` command or a Claude hook a moment ago is never lost. Then shows the result.
    private func change(_ edit: (inout Plan) -> Bool) {
        _ = try? planFile.change(settings: settings, now: now) { edit(&$0) }
        reload()
    }

    private func shownTitle(at index: Int) -> String? {
        blocks.indices.contains(index) ? blocks[index].title : nil
    }

    /// Indexes come from what the panel shows; another writer may have moved blocks since, so check before using one.
    private static func block(at index: Int, in plan: Plan, isTitled title: String?) -> Bool {
        plan.blocks.indices.contains(index) && plan.blocks[index].title == title
    }

    // MARK: - Ticking and ringing

    private func tick() {
        now = Date()
        loadSettingsIfChanged()
        loadIfChanged()
        startNewDayIfNeeded()
        noticeNewCurrentBlock()
        let newAlert = isForToday ? currentAlert() : .none
        ringIfNeeded(newAlert)
        alert = newAlert
        showDayReportIfDue()
    }

    private func startNewDayIfNeeded() {
        if let plan, plan.date >= Plan.dayString(now) { return }
        guard (try? planFile.todaysPlan(settings: settings, now: now)) != nil else { return }
        reload()
    }

    private func showDayReportIfDue() {
        guard settings.showsEndOfDayReport, isForToday, let end = clockTime(dayEnd), now >= end else { return }
        let today = Plan.dayString(now)
        guard UserDefaults.standard.string(forKey: Self.dayReportShownKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.dayReportShownKey)
        isShowingDayReport = true
        onNeedsAttention?()
    }

    private func noticeNewCurrentBlock() {
        let title = isForToday ? currentIndex.map { blocks[$0].title } : nil
        guard title != currentTitle else { return }
        currentTitle = title
        becameCurrentAt = now
        snoozedUntil = nil
        if title != nil {
            Sound.play("Glass")
            onNeedsAttention?()
        }
    }

    private func currentAlert() -> Alert {
        let isSnoozed = snoozedUntil.map { now < $0 } ?? false
        if !isSnoozed, let index = currentIndex {
            let block = blocks[index]
            if let pausedAt = block.pausedAt {
                if now.timeIntervalSince(pausedAt) >= 10 * 60 {
                    return .pausedTooLong
                }
            } else if block.status == .doing, let end = plannedEnd(block), now >= end {
                return .overrun
            }
            if block.status == .todo, now.timeIntervalSince(becameCurrentAt) >= 3 * 60 {
                return .notStarted
            }
        }
        return waitingItems.contains(where: isChaseDue) ? .chase : .none
    }

    private func ringIfNeeded(_ newAlert: Alert) {
        guard newAlert != .none else {
            lastRing = nil
            return
        }
        if let lastRing, lastRing.alert == newAlert {
            guard let gap = newAlert.repeatAfter, now.timeIntervalSince(lastRing.at) >= gap else { return }
        }
        lastRing = (newAlert, now)
        newAlert.playSound()
        if newAlert != .chase {
            onNeedsAttention?()
        }
    }

    // MARK: - File

    /// Reloads only files whose date changed, so a quiet tick costs a few file checks.
    private func loadIfChanged() {
        let modified = modificationDate(of: planFile.url)
        if modified != loadedModificationDate {
            loadedModificationDate = modified
            plan = planFile.load()
            canUndo = planFile.canUndo
        }
        if modificationDate(of: sessionsFile.url) != loadedSessionsDate {
            reloadSessions()
        }
    }

    private func reload() {
        loadedModificationDate = nil
        loadIfChanged()
        tick()
    }

    private func reloadSessions() {
        loadedSessionsDate = modificationDate(of: sessionsFile.url)
        sessions = sessionsFile.load()
    }

    /// Picks up settings changed by `ise settings`, including a move to or from iCloud Drive.
    private func loadSettingsIfChanged() {
        let modified = modificationDate(of: IseFolder.settingsURL)
        guard modified != loadedSettingsDate else { return }
        loadedSettingsDate = modified
        let newSettings = IseFolder.loadSettings()
        let movesFolder = IseFolder.dataFolder(for: newSettings) != IseFolder.dataFolder(for: settings)
        settings = newSettings
        if movesFolder {
            useFolderFromSettings()
        }
    }

    private func useFolderFromSettings() {
        planFile = PlanFile(settings: settings)
        sessionsFile = SessionsFile(folder: planFile.url.deletingLastPathComponent())
        watchFolder()
        loadedModificationDate = nil
        loadedSessionsDate = nil
    }

    /// Reacts as soon as the `ise` command or a Claude hook writes, instead of waiting for the next tick.
    private func watchFolder() {
        folderWatcher = FolderWatcher(folder: planFile.url.deletingLastPathComponent()) { [weak self] in
            self?.loadIfChanged()
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}

/// Calls back when files in a folder are added, replaced or removed. Saves replace files, so this catches every save.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(folder: URL, onChange: @escaping () -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
