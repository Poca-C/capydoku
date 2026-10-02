import XCTest
import CryptoKit
@testable import CapydokuCore

final class PuzzleSimilarityConfigurationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func board(legacy: Bool = false, level: Int = 1) throws -> Puzzle {
        let file = legacy ? "levels-legacy-v2.json" : "levels.json"
        let all = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: root.appendingPathComponent("Resources/" + file)))
        return try XCTUnwrap(all.first { $0.id == level })
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testGlobalConfigurationAndLegacyDefaultsAreExplicitlyUncalibrated() throws {
        let bytes = try Data(contentsOf: root.appendingPathComponent("Resources/similarity-config.json"))
        let global = try SimilarityConfiguration.decode(bytes)
        XCTAssertEqual(global, .strict)
        XCTAssertEqual(global.provenance, "local demo, uncalibrated")
        XCTAssertFalse(global.crossProductCorpusAvailable)
        XCTAssertTrue(global.validationErrors.isEmpty)
        let legacy = Data(#"{"version":"original-ch3-strict-v1","threshold":0.9,"strictOriginalHardRejections":true,"crossProductCorpusAvailable":false}"#.utf8)
        let decoded = try SimilarityConfiguration.decode(legacy)
        XCTAssertEqual(decoded.version, "original-ch3-strict-v1")
        XCTAssertEqual(decoded.weights, .legacy)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.provenance, global.provenance)
        XCTAssertFalse(decoded.crossProductCorpusAvailable)
    }

    func testMalformedGlobalConfigurationFailsClosed() throws {
        let good = try object(SimilarityConfiguration.strict)
        var cases: [[String: Any]] = []
        for threshold in [0.0, -0.1, 1.01] {
            var value = good; value["threshold"] = threshold; cases.append(value)
        }
        var negative = good
        negative["weights"] = ["regionGraph": -0.1, "regionSizeDistribution": 0.5, "answerPattern": 0.5, "openingState": 0.1]
        cases.append(negative)
        var wrongTotal = good
        wrongTotal["weights"] = ["regionGraph": 0.4, "regionSizeDistribution": 0.4, "answerPattern": 0.4, "openingState": 0.4]
        cases.append(wrongTotal)
        var future = good; future["schemaVersion"] = 99; cases.append(future)
        var disabled = good; disabled["strictOriginalHardRejections"] = false; cases.append(disabled)
        for value in cases { XCTAssertThrowsError(try SimilarityConfiguration.decode(data(value))) }
        var mutated = SimilarityConfiguration.strict
        mutated.weights.openingState = .nan
        XCTAssertFalse(mutated.validationErrors.isEmpty)
        XCTAssertFalse(PuzzleSimilarity.evaluate(try board(), corpus: [], configuration: mutated).accepted)
    }

    func testCanonicalLabelsAndEveryOriginalHardRejectionIgnoreWeights() throws {
        let puzzle = try board()
        var relabeled = puzzle
        relabeled.regions = puzzle.regions.map { 100 + (puzzle.size - 1 - $0) * 7 }
        XCTAssertEqual(PuzzleFingerprint(puzzle: puzzle), PuzzleFingerprint(puzzle: relabeled))
        var configuration = SimilarityConfiguration.strict
        configuration.threshold = 1
        configuration.weights = .init(regionGraph: 0, regionSizeDistribution: 1, answerPattern: 0, openingState: 0)
        let original = SimilarityCorpusEntry(game: "CapyDoku", puzzle: puzzle)
        var onlyAnswer = original
        onlyAnswer.fingerprint.regionGraph = Array(repeating: -1, count: puzzle.regions.count)
        onlyAnswer.fingerprint.serializedBoard = "different board"
        var onlyGraph = original
        onlyGraph.fingerprint.answerPattern = []
        onlyGraph.fingerprint.serializedBoard = "different board"
        var onlySerialized = onlyAnswer
        onlySerialized.fingerprint.answerPattern = []
        onlySerialized.fingerprint.serializedBoard = original.fingerprint.serializedBoard
        let variants: [(SimilarityCorpusEntry, String)] = [
            (onlyAnswer, "answer_pattern"), (onlyGraph, "region_graph"), (onlySerialized, "serialized_board")
        ]
        for (entry, dimension) in variants {
            let report = PuzzleSimilarity.evaluate(puzzle, corpus: [entry], configuration: configuration)
            XCTAssertFalse(report.accepted, dimension)
            XCTAssertTrue(report.matches.contains { $0.decision == "Reject" && $0.matchedDimensions.contains(dimension) })
        }
    }

    func testOpeningUsesRealDeductionPrefixAndFirstBreakthroughWithoutStoredAnswer() throws {
        let puzzle = try board(legacy: true, level: 2)
        let fingerprint = PuzzleFingerprint(puzzle: puzzle)
        XCTAssertTrue(fingerprint.openingState.isEmpty, "Known board has no singleton region; old feature was empty")
        let opening = try XCTUnwrap(fingerprint.openingDetails)
        XCTAssertTrue(opening.deductions.contains { $0.forcedCell == nil && !$0.excludedCells.isEmpty })
        let breakthrough = try XCTUnwrap(opening.firstBreakthrough)
        XCTAssertTrue(puzzle.solution.contains(breakthrough.cell))
        XCTAssertEqual(opening.deductions.last?.forcedCell, breakthrough.cell)
        XCTAssertEqual(breakthrough.deductionIndex, opening.deductions.count - 1)
        XCTAssertLessThanOrEqual(opening.deductions.count, PuzzleOpeningFingerprint.maximumSteps)
        for step in opening.deductions {
            XCTAssertTrue(Set(step.excludedCells).isDisjoint(with: Set(puzzle.solution)))
        }
        var answerless = puzzle; answerless.solution = []
        var falseAnswer = puzzle; falseAnswer.solution = [0, 1, 2, 3]
        XCTAssertEqual(PuzzleFingerprint(puzzle: answerless).openingDetails, opening)
        XCTAssertEqual(PuzzleFingerprint(puzzle: falseAnswer).openingDetails, opening)

        let rowBoard = Puzzle(id: 0, size: 4, regions: (0..<16).map { $0 / 4 }, solution: [], seed: 0,
                              generatorVersion: "test", difficulty: "test")
        var other = SimilarityCorpusEntry(game: "CapyDoku", puzzle: rowBoard)
        XCTAssertEqual(other.fingerprint.openingState, fingerprint.openingState)
        XCTAssertNotEqual(other.fingerprint.openingDetails, opening)
        // Keep one unrelated matching dimension to expose the scored comparison;
        // isolate the opening weight without a hard answer/graph/board match.
        other.fingerprint.regionSizeDistribution = fingerprint.regionSizeDistribution
        var configuration = SimilarityConfiguration.strict
        configuration.threshold = 1
        configuration.weights = .init(regionGraph: 0, regionSizeDistribution: 0, answerPattern: 0, openingState: 1)
        let report = PuzzleSimilarity.evaluate(puzzle, corpus: [other], configuration: configuration)
        XCTAssertTrue(report.accepted)
        let match = try XCTUnwrap(report.matches.first)
        XCTAssertLessThan(match.similarityScore, 1, "Empty singleton lists must not imply identical openings")
        XCTAssertFalse(match.matchedDimensions.contains("opening_state"))
    }

    func testOldFingerprintCorpusAndReportJSONRemainReadable() throws {
        let puzzle = try board(legacy: true, level: 2)
        let current = PuzzleFingerprint(puzzle: puzzle)
        var oldFingerprint = try object(current)
        oldFingerprint.removeValue(forKey: "openingDetails")
        let decoded = try JSONDecoder().decode(PuzzleFingerprint.self, from: data(oldFingerprint))
        XCTAssertNil(decoded.openingDetails)
        XCTAssertTrue(decoded.matchesLegacyFields(of: current))
        var entry = try object(SimilarityCorpusEntry(game: "CapyDoku", puzzle: puzzle))
        entry["fingerprint"] = oldFingerprint
        let imported = try JSONDecoder().decode(SimilarityCorpusEntry.self, from: data(entry))
        XCTAssertEqual(imported.fingerprint, current, "Legacy corpus upgrades once at import, before candidate filtering")
        let report = PuzzleSimilarity.evaluate(puzzle, corpus: [], configuration: .strict)
        var oldReport = try object(report)
        for key in ["configurationProvenance", "configurationWeights", "openingFingerprintVersion", "calibrationStatus"] {
            oldReport.removeValue(forKey: key)
        }
        let restored = try JSONDecoder().decode(SimilarityReport.self, from: data(oldReport))
        XCTAssertEqual(restored.accepted, report.accepted)
        XCTAssertNil(restored.openingFingerprintVersion)
    }

    func testLegacyHistoryUpgradePreservesCheckpointAndMixedBackupPrefixWithoutRewritingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var puzzle = try board(); puzzle.id = 151
        let store = ExperimentalPuzzleHistoryStore(directory: directory)
        let checkpoint = try store.record(puzzle, checkpoint: nil, requiredLevels: [])
        let modern = try Data(contentsOf: store.primaryURL)
        let legacy = try historyBytes(modern) { $0.removeValue(forKey: "openingDetails") }
        try legacy.write(to: store.primaryURL)
        try legacy.write(to: store.backupURL)
        let oldSnapshot = try store.load(checkpoint: checkpoint, requiredLevels: [151])
        XCTAssertEqual(oldSnapshot.checkpoint, checkpoint)
        XCTAssertEqual(oldSnapshot.corpus.first?.fingerprint, PuzzleFingerprint(puzzle: puzzle))
        XCTAssertEqual(try Data(contentsOf: store.primaryURL), legacy, "Read-time upgrade must not rewrite saved history")
        try modern.write(to: store.backupURL)
        let mixed = try store.load(checkpoint: checkpoint, requiredLevels: [151])
        XCTAssertEqual(mixed.checkpoint, checkpoint)
        XCTAssertEqual(mixed.corpus, oldSnapshot.corpus)
        XCTAssertFalse(PuzzleSimilarity.evaluate(puzzle, corpus: mixed.corpus, configuration: .strict).accepted)
        XCTAssertEqual(try store.record(puzzle, checkpoint: checkpoint, requiredLevels: [151]), checkpoint)
    }

    func testNewOpeningTamperingIsRejectedAndMissingOtherProductNeverBecomesVerified() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var puzzle = try board(); puzzle.id = 151
        let store = ExperimentalPuzzleHistoryStore(directory: directory)
        let checkpoint = try store.record(puzzle, checkpoint: nil, requiredLevels: [])
        let tampered = try historyBytes(Data(contentsOf: store.primaryURL)) { fingerprint in
            var opening = try XCTUnwrap(fingerprint["openingDetails"] as? [String: Any])
            opening["termination"] = "fabricated opening"
            fingerprint["openingDetails"] = opening
        }
        try tampered.write(to: store.primaryURL)
        try tampered.write(to: store.backupURL)
        XCTAssertThrowsError(try store.load(checkpoint: checkpoint, requiredLevels: [151]))

        var claimedCorpus = SimilarityConfiguration.strict
        claimedCorpus.crossProductCorpusAvailable = true
        let missing = PuzzleSimilarity.evaluate(puzzle, corpus: [], configuration: claimedCorpus)
        XCTAssertEqual(missing.crossProductStatus, "missing_other_product_corpus")
        XCTAssertFalse(missing.originalStrictAcceptance)
        let other = SimilarityCorpusEntry(game: "PandaDoku", puzzle: puzzle)
        let falseFlag = PuzzleSimilarity.evaluate(puzzle, corpus: [other], configuration: .strict)
        XCTAssertEqual(falseFlag.crossProductStatus, "missing_other_product_corpus")
        let supplied = PuzzleSimilarity.evaluate(puzzle, corpus: [other], configuration: claimedCorpus)
        XCTAssertEqual(supplied.crossProductStatus, "supplied_corpus_checked")
        XCTAssertFalse(supplied.originalStrictAcceptance)
        XCTAssertEqual(supplied.calibrationStatus, "local_demo_uncalibrated")
        XCTAssertEqual(supplied.configurationProvenance, "local demo, uncalibrated")
    }

    /// Keep a valid envelope checksum so rejection tests exercise semantic record
    /// verification, not just the already-covered byte-integrity guard.
    private func historyBytes(_ bytes: Data, transform: (inout [String: Any]) throws -> Void) throws -> Data {
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let encodedPayload = try XCTUnwrap(envelope["payload"] as? String)
        let payloadBytes = try XCTUnwrap(Data(base64Encoded: encodedPayload))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any])
        var records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        var entry = try XCTUnwrap(records[0]["entry"] as? [String: Any])
        var fingerprint = try XCTUnwrap(entry["fingerprint"] as? [String: Any])
        try transform(&fingerprint)
        entry["fingerprint"] = fingerprint; records[0]["entry"] = entry; payload["records"] = records
        let replacement = try data(payload)
        envelope["payload"] = replacement.base64EncodedString()
        envelope["sha256"] = SHA256.hash(data: replacement).map { String(format: "%02x", $0) }.joined()
        return try data(envelope)
    }
}
