import XCTest
@testable import Ise

final class IseCommandTests: XCTestCase {
    private var home: URL!
    private var planFile: PlanFile!
    private var settings = Settings()

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ise-\(UUID().uuidString)", isDirectory: true)
        setenv("ISE_HOME", home.path, 1)
        settings.lunch = nil
        planFile = PlanFile(settings: settings)
    }

    override func tearDown() {
        unsetenv("ISE_HOME")
        try? FileManager.default.removeItem(at: home)
    }

    private func run(_ words: String...) throws -> String {
        try PlanCommands(planFile: planFile, settings: settings, input: ParsedInput(words)).run()
    }

    private func savePlan(date: String = Plan.dayString(Date()), _ blocks: [Block]) throws {
        try planFile.save(Plan(date: date, dayEnd: "23:59", blocks: blocks))
    }

    private func block(_ title: String, _ status: BlockStatus = .todo, steps: [String] = [], fixedStart: String? = nil) -> Block {
        var block = Block(title: title, minutes: 30, fixedStart: fixedStart)
        block.status = status
        block.steps = steps.map { Step(text: $0) }
        return block
    }

    func testANewDayStartsWithYesterdaysUnfinishedWorkOnly() throws {
        let yesterday = Plan.dayString(Date().addingTimeInterval(-24 * 60 * 60))
        var started = block("Payment retries", .doing, steps: ["Write the test", "Fix the bug"])
        started.startedAt = Date().addingTimeInterval(-600)
        started.steps[0].status = .done
        try savePlan(date: yesterday, [block("Release notes", .done), started, block("Team sync", fixedStart: "10:00"), block("Reply to the designer")])

        let today = try planFile.todaysPlan(settings: settings)

        XCTAssertEqual(today.date, Plan.dayString(Date()))
        XCTAssertEqual(today.blocks.map(\.title), ["Payment retries", "Reply to the designer"])
        XCTAssertEqual(today.blocks[0].status, .todo)
        XCTAssertNil(today.blocks[0].startedAt)
        XCTAssertEqual(today.blocks[0].steps.map(\.status), [.done, .todo])
    }

    func testDoneAndReopenFindItemsByWordsOrNumberAndAskWhenUnclear() throws {
        try savePlan([block("Fix login bug", steps: ["Reproduce it"]), block("Fix pricing copy")])

        XCTAssertThrowsError(try run("done", "fix"))
        _ = try run("done", "1.1")
        _ = try run("done", "pricing")
        _ = try run("reopen", "pricing")

        let plan = try XCTUnwrap(planFile.load())
        XCTAssertEqual(plan.blocks[0].steps[0].status, .done)
        XCTAssertEqual(plan.blocks[1].status, .todo)
    }

    func testUndoGoesBackOneChangeAtATimeButNeverOverAnOutsideWrite() throws {
        try savePlan([block("Fix login bug")])
        _ = try run("add", "Write release notes")
        _ = try run("done", "login")

        XCTAssertTrue(try planFile.undo())
        XCTAssertEqual(planFile.load()?.blocks.first?.status, .todo)

        let outsidePlan = #"{"date": "\#(Plan.dayString(Date()))", "blocks": [{"title": "Written by a stand-up", "minutes": 30}]}"#
        try outsidePlan.write(to: planFile.url, atomically: true, encoding: .utf8)

        XCTAssertFalse(planFile.canUndo)
        XCTAssertFalse(try planFile.undo())
        XCTAssertEqual(planFile.load()?.blocks.map(\.title), ["Written by a stand-up"])
    }

    func testDoneWithASessionOnlyFinishesThatSessionsOwnTask() throws {
        var linked = block("Payment retries")
        linked.sessionId = "session-1"
        try savePlan([block("Other project review"), linked])

        XCTAssertThrowsError(try run("done", "--session", "unrelated-session"))
        _ = try run("done", "--session", "session-1")

        XCTAssertEqual(planFile.load()?.blocks.map(\.status), [.todo, .done])
    }

    func testAPlanMadeForTomorrowWaitsForItsDayAndPicksUpWhatIsLeft() throws {
        let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
        try savePlan([block("Fix login bug"), block("Release notes", .done)])
        try planFile.saveTomorrow(Plan(date: Plan.dayString(tomorrow), blocks: [block("Planned ahead")]))

        XCTAssertEqual(try planFile.todaysPlan(settings: settings).blocks.map(\.title), ["Fix login bug", "Release notes"])

        let nextDay = try planFile.todaysPlan(settings: settings, now: tomorrow)
        XCTAssertEqual(nextDay.blocks.map(\.title), ["Planned ahead", "Fix login bug"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: planFile.tomorrowURL.path))
    }

    func testOnlyAPermissionPromptLeavesASessionWaitingOnYou() throws {
        _ = try SessionHooks.handle(hook("Stop", message: "All done, the tests pass."), settings: settings)
        _ = try SessionHooks.handle(hook("Notification", notificationType: "idle_prompt"), settings: settings)
        XCTAssertFalse(try XCTUnwrap(SessionsFile(folder: home).load().first).hasWorkLeft)

        _ = try SessionHooks.handle(hook("Notification", notificationType: "permission_prompt"), settings: settings)
        XCTAssertTrue(try XCTUnwrap(SessionsFile(folder: home).load().first).hasWorkLeft)
    }

    func testLaterKeepsATaskUnfinishedCarriesItOverAndBringsItBack() throws {
        try savePlan([block("Release notes", steps: ["Draft", "Proofread"]), block("Fix login bug")])
        _ = try run("later", "release")
        _ = try run("later", "1.2")

        let today = try XCTUnwrap(planFile.load())
        XCTAssertEqual(today.blocks[0].status, .skipped)
        XCTAssertFalse(today.isFinished(PlanItem(block: 0, step: nil)))
        let tomorrow = today.carriedOver(to: Plan.dayString(Date().addingTimeInterval(24 * 60 * 60)), settings: settings)
        XCTAssertEqual(tomorrow.blocks.map(\.title), ["Release notes", "Fix login bug"])
        XCTAssertEqual(tomorrow.blocks[0].status, .todo)
        XCTAssertEqual(tomorrow.blocks[0].steps.map(\.status), [.todo, .todo])

        _ = try run("reopen", "release")
        XCTAssertEqual(planFile.load()?.blocks[0].status, .todo)
    }

    func testANewDayCannotBeUndoneAndTurningSyncOffAgainKeepsThePlan() throws {
        try savePlan(date: Plan.dayString(Date().addingTimeInterval(-24 * 60 * 60)), [block("Fix login bug")])
        _ = try planFile.todaysPlan(settings: settings)
        XCTAssertFalse(planFile.canUndo)

        try IseFolder.changeSync(to: false)
        XCTAssertEqual(planFile.load()?.blocks.map(\.title), ["Fix login bug"])
    }

    func testAPlanMadeAheadIsUsedAfterAMissedDayButNotAfterItsDayHadAPlan() throws {
        let day = 24.0 * 60 * 60
        let twoDaysAgo = Plan.dayString(Date().addingTimeInterval(-2 * day))
        let yesterday = Plan.dayString(Date().addingTimeInterval(-day))
        var shipped = block("Ship release", .done)
        shipped.steps = [Step(text: "Tag it")]

        try savePlan(date: twoDaysAgo, [block("Fix login bug")])
        try planFile.saveTomorrow(Plan(date: yesterday, blocks: [block("Planned for the missed day")]))
        XCTAssertEqual(try planFile.todaysPlan(settings: settings).blocks.map(\.title), ["Planned for the missed day", "Fix login bug"])

        try savePlan(date: yesterday, [shipped])
        try planFile.saveTomorrow(Plan(date: yesterday, blocks: [block("Ship release")]))
        XCTAssertEqual(try planFile.todaysPlan(settings: settings).blocks.map(\.title), [])
    }

    func testReopenAsksBetweenDoneAndLaterAndStartsTheTimerFresh() throws {
        var finished = block("Release notes", .done)
        finished.pausedSeconds = 600
        finished.extraMinutes = 15
        var checklist = block("Fix login bug", steps: ["Release checklist"])
        checklist.steps[0].status = .skipped
        try savePlan([finished, checklist])

        XCTAssertThrowsError(try run("reopen", "release"))
        _ = try run("reopen", "1")

        let reopened = try XCTUnwrap(planFile.load()?.blocks[0])
        XCTAssertEqual(reopened.status, .todo)
        XCTAssertEqual(reopened.pausedSeconds, 0)
        XCTAssertEqual(reopened.extraMinutes, 0)
    }

    func testTheDayIsNeverCalledOverWhileAMeetingLaterOrWaitingWorkIsLeft() throws {
        let plan = Plan(date: Plan.dayString(Date()), blocks: [block("Report", .done), block("Team call", fixedStart: "13:00")])
        let nine = try XCTUnwrap(plan.clockTime("09:00"))
        XCTAssertEqual(Summary.whatIsNext(plan, at: nine), "Free until the next fixed block.")

        let laterOnly = Plan(date: plan.date, blocks: [block("Report", .done), block("Notes", .skipped)])
        XCTAssertTrue(Summary.whatIsNext(laterOnly, at: nine).hasPrefix("Only Later is left"))

        let waitingOnly = Plan(date: plan.date, blocks: [block("Report", .done), block("Merge", .waiting)])
        XCTAssertEqual(Summary.whatIsNext(waitingOnly, at: nine), "Only work waiting on someone is left.")

        var blockedStep = block("Release", .done, steps: ["Ask Sam for keys"])
        blockedStep.steps[0].status = .blocked
        XCTAssertEqual(Summary.whatIsNext(Plan(date: plan.date, blocks: [blockedStep]), at: nine), "Only work waiting on someone is left.")
    }

    func testReopenRefusesWorkInProgressAndClickingALaterStepBringsItBack() throws {
        var inProgress = block("Fix login bug", .doing, steps: ["Reproduce it"])
        inProgress.startedAt = Date()
        inProgress.steps[0].status = .skipped
        try savePlan([inProgress])

        XCTAssertThrowsError(try run("reopen", "fix login"))
        XCTAssertEqual(planFile.load()?.blocks[0].status, .doing)

        let store = PlanStore(fileURL: planFile.url)
        store.toggleStepDone(0, in: 0)
        XCTAssertEqual(planFile.load()?.blocks[0].steps[0].status, .todo)
    }

    func testSavingTodaysPlanStartsTheDaySoUndoKeepsAPlanMadeAhead() throws {
        let today = Plan.dayString(Date())
        try savePlan(date: Plan.dayString(Date().addingTimeInterval(-24 * 60 * 60)), [block("Fix login bug")])
        try planFile.saveTomorrow(Plan(date: today, blocks: [block("Planned ahead")]))
        let newPlan = home.appendingPathComponent("new.json")
        try #"{"date": "\#(today)", "blocks": [{"title": "Written by Claude", "minutes": 30}]}"#.write(to: newPlan, atomically: true, encoding: .utf8)

        XCTAssertEqual(CommandLineTool.run(["Ise", "save-plan", newPlan.path]), 0)
        XCTAssertTrue(try planFile.undo())

        XCTAssertEqual(planFile.load()?.blocks.map(\.title), ["Planned ahead", "Fix login bug"])
    }

    func testSavePlanReplacesAnUnreadableFileAndLaterLeavesDoneWorkAlone() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "{ not json".write(to: planFile.url, atomically: true, encoding: .utf8)
        let newPlan = home.appendingPathComponent("new.json")
        try #"{"date": "\#(Plan.dayString(Date()))", "blocks": [{"title": "Release notes", "minutes": 30, "status": "done"}]}"#
            .write(to: newPlan, atomically: true, encoding: .utf8)

        XCTAssertEqual(CommandLineTool.run(["Ise", "save-plan", newPlan.path]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("plan.unreadable.json").path))
        XCTAssertThrowsError(try run("later", "release"))
        XCTAssertEqual(planFile.load()?.blocks[0].status, .done)
    }

    func testAPlanWithABadDateIsRefused() throws {
        let file = home.appendingPathComponent("bad.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try #"{"date": "tomorrow", "blocks": []}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CommandLineTool.run(["Ise", "save-plan", file.path]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: planFile.tomorrowURL.path))
    }

    func testANewTaskGoesBeforeALaterLunchWhenItFits() throws {
        var plan = Plan(date: Plan.dayString(Date()), blocks: [block("Lunch", fixedStart: "13:00")])
        let nineInTheMorning = try XCTUnwrap(plan.clockTime("09:00"))

        plan.insertByClock(block("Quick fix"), now: nineInTheMorning)
        plan.insertByClock(block("Afternoon review"), now: nineInTheMorning.addingTimeInterval(4 * 60 * 60))

        XCTAssertEqual(plan.blocks.map(\.title), ["Quick fix", "Lunch", "Afternoon review"])
    }

    func testHooksTrackASessionsOpenTasksAndTickItsLinkedStep() throws {
        let longTask = "Write the test for retries " + String(repeating: "with a very long explanation ", count: 4)
        var linked = block("Payment retries", steps: [SessionHooks.shortSubject(longTask)])
        linked.sessionId = "session-1"
        try savePlan([linked])

        let context = try SessionHooks.handle(hook("SessionStart"), settings: settings)
        _ = try SessionHooks.handle(hook("UserPromptSubmit", prompt: "Add retries to failed payments\nmore detail"), settings: settings)
        _ = try SessionHooks.handle(hook("TaskCreated", taskId: "1", subject: longTask), settings: settings)
        _ = try SessionHooks.handle(hook("TaskCreated", taskId: "2", subject: "Update the docs"), settings: settings)
        _ = try SessionHooks.handle(hook("TaskCompleted", taskId: "1", subject: longTask), settings: settings)

        XCTAssertTrue(try XCTUnwrap(context).contains("session-1"))
        XCTAssertTrue(try XCTUnwrap(context).contains("Payment retries"))
        let session = try XCTUnwrap(SessionsFile(folder: home).load().first)
        XCTAssertEqual(session.title, "Add retries to failed payments")
        XCTAssertEqual(session.openTasks.map(\.subject), ["Update the docs"])
        XCTAssertTrue(session.hasWorkLeft)
        XCTAssertEqual(planFile.load()?.blocks[0].steps[0].status, .done)
    }

    func testASessionThatEndsWithAQuestionHasWorkLeft() throws {
        _ = try SessionHooks.handle(hook("Stop", message: "Done with the fix. Should I open the pull request?"), settings: settings)
        XCTAssertTrue(try XCTUnwrap(SessionsFile(folder: home).load().first).hasWorkLeft)
    }

    private func hook(
        _ event: String, prompt: String? = nil, taskId: String? = nil, subject: String? = nil, message: String? = nil, notificationType: String? = nil
    ) -> HookInput {
        var fields: [String: String] = ["session_id": "session-1", "hook_event_name": event, "cwd": "/tmp/payments"]
        fields["prompt"] = prompt
        fields["task_id"] = taskId
        fields["task_subject"] = subject
        fields["last_assistant_message"] = message
        fields["notification_type"] = notificationType
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(HookInput.self, from: data)
    }
}
