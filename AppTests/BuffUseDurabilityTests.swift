import XCTest
import CapydokuCore
@testable import Capydoku

private final class DurableBuffIdentity: AnalyticsIdentityStore {
    var value: AnalyticsIdentity?
    func load() -> AnalyticsIdentity? { value }
    func save(_ identity: AnalyticsIdentity) -> Bool { value = identity; return true }
}

private final class DurableBuffRewards: RewardProvider {
    var requests: [(String, (RewardSignal) -> Void)] = []
    func present(offerID: String, completion: @escaping (RewardSignal) -> Void) {
        requests.append((offerID, completion))
    }
}

final class BuffUseDurabilityTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("buff-durability-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func model(_ directory: URL, identity: DurableBuffIdentity = DurableBuffIdentity(),
                                  hints: Int = 2, direct: Int = 2, consent: Bool = true,
                                  asyncSaves: Bool = false, rewards: DurableBuffRewards? = nil) -> AppModel {
        let feedback = FeedbackPlayer(manifest: .silent, resourceResolver: { _ in nil },
                                      playerFactory: { _ in nil }, sessionControl: { _ in true }, observeSystem: false)
        let app = AppModel(saveDirectory: directory, rewardProvider: rewards, runsTimer: asyncSaves, feedbackEnabled: false,
                           analyticsIdentityStore: identity, feedbackPlayer: feedback)
        if consent { app.consentAccepted() }
        app.progress.tutorialCompleted = true
        app.config = DemoConfig(hintsPerLevel: hints, directPerLevel: direct)
        if app.session == nil { app.start(level: 1) }
        app.notice = nil
        return app
    }
    @MainActor private func uses(_ app: AppModel, type: String? = nil) -> [AnalyticsRecorder.Event] {
        app.analytics.events.filter { $0.eventName == "buff_use" && (type == nil || $0.parameters["buff_type"] == .text(type!)) }
    }
    @MainActor private func store(_ app: AppModel) throws -> SaveStore {
        let puzzle = try XCTUnwrap(app.session?.puzzle)
        return SaveStore(directory: app.saveDirectory, packagedPuzzle: { $0 == puzzle.id ? puzzle : nil })
    }
    private func block(_ url: URL) throws -> Data {
        let previous = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return previous
    }
    private func unblock(_ url: URL, restoring data: Data) throws {
        try FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
    }
    private func prepared(_ progress: PlayerProgress) throws -> [AnalyticsRecorder.PreparedEvent] {
        try progress.pendingBuffEvents.values.map { try JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: $0) }
    }
    private func assertSameEvent(_ actual: AnalyticsRecorder.Event, _ original: AnalyticsRecorder.Event,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.eventID, original.eventID, file: file, line: line)
        XCTAssertEqual(actual.eventName, original.eventName, file: file, line: line)
        XCTAssertEqual(actual.eventTime, original.eventTime, file: file, line: line)
        XCTAssertEqual(actual.userID, original.userID, file: file, line: line)
        XCTAssertEqual(actual.sessionID, original.sessionID, file: file, line: line)
        XCTAssertEqual(actual.levelID, original.levelID, file: file, line: line)
        XCTAssertEqual(actual.pawdokuConfigVersion, original.pawdokuConfigVersion, file: file, line: line)
        XCTAssertEqual(actual.parameters, original.parameters, file: file, line: line)
        XCTAssertEqual(actual.environment, original.environment, file: file, line: line)
    }

    @MainActor func testDirectProgressWriteFailureRollsBackInventoryBoardAndEvent() async throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity)
        app.flushPendingSaves()
        let before = app.progress
        let primary = directory.appendingPathComponent("progress.json"), previous = try block(primary)
        app.direct()
        XCTAssertEqual(app.progress, before)
        XCTAssertTrue(uses(app).isEmpty)
        XCTAssertNotNil(app.errorMessage)
        try unblock(primary, restoring: previous)
        app.errorMessage = nil
        try await Task.sleep(nanoseconds: 420_000_000)
        app.direct(); app.direct()
        XCTAssertEqual(app.session?.found.count, 1)
        XCTAssertEqual(app.progress.availableDirect, before.availableDirect - 1)
        XCTAssertEqual(uses(app, type: "direct_find").count, 1)
        let restored = model(directory, identity: identity)
        XCTAssertEqual(restored.session, app.session)
        XCTAssertEqual(restored.progress.availableDirect, app.progress.availableDirect)
        XCTAssertEqual(uses(restored, type: "direct_find").count, 1)
    }

    @MainActor func testHintPreparationWriteFailureDoesNotConsumePublishOrReportPreview() throws {
        let directory = directory(), app = model(directory)
        let before = app.progress
        let primary = directory.appendingPathComponent("progress.json"), previous = try block(primary)
        app.showHint()
        XCTAssertEqual(app.progress, before)
        XCTAssertNil(app.hint)
        XCTAssertNil(app.progress.activeHintUse)
        XCTAssertTrue(uses(app).isEmpty)
        XCTAssertNotNil(app.errorMessage)
        try unblock(primary, restoring: previous)
        app.errorMessage = nil
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse)
        XCTAssertEqual(app.hint, use.hint)
        XCTAssertFalse(use.previewPresented)
        XCTAssertEqual(use.inventoryBefore, before.availableHints)
        XCTAssertEqual(use.inventoryAfter, before.availableHints - 1)
        XCTAssertEqual(app.progress.availableHints, before.availableHints - 1)
        XCTAssertEqual(app.session?.marks, before.session?.marks)
        XCTAssertTrue(uses(app).isEmpty, "Preparing a preview is not evidence that its UI was displayed.")
    }

    @MainActor func testActualAppearanceWriteFailureLeavesPreviewUnreportedAndRetryable() throws {
        let directory = directory(), app = model(directory)
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse), before = app.progress
        let primary = directory.appendingPathComponent("progress.json"), previous = try block(primary)
        app.hintDidAppear(useID: use.id)
        XCTAssertEqual(app.progress, before)
        XCTAssertEqual(app.hint, use.hint)
        XCTAssertEqual(app.progress.activeHintUse?.previewPresented, false)
        XCTAssertTrue(uses(app).isEmpty)
        try unblock(primary, restoring: previous)
        app.errorMessage = nil
        app.hintDidAppear(useID: use.id); app.hintDidAppear(useID: use.id)
        XCTAssertEqual(app.progress.activeHintUse?.previewPresented, true)
        XCTAssertEqual(uses(app, type: "hint").count, 1)
        XCTAssertEqual(uses(app).first?.parameters["applied"], .flag(false))
        XCTAssertEqual(app.progress.availableHints, before.availableHints)
        XCTAssertEqual(try store(app).load().progress.activeHintUse?.previewPresented, true)
    }

    @MainActor func testApplyWriteFailurePreservesSavedPreviewAndDoesNotPublishMarksOrAppliedEvent() throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity)
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse)
        app.hintDidAppear(useID: use.id)
        let before = app.progress
        let primary = directory.appendingPathComponent("progress.json"), previous = try block(primary)
        app.applyHint()
        XCTAssertEqual(app.progress, before)
        XCTAssertEqual(app.hint, use.hint)
        XCTAssertEqual(uses(app).map { $0.parameters["applied"] }, [.flag(false)])
        XCTAssertNotNil(app.errorMessage)
        try unblock(primary, restoring: previous)
        app.errorMessage = nil
        app.applyHint(); app.applyHint()
        XCTAssertTrue(Set(use.hint.cells).isSubset(of: try XCTUnwrap(app.session?.marks)))
        XCTAssertNil(app.progress.activeHintUse)
        XCTAssertNil(app.hint)
        XCTAssertEqual(app.progress.availableHints, before.availableHints)
        XCTAssertEqual(uses(app).map { $0.parameters["applied"] }, [.flag(false), .flag(true)])
        let restored = model(directory, identity: identity)
        XCTAssertEqual(restored.session, app.session)
        XCTAssertNil(restored.progress.activeHintUse)
    }

    @MainActor func testDirectQueueFailureAndLostAcknowledgementKeepFrozenEventAndSingleEffect() throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity)
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), previous = try block(queue)
        app.direct()
        let beforeAcknowledgement = try store(app).load().progress
        XCTAssertEqual(beforeAcknowledgement.session?.found.count, 1)
        XCTAssertEqual(beforeAcknowledgement.availableDirect, 1)
        let frozen = try XCTUnwrap(try prepared(beforeAcknowledgement).first)
        XCTAssertEqual(beforeAcknowledgement.pendingBuffEvents.count, 1)
        try unblock(queue, restoring: previous)
        let recovered = model(directory, identity: identity)
        assertSameEvent(try XCTUnwrap(uses(recovered).first), frozen.event)
        XCTAssertNotEqual(frozen.event.sessionID, recovered.analytics.events.last { $0.eventName == "session_start" }?.sessionID)
        XCTAssertEqual(recovered.session?.found.count, 1)
        XCTAssertEqual(recovered.progress.availableDirect, 1)
        XCTAssertTrue(recovered.progress.pendingBuffEvents.isEmpty)
        try store(recovered).save(beforeAcknowledgement)
        let again = model(directory, identity: identity)
        XCTAssertEqual(uses(again).count, 1)
        assertSameEvent(try XCTUnwrap(uses(again).first), frozen.event)
        XCTAssertEqual(again.session?.found.count, 1)
        XCTAssertEqual(again.progress.availableDirect, 1)
        XCTAssertTrue(again.progress.pendingBuffEvents.isEmpty)
    }

    @MainActor func testHintPreviewAndApplyQueueFailureRecoverOriginalEventsWithoutReapplying() throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity)
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse)
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), previous = try block(queue)
        app.hintDidAppear(useID: use.id)
        app.applyHint()
        let beforeAcknowledgement = try store(app).load().progress
        let frozen = try prepared(beforeAcknowledgement)
        XCTAssertEqual(frozen.count, 2)
        XCTAssertNil(beforeAcknowledgement.activeHintUse)
        XCTAssertEqual(Set(frozen.compactMap { $0.event.parameters["applied"] == .flag(true) ? "apply" : "preview" }), ["preview", "apply"])
        try unblock(queue, restoring: previous)
        let recovered = model(directory, identity: identity)
        XCTAssertEqual(uses(recovered).count, 2)
        for original in frozen {
            assertSameEvent(try XCTUnwrap(uses(recovered).first { $0.eventID == original.event.eventID }), original.event)
        }
        XCTAssertEqual(recovered.session?.marks, beforeAcknowledgement.session?.marks)
        XCTAssertEqual(recovered.progress.availableHints, 1)
        XCTAssertNil(recovered.hint)
        XCTAssertNil(recovered.progress.activeHintUse)
        XCTAssertTrue(recovered.progress.pendingBuffEvents.isEmpty)
        try store(recovered).save(beforeAcknowledgement)
        let again = model(directory, identity: identity)
        XCTAssertEqual(uses(again).count, 2)
        XCTAssertEqual(Set(uses(again).map(\.eventID)), Set(frozen.map { $0.event.eventID }))
        XCTAssertTrue(again.progress.pendingBuffEvents.isEmpty)
        XCTAssertEqual(again.session?.marks, beforeAcknowledgement.session?.marks)
    }

    @MainActor func testFinalRewardedDirectCommitsUsageAndWinTogetherBeforeImmediateColdStart() throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity, direct: 0)
        let puzzle = try XCTUnwrap(app.session?.puzzle)
        for cell in puzzle.solution.dropLast() { app.submit(cell) }
        let store = try store(app), offer = UUID().uuidString
        XCTAssertTrue(try store.prepareReward(offerID: offer, kind: .direct, progress: &app.progress))
        let outcome = try store.grantReward(offerID: offer, progress: &app.progress) { candidate, result in
            app.finalizeRewardResult(result, in: &candidate, offerID: offer)
        }
        guard case .directRevealed = outcome else { return XCTFail("Expected the last answer from the committed direct reward.") }
        // Stop exactly at the reward transaction commit. No AppModel afterAction,
        // ordinary save, UI refresh or analytics-delivery call is allowed here.
        let committed = store.load().progress
        XCTAssertEqual(committed.session?.status, .won)
        XCTAssertEqual(committed.session?.resultPhaseEnd, .win)
        XCTAssertEqual(committed.rewardLedger[offer]?.state, .executed)
        XCTAssertTrue(committed.completedLevels.contains(1))
        XCTAssertEqual(committed.unlockedLevel, 2)
        XCTAssertEqual(committed.pendingBuffEvents.count, 1)
        XCTAssertEqual(committed.pendingLevelResultEvents.count, 1)
        XCTAssertTrue(uses(app).isEmpty)
        let recovered = model(directory, identity: identity, direct: 0)
        let events = recovered.analytics.events
        let buffIndex = try XCTUnwrap(events.firstIndex { $0.eventName == "buff_use" })
        let winIndex = try XCTUnwrap(events.firstIndex { $0.eventName == "level_end" && $0.parameters["result"] == .text("win") })
        XCTAssertLessThan(buffIndex, winIndex)
        XCTAssertEqual(events[buffIndex].parameters["source"], .text("rewarded_ad"))
        XCTAssertEqual(events[buffIndex].parameters["applied"], .flag(true))
        XCTAssertEqual(uses(recovered).count, 1)
        XCTAssertEqual(recovered.session?.puzzle, puzzle)
        XCTAssertTrue(recovered.progress.pendingBuffEvents.isEmpty)
        XCTAssertTrue(recovered.progress.pendingLevelResultEvents.isEmpty)
        XCTAssertTrue(recovered.progress.completedLevels.contains(1))
    }

    @MainActor func testPreparedHintColdRestorePreservesPreviewButHomeAndBackgroundAreNotDisplayEvidence() throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity)
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse), balance = app.progress.availableHints
        let originalMarks = app.session?.marks
        let restored = model(directory, identity: identity)
        XCTAssertEqual(restored.screen, .home)
        XCTAssertNil(restored.hint)
        XCTAssertEqual(restored.progress.activeHintUse, use)
        restored.hintDidAppear(useID: use.id)
        XCTAssertTrue(uses(restored).isEmpty)
        XCTAssertEqual(restored.progress.activeHintUse?.previewPresented, false)
        restored.startOrContinue()
        XCTAssertEqual(restored.hint, use.hint)
        XCTAssertEqual(restored.progress.activeHintUse?.id, use.id)
        XCTAssertEqual(restored.progress.availableHints, balance)
        restored.setActive(false)
        restored.hintDidAppear(useID: use.id)
        XCTAssertTrue(uses(restored).isEmpty)
        restored.setActive(true)
        restored.hintDidAppear(useID: UUID())
        XCTAssertTrue(uses(restored).isEmpty)
        restored.hintDidAppear(useID: use.id); restored.hintDidAppear(useID: use.id)
        XCTAssertEqual(uses(restored).count, 1)
        XCTAssertEqual(restored.progress.activeHintUse?.previewPresented, true)
        XCTAssertEqual(restored.progress.availableHints, balance)
        XCTAssertEqual(restored.session?.marks, originalMarks)
    }

    @MainActor func testDisplayedHintColdReentryAndCloseDoNotDeductRefundOrDuplicatePreview() throws {
        for appeared in [false, true] {
            let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity)
            app.showHint()
            let use = try XCTUnwrap(app.progress.activeHintUse), balance = app.progress.availableHints
            if appeared { app.hintDidAppear(useID: use.id) }
            let restored = model(directory, identity: identity)
            restored.startOrContinue()
            XCTAssertEqual(restored.hint, use.hint)
            if appeared {
                restored.hintDidAppear(useID: use.id)
                XCTAssertEqual(uses(restored).count, 1)
            }
            XCTAssertTrue(restored.closeHint(), "A real close action itself proves the preview was visible.")
            _ = restored.closeHint()
            restored.hintDidAppear(useID: use.id)
            XCTAssertNil(restored.hint)
            XCTAssertNil(restored.progress.activeHintUse)
            XCTAssertEqual(restored.progress.availableHints, balance)
            XCTAssertEqual(uses(restored).map { $0.parameters["applied"] }, [.flag(false)])
            let again = model(directory, identity: identity)
            again.startOrContinue()
            XCTAssertNil(again.hint)
            XCTAssertNil(again.progress.activeHintUse)
            XCTAssertEqual(again.progress.availableHints, balance)
            XCTAssertEqual(uses(again).count, 1)
        }
    }

    @MainActor func testApplyConfirmsFirstDisplayOnceButCannotReportApplicationWhenNoMarksChange() throws {
        let app = model(directory())
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse), balance = app.progress.availableHints
        app.applyHint(); app.applyHint(); app.hintDidAppear(useID: use.id)
        XCTAssertTrue(Set(use.hint.cells).isSubset(of: try XCTUnwrap(app.session?.marks)))
        XCTAssertEqual(uses(app).map { $0.parameters["applied"] }, [.flag(false), .flag(true)])
        XCTAssertEqual(app.progress.availableHints, balance)
        XCTAssertNil(app.progress.activeHintUse)

        let stale = model(directory())
        stale.showHint()
        let alreadyMarked = try XCTUnwrap(stale.progress.activeHintUse)
        stale.hintDidAppear(useID: alreadyMarked.id)
        // A legitimately saved preview may become redundant after another state
        // update; this fixture exercises the real markMany change-count guard.
        _ = stale.progress.session?.markMany(alreadyMarked.hint.cells)
        stale.save()
        let marks = stale.session?.marks
        stale.applyHint(); stale.applyHint()
        XCTAssertEqual(stale.session?.marks, marks)
        XCTAssertFalse(uses(stale).contains { $0.parameters["applied"] == .flag(true) })
        XCTAssertEqual(stale.progress.availableHints, 1)
    }

    @MainActor func testPreConsentActualUsesNeverBackfillButLaterRealApplyIsANewFact() throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity, consent: false)
        app.direct()
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse)
        app.hintDidAppear(useID: use.id)
        XCTAssertEqual(app.progress.activeHintUse?.previewPresented, true)
        XCTAssertTrue(app.progress.pendingBuffEvents.isEmpty)
        XCTAssertTrue(app.analytics.events.isEmpty)
        app.consentAccepted()
        app.hintDidAppear(useID: use.id)
        XCTAssertTrue(uses(app).isEmpty)
        app.applyHint(); app.applyHint()
        XCTAssertEqual(uses(app).count, 1)
        XCTAssertEqual(uses(app).first?.parameters["buff_type"], .text("hint"))
        XCTAssertEqual(uses(app).first?.parameters["applied"], .flag(true))
        let restored = model(directory, identity: identity)
        XCTAssertEqual(uses(restored).count, 1)
        XCTAssertTrue(uses(restored, type: "direct_find").isEmpty)
    }

    @MainActor func testHintPreparedBeforeConsentCanRecordItsFirstActualDisplayAfterConsent() throws {
        let app = model(directory(), consent: false)
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse)
        XCTAssertFalse(use.previewPresented)
        XCTAssertTrue(app.analytics.events.isEmpty)
        app.consentAccepted()
        let acceptedBy = Date()
        let session = try XCTUnwrap(app.analytics.events.last { $0.eventName == "session_start" }?.sessionID)
        app.hintDidAppear(useID: use.id); app.hintDidAppear(useID: use.id)
        let event = try XCTUnwrap(uses(app).first)
        XCTAssertEqual(uses(app).count, 1)
        XCTAssertGreaterThanOrEqual(event.eventTime, acceptedBy)
        XCTAssertEqual(event.sessionID, session)
        XCTAssertEqual(event.parameters["applied"], .flag(false))
        XCTAssertEqual(event.parameters["inventory_before"], .integer(use.inventoryBefore))
        XCTAssertEqual(event.parameters["inventory_after"], .integer(use.inventoryAfter))
    }

    @MainActor func testUnknownLegacySourceRemainsUsableWithoutInventingBuffAttribution() throws {
        let directory = directory(), identity = DurableBuffIdentity()
        let app = model(directory, identity: identity, hints: 0, direct: 0)
        app.progress.bonusHints = 1
        app.progress.bonusDirect = 1
        app.save()
        let restored = model(directory, identity: identity, hints: 0, direct: 0)
        restored.startOrContinue()
        XCTAssertNil(restored.progress.nextDirectSource)
        restored.direct()
        XCTAssertEqual(restored.session?.found.count, 1)
        restored.showHint()
        let use = try XCTUnwrap(restored.progress.activeHintUse)
        XCTAssertNil(use.source)
        restored.hintDidAppear(useID: use.id)
        restored.applyHint(); restored.applyHint()
        XCTAssertEqual(restored.progress.availableHints, 0)
        XCTAssertEqual(restored.progress.availableDirect, 0)
        XCTAssertTrue(uses(restored).isEmpty)
        XCTAssertTrue(restored.progress.pendingBuffEvents.isEmpty)
        XCTAssertTrue(Set(use.hint.cells).isSubset(of: try XCTUnwrap(restored.session?.marks)))
    }

    @MainActor func testProductionAsyncSnapshotsCannotOverwriteCommittedUsesAcrossImmediateNavigation() async throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity, asyncSaves: true)
        let cell = try XCTUnwrap(app.session?.puzzle.regions.indices.first)
        for _ in 0..<12 { app.toggle(cell); app.toggle(cell) }
        app.direct()
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse)
        app.hintDidAppear(useID: use.id)
        app.applyHint()
        app.home(); app.start(level: 2)
        app.flushPendingSaves()
        try await Task.sleep(nanoseconds: 70_000_000)
        app.flushPendingSaves()
        app.setActive(false)
        let restored = model(directory, identity: identity)
        XCTAssertEqual(restored.session?.puzzle.id, 2)
        XCTAssertNil(restored.progress.activeHintUse)
        XCTAssertTrue(restored.progress.pendingBuffEvents.isEmpty)
        XCTAssertEqual(uses(restored, type: "direct_find").count, 1)
        XCTAssertEqual(uses(restored, type: "hint").map { $0.parameters["applied"] }, [.flag(false), .flag(true)])
        XCTAssertEqual(Set(uses(restored).map(\.eventID)).count, 3)
        XCTAssertTrue(uses(restored).allSatisfy { $0.levelID == 1 })
        let current = restored.session
        restored.startOrContinue()
        restored.hintDidAppear(useID: use.id); restored.applyHint()
        XCTAssertEqual(restored.session, current)
        XCTAssertNil(restored.hint)
        XCTAssertEqual(uses(restored).count, 3)
        XCTAssertNil(restored.errorMessage)
    }

    @MainActor func testClosingRecoveredDeveloperSheetRestoresPendingPreviewWithoutAnotherConsumption() throws {
        let app = model(directory())
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse)
        app.sheet = .debug
        app.loadProgress()
        XCTAssertNil(app.hint)
        XCTAssertEqual(app.progress.activeHintUse, use)
        XCTAssertTrue(uses(app).isEmpty)
        app.sheet = nil
        XCTAssertEqual(app.hint, use.hint)
        XCTAssertEqual(app.progress.availableHints, use.inventoryAfter)
        app.hintDidAppear(useID: use.id)
        XCTAssertEqual(uses(app).count, 1)
        app.applyHint()
        XCTAssertTrue(Set(use.hint.cells).isSubset(of: try XCTUnwrap(app.session?.marks)))
    }

    @MainActor func testCloseWriteFailureKeepsSamePreviewUntilItsDismissalIsSaved() throws {
        let directory = directory(), identity = DurableBuffIdentity(), app = model(directory, identity: identity)
        app.showHint()
        let use = try XCTUnwrap(app.progress.activeHintUse)
        app.hintDidAppear(useID: use.id)
        let primary = directory.appendingPathComponent("progress.json"), previous = try block(primary)
        XCTAssertFalse(app.closeHint())
        XCTAssertEqual(app.hint, use.hint)
        XCTAssertEqual(app.progress.activeHintUse?.id, use.id)
        XCTAssertEqual(app.progress.availableHints, use.inventoryAfter)
        XCTAssertEqual(uses(app).count, 1)
        try unblock(primary, restoring: previous)
        app.errorMessage = nil
        XCTAssertTrue(app.closeHint())
        let restored = model(directory, identity: identity)
        restored.startOrContinue()
        XCTAssertNil(restored.hint)
        XCTAssertNil(restored.progress.activeHintUse)
        XCTAssertEqual(restored.progress.availableHints, use.inventoryAfter)
        XCTAssertEqual(restored.session?.marks, [])
        XCTAssertEqual(uses(restored).count, 1)
        XCTAssertEqual(uses(restored).first?.parameters["applied"], .flag(false))
    }

    @MainActor func testActualRewardOfferPreservesAttributionAcrossSessionChangeQueueFailureAndColdRecovery() async throws {
        let directory = directory(), identity = DurableBuffIdentity(), rewards = DurableBuffRewards()
        let app = model(directory, identity: identity, hints: 0, direct: 0, rewards: rewards)
        for cell in try XCTUnwrap(app.session?.puzzle.solution).dropLast() { app.submit(cell) }
        app.offer(.direct)
        let request = try XCTUnwrap(rewards.requests.last)
        let record = try XCTUnwrap(app.progress.rewardLedger[request.0])
        let offer = try JSONDecoder().decode(AnalyticsRecorder.PreparedEvent.self, from: XCTUnwrap(record.analyticsOffer))
        app.analytics.endSession(reason: "quit")
        app.analytics.beginSession(source: "resume")
        XCTAssertNotEqual(app.analytics.events.last { $0.eventName == "session_start" }?.sessionID, offer.event.sessionID)
        let queue = directory.appendingPathComponent("analytics-demo-queue.json"), previous = try block(queue)
        request.1(.started); request.1(.earned); request.1(.earned)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(app.session?.status, .won)
        let saved = try store(app).load().progress
        XCTAssertEqual(saved.rewardLedger[request.0]?.state, .executed)
        let frozen = try XCTUnwrap(try prepared(saved).first)
        XCTAssertEqual(frozen.event.sessionID, offer.event.sessionID)
        XCTAssertEqual(frozen.event.userID, offer.event.userID)
        XCTAssertEqual(frozen.event.levelID, offer.event.levelID)
        XCTAssertEqual(frozen.event.pawdokuConfigVersion, offer.event.pawdokuConfigVersion)
        XCTAssertEqual(frozen.event.parameters["source"], .text("rewarded_ad"))
        try unblock(queue, restoring: previous)
        let restored = model(directory, identity: identity)
        assertSameEvent(try XCTUnwrap(uses(restored).first), frozen.event)
        XCTAssertEqual(uses(restored).count, 1)
        XCTAssertEqual(restored.session?.status, .won)
        XCTAssertTrue(restored.progress.pendingBuffEvents.isEmpty)
        let completionIndex = try XCTUnwrap(restored.analytics.events.firstIndex {
            $0.eventName == "ad_result" && $0.parameters["offer_id"] == .text(request.0) && $0.parameters["status"] == .text("completed")
        })
        let useIndex = try XCTUnwrap(restored.analytics.events.firstIndex { $0.eventID == frozen.event.eventID })
        let winIndex = try XCTUnwrap(restored.analytics.events.firstIndex { $0.eventName == "level_end" && $0.parameters["result"] == .text("win") })
        XCTAssertLessThan(completionIndex, useIndex)
        XCTAssertLessThan(useIndex, winIndex)
    }
}
