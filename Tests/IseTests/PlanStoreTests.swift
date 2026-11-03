import XCTest
@testable import Ise

final class PlanStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ise-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("ISE_HOME", folder.path, 1)
        fileURL = folder.appendingPathComponent("plan.json")
    }

    override func tearDown() {
        unsetenv("ISE_HOME")
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func storeWithBlocks(_ blocks: String) throws -> PlanStore {
        let json = #"{"date": "\#(Plan.dayString(Date()))", "dayEnd": "23:59", "blocks": [\#(blocks)]}"#
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        return PlanStore(fileURL: fileURL)
    }

    private func isoTime(minutesFromNow minutes: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(minutes * 60))
    }

    func testFirstFlexibleBlockIsUpWhileLaterMeetingWaitsForItsTime() throws {
        let store = try storeWithBlocks("""
        {"title": "Meeting", "minutes": 30, "fixedStart": "23:58"},
        {"title": "Checkout fix", "minutes": 60}
        """)

        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.alert, .none)
    }

    func testStartedBlockPastItsTimeRingsAsOverrun() throws {
        let store = try storeWithBlocks("""
        {"title": "Checkout fix", "minutes": 30, "status": "doing", "startedAt": "\(isoTime(minutesFromNow: -45))"}
        """)

        XCTAssertEqual(store.alert, .overrun)
        XCTAssertEqual(store.minutesLeft(store.blocks[0]), -15)
    }

    func testParkingABlockBringsUpTheNextOneWithoutRinging() throws {
        let store = try storeWithBlocks("""
        {"title": "Team call", "minutes": 15},
        {"title": "Checkout fix", "minutes": 60}
        """)

        store.park(0, blockedBy: "Sam")

        XCTAssertEqual(store.blocks[0].status, .waiting)
        XCTAssertEqual(store.blocks[0].blockedBy, "Sam")
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.alert, .none)
    }

    func testParkedBlockPastItsChaseTimeRingsAsChase() throws {
        let store = try storeWithBlocks("""
        {"title": "Team call", "minutes": 15, "status": "waiting", "chaseAt": "\(isoTime(minutesFromNow: -1))"},
        {"title": "Checkout fix", "minutes": 60, "status": "doing", "startedAt": "\(isoTime(minutesFromNow: -5))"}
        """)

        XCTAssertEqual(store.alert, .chase)
    }

    func testUnblockedBlockGoesRightAfterTheBlockInProgress() throws {
        let store = try storeWithBlocks("""
        {"title": "Team call", "minutes": 15, "status": "waiting"},
        {"title": "Checkout fix", "minutes": 60, "status": "doing", "startedAt": "\(isoTime(minutesFromNow: -5))"},
        {"title": "Time off", "minutes": 30}
        """)

        store.unblock(store.waitingItems[0])

        XCTAssertEqual(store.blocks.map(\.title), ["Checkout fix", "Team call", "Time off"])
        XCTAssertEqual(store.blocks[1].status, .todo)
    }

    func testBlockedStepIsListedAsWaitingAndRingsAtItsChaseTime() throws {
        let store = try storeWithBlocks("""
        {"title": "Chase and reply", "minutes": 30, "status": "doing", "startedAt": "\(isoTime(minutesFromNow: -5))",
         "steps": [{"text": "Book the Team call"}, {"text": "Reply to Alex"}]}
        """)

        store.blockStep(0, in: 0, blockedBy: "Sam")

        XCTAssertEqual(store.waitingItems.map(\.title), ["Book the Team call"])
        XCTAssertEqual(store.waitingItems.first?.blockedBy, "Sam")
        XCTAssertEqual(store.alert, .none)

        let chaseDue = try storeWithBlocks("""
        {"title": "Chase and reply", "minutes": 30, "status": "doing", "startedAt": "\(isoTime(minutesFromNow: -5))",
         "steps": [{"text": "Book the Team call", "status": "blocked", "chaseAt": "\(isoTime(minutesFromNow: -1))"}]}
        """)
        XCTAssertEqual(chaseDue.alert, .chase)
    }

    func testPausingFreezesTheTimeLeftAndResumingCarriesOn() throws {
        let store = try storeWithBlocks("""
        {"title": "Checkout fix", "minutes": 30, "status": "doing", "startedAt": "\(isoTime(minutesFromNow: -10))", "pausedAt": "\(isoTime(minutesFromNow: -4))"}
        """)
        let block = store.blocks[0]

        XCTAssertEqual(store.secondsLeft(block, at: Date()), store.secondsLeft(block, at: Date().addingTimeInterval(120)))
        XCTAssertEqual(store.minutesLeft(block), 24)
        XCTAssertEqual(store.alert, .none)

        store.resume(0)

        XCTAssertNil(store.blocks[0].pausedAt)
        XCTAssertEqual(store.blocks[0].pausedSeconds, 240, accuracy: 2)
        XCTAssertEqual(store.minutesLeft(store.blocks[0]), 24)
    }

    func testLongPauseNudgesInsteadOfCountingAsOverTime() throws {
        let store = try storeWithBlocks("""
        {"title": "Checkout fix", "minutes": 30, "status": "doing", "startedAt": "\(isoTime(minutesFromNow: -60))", "pausedAt": "\(isoTime(minutesFromNow: -45))"}
        """)

        XCTAssertEqual(store.alert, .pausedTooLong)
        XCTAssertEqual(store.minutesPaused(store.blocks[0]), 45)
    }

    func testChangingALengthMovesEveryBlockAfterIt() throws {
        let store = try storeWithBlocks("""
        {"title": "Checkout fix", "minutes": 30},
        {"title": "Time off", "minutes": 30},
        {"title": "Feature exceptions", "minutes": 30}
        """)
        let startsBefore = store.estimatedStarts()

        store.setMinutes(60, for: 0)

        let startsAfter = store.estimatedStarts()
        XCTAssertEqual(startsAfter[1]!.timeIntervalSince(startsBefore[1]!), 30 * 60, accuracy: 5)
        XCTAssertEqual(startsAfter[2]!.timeIntervalSince(startsBefore[2]!), 30 * 60, accuracy: 5)
    }

    func testAddedStepsAndTasksAreSavedAndATaskCanBeDoneNext() throws {
        let store = try storeWithBlocks("""
        {"title": "Chase and reply", "minutes": 30, "status": "doing", "startedAt": "\(isoTime(minutesFromNow: -5))"},
        {"title": "Checkout fix", "minutes": 60}
        """)

        store.addStep("  Ping Sam about the call  ", to: 0)
        store.addStep("   ", to: 0)
        store.addBlock("Reply to Alex")
        store.moveToNext(2)

        let reloaded = PlanStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.blocks[0].steps.map(\.text), ["Ping Sam about the call"])
        XCTAssertEqual(reloaded.blocks.map(\.title), ["Chase and reply", "Reply to Alex", "Checkout fix"])
        XCTAssertEqual(reloaded.blocks[1].minutes, 30)
    }

    func testDraggedBlocksAndStepsTakeThePlaceOfTheRowTheyAreDroppedOn() throws {
        let store = try storeWithBlocks("""
        {"title": "Checkout fix", "minutes": 30, "steps": [{"text": "Rebase"}, {"text": "Fix rounding"}, {"text": "Ask for review"}]},
        {"title": "Time off", "minutes": 30},
        {"title": "Reply to Alex", "minutes": 30}
        """)

        XCTAssertTrue(store.moveDraggedBlock(DragText.block(0), to: 2))
        XCTAssertTrue(store.moveDraggedStep(DragText.step(2, in: 2), to: 0, in: 2))
        XCTAssertFalse(store.moveDraggedStep(DragText.step(0, in: 2), to: 0, in: 1))

        let reloaded = PlanStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.blocks.map(\.title), ["Time off", "Reply to Alex", "Checkout fix"])
        XCTAssertEqual(reloaded.blocks[2].steps.map(\.text), ["Ask for review", "Rebase", "Fix rounding"])
    }

    func testUndoPutsBackEachChangeInTurn() throws {
        let store = try storeWithBlocks("""
        {"title": "Checkout fix", "minutes": 30},
        {"title": "Time off", "minutes": 30}
        """)

        store.moveBlock(1, to: 0)
        store.setMinutes(60, for: 0)
        store.undo()

        XCTAssertEqual(PlanStore(fileURL: fileURL).blocks.map(\.minutes), [30, 30])
        XCTAssertEqual(PlanStore(fileURL: fileURL).blocks.map(\.title), ["Time off", "Checkout fix"])

        store.undo()

        XCTAssertEqual(PlanStore(fileURL: fileURL).blocks.map(\.title), ["Checkout fix", "Time off"])
        XCTAssertFalse(store.canUndo)
    }

    func testTicksAreWrittenBackToTheFile() throws {
        let store = try storeWithBlocks("""
        {"title": "Checkout fix", "minutes": 60, "steps": [{"text": "Rebase"}, {"text": "Ask for review"}]}
        """)

        store.start(0)
        store.toggleStepDone(0, in: 0)
        store.setStep(1, in: 0, to: .skipped)

        let reloaded = PlanStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.blocks[0].status, .doing)
        XCTAssertEqual(reloaded.blocks[0].steps.map(\.status), [.done, .skipped])
    }
}
