import XCTest
import CapydokuCore
@testable import Capydoku

final class GenerationAuditIntegrationTests: XCTestCase {
    private func directory() -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("audit-integration-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    @MainActor private func model(_ directory: URL) -> AppModel {
        let value = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        value.progress.tutorialCompleted = true
        return value
    }
    @MainActor private func generate(_ app: AppModel, level: Int) async throws {
        app.errorMessage = nil; app.start(level: level)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while app.loading && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(app.loading)
        app.flushPendingSaves()
    }
    private struct Export: Decodable {
        let generationReport: GenerationPipelineReport?
        let currentBoardGenerationReport: GenerationPipelineReport?
        let generationAuditIssues: [String]
        let generationReportScope: String
    }
    @MainActor func testInvalidSimilarityConfigurationPreservesPlayableBoard() throws {
        let app = AppModel(saveDirectory: directory(), runsTimer: false, feedbackEnabled: false,
            generationSimilarityData: Data("{\"threshold\":-1}".utf8))
        app.progress.tutorialCompleted = true
        app.start(level: 2)
        let before = app.progress
        XCTAssertNotNil(app.session)
        app.start(level: 151)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertFalse(app.loading)
        XCTAssertEqual(app.progress, before)
        XCTAssertNil(app.lastGenerationReport)
    }
    @MainActor func testV3InProgressBoardSurvivesV4PackUpgrade() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels-legacy-v3", withExtension: "json"))
        let oldPack = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
        let currentURL = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        let currentPack = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: currentURL))
        let oldBoard = try XCTUnwrap(oldPack.first { old in currentPack.contains { $0.id == old.id && $0 != old } })
        let directory = directory()
        let oldApp = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false, bundledPuzzles: oldPack)
        oldApp.progress.tutorialCompleted = true
        oldApp.start(level: oldBoard.id)
        let mark = try XCTUnwrap(oldBoard.regions.indices.first { !oldBoard.solution.contains($0) })
        oldApp.toggle(mark)
        oldApp.save(force: true)
        XCTAssertTrue(oldApp.session?.marks.contains(mark) == true)
        let before = oldApp.progress
        let upgraded = model(directory)
        XCTAssertEqual(upgraded.progress, before)
        XCTAssertEqual(upgraded.session?.puzzle, oldBoard)
        let fresh = model(self.directory())
        fresh.start(level: oldBoard.id)
        XCTAssertEqual(fresh.session?.puzzle, currentPack.first { $0.id == oldBoard.id })
        XCTAssertNotEqual(fresh.session?.puzzle, oldBoard)
    }
    @MainActor private func export(_ app: AppModel) throws -> Export {
        app.exportDiagnostics()
        let data = try Data(contentsOf: XCTUnwrap(app.exportURL))
        return try JSONDecoder().decode(Export.self, from: data)
    }

    @MainActor func testColdExportRetainsSuccessfulBoardAndLaterRejectedBatchSeparately() async throws {
        let directory = directory(), warm = model(directory)
        try await generate(warm, level: 151)
        XCTAssertNil(warm.errorMessage)
        let accepted = try XCTUnwrap(warm.lastGenerationReport)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "similarity-config", withExtension: "json"))
        let configuration = try SimilarityConfiguration.decode(Data(contentsOf: url))
        XCTAssertEqual(accepted.selectedSimilarityReport?.configurationVersion, configuration.version)
        XCTAssertNotNil(accepted.selectedQualityReport)
        XCTAssertNotNil(accepted.selectedSolverReport?.deductionTrace)
        let board = try XCTUnwrap(warm.session?.puzzle)
        let before = warm.progress
        warm.config.generatorCandidateLimit = 1 // Applies only to the next generation, not the saved current session.
        try await generate(warm, level: 152)
        XCTAssertNotNil(warm.errorMessage)
        XCTAssertEqual(warm.progress, before)
        let rejected = try XCTUnwrap(warm.lastGenerationReport)
        XCTAssertEqual(rejected.termination, "insufficient_candidate_budget")
        XCTAssertNil(try GenerationAuditStore(directory: directory).latest()?.puzzle)

        let cold = model(directory)
        XCTAssertNil(cold.lastGenerationReport, "The export must recover durable evidence without relying on old process memory.")
        XCTAssertEqual(cold.session?.puzzle, board)
        let report = try export(cold)
        let attachment = XCTAttachment(data: try Data(contentsOf: XCTUnwrap(cold.exportURL)), uniformTypeIdentifier: "public.json")
        attachment.name = "cold-generation-diagnostics-selected-and-rejected"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(report.generationReport, rejected)
        XCTAssertEqual(report.currentBoardGenerationReport, accepted)
        XCTAssertTrue(report.generationAuditIssues.isEmpty)
        XCTAssertTrue(report.generationReportScope.contains("may differ"))
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("progress.json"))) as! [String: Any]
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        let state = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        XCTAssertNil(state["generationReport"])
        XCTAssertNil(state["currentBoardGenerationReport"])
        XCTAssertNil((state["session"] as? [String: Any])?["puzzle"])
    }

    @MainActor func testReportWriteFailureDoesNotPublishBoardOrConsumeAttemptOrHistory() async throws {
        let directory = directory(), app = model(directory)
        app.start(level: 2); app.progress.bonusHints = 3; app.save(force: true)
        let before = app.progress
        let blocked = directory.appendingPathComponent("GenerationReports")
        let obstruction = Data("existing file obstructs report directory".utf8)
        try obstruction.write(to: blocked)
        try await generate(app, level: 151)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertEqual(app.progress, before)
        XCTAssertNil(app.progress.attemptCounts["151"])
        XCTAssertNil(app.progress.experimentalHistoryCheckpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("experimental-history.json").path))
        XCTAssertEqual(try Data(contentsOf: blocked), obstruction)
        XCTAssertEqual(model(directory).progress, before)
    }

    @MainActor func testMissingOrCorruptOldReportDoesNotAlterBoardOrInventEvidence() async throws {
        let directory = directory(), app = model(directory)
        try await generate(app, level: 151)
        XCTAssertNil(app.errorMessage)
        let before = app.progress
        let reports = directory.appendingPathComponent("GenerationReports")
        let indexes = try FileManager.default.contentsOfDirectory(at: reports.appendingPathComponent("boards"), includingPropertiesForKeys: nil)
        XCTAssertEqual(indexes.count, 1)
        let corrupt = Data("corrupt generation report".utf8)
        try corrupt.write(to: XCTUnwrap(indexes.first), options: .atomic)
        let cold = model(directory)
        let damaged = try export(cold)
        XCTAssertNil(damaged.currentBoardGenerationReport)
        XCTAssertTrue(damaged.generationAuditIssues.contains { $0.contains("could not be verified") })
        XCTAssertEqual(cold.progress, before)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(indexes.first)), corrupt)
        try FileManager.default.removeItem(at: reports)
        let legacy = model(directory), missing = try export(legacy)
        XCTAssertNil(missing.generationReport)
        XCTAssertNil(missing.currentBoardGenerationReport)
        XCTAssertTrue(missing.generationAuditIssues.contains { $0.contains("No generation audit is available") })
        XCTAssertEqual(legacy.progress, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reports.path))
    }

    @MainActor func testSavedCandidateReportIsNotMisattributedAfterPlayerCommitFails() async throws {
        let directory = directory(), app = model(directory)
        try await generate(app, level: 151)
        XCTAssertNil(app.errorMessage)
        let before = app.progress, playedReport = try XCTUnwrap(app.lastGenerationReport)
        let primary = directory.appendingPathComponent("progress.json")
        let bytes = try Data(contentsOf: primary)
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        try await generate(app, level: 152)
        XCTAssertNotNil(app.errorMessage)
        XCTAssertEqual(app.progress, before)
        let candidateReport = try XCTUnwrap(app.lastGenerationReport)
        XCTAssertEqual(candidateReport.target.levelID, 152)
        try FileManager.default.removeItem(at: primary)
        try bytes.write(to: primary, options: .atomic)
        let cold = model(directory), result = try export(cold)
        XCTAssertEqual(cold.progress, before)
        XCTAssertEqual(result.generationReport, candidateReport)
        XCTAssertEqual(result.currentBoardGenerationReport, playedReport)
        XCTAssertTrue(result.generationAuditIssues.isEmpty)
    }
}
