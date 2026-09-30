import Foundation
import CapydokuCore

struct LevelRecord: Codable {
    var level: Int
    var size: Int
    var seed: UInt64
    var fingerprint: String
    var difficulty: String
    var generationMilliseconds: Int
    var validation: PuzzleValidationReport
    var automatedPlaythrough: AutomatedPlaythrough?
    var pipeline: GenerationPipelineReport?
}
struct AutomatedPlaythrough: Codable {
    var method = "Automated solver-guided gameplay, not human playtesting. Hint previews are applied as marks without consuming tool inventory; checks correctness and recovery, not difficulty or monetization."
    var passed: Bool
    var status: String
    var found: Int
    var livesRemaining: Int
    var logicalHintsApplied: Int
    var contradictionHintsApplied: Int
    var sameStateRestoreChecks: Int
}
struct GenerationReport: Codable {
    var generatorVersion = PuzzleGenerator.version
    var profileVersion = DifficultyProfile.provisionalVersion
    var status = "Original chapter 3 candidate/solver/difficulty/similarity/select pipeline implemented. Numeric profiles and player metrics are local estimates, not frozen Pawdoku validation. Same-product exact region/answer/board duplicates are strictly rejected; cross-product corpus is missing."
    var count: Int
    var uniqueFingerprints: Int
    var allValid: Bool
    var levels: [LevelRecord]
}

let args = CommandLine.arguments
func argument(_ key: String, fallback: String) -> String {
    guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return fallback }
    return args[index + 1]
}
let outputDirectory = URL(fileURLWithPath: argument("--output", fallback: FileManager.default.currentDirectoryPath), isDirectory: true)
let first = Int(argument("--start", fallback: "1")) ?? 1
let count = Int(argument("--count", fallback: "150")) ?? 150
let experimental = args.contains("--experimental")
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

func playthrough(_ puzzle: Puzzle) throws -> AutomatedPlaythrough {
    var game = GameSession(puzzle: puzzle)
    var logicalHints = 0, contradictionHints = 0, restores = 0
    var correct = true
    for _ in 0..<(puzzle.size * puzzle.size * 2) {
        if game.status != .playing { break }
        var forced: Int?
        for row in 0..<puzzle.size where !game.found.contains(where: { $0 / puzzle.size == row }) {
            let cells = (0..<puzzle.size).map { row * puzzle.size + $0 }.filter { !game.marks.contains($0) }
            if cells.count == 1 { forced = cells[0]; break }
        }
        if let cell = forced {
            guard puzzle.isSolutionCell(cell) else { correct = false; break }
            _ = game.submit(cell: cell)
        } else {
            let beforePreview = game
            guard let hint = PuzzleHints.next(puzzle: puzzle, found: game.found, marks: game.marks), !hint.cells.isEmpty else { correct = false; break }
            guard game == beforePreview, Set(hint.cells).isDisjoint(with: Set(puzzle.solution)) else { correct = false; break }
            if hint.rule == "Contradiction check" { contradictionHints += 1 } else { logicalHints += 1 }
            guard game.markMany(hint.cells) > 0 else { correct = false; break }
        }
        if restores == 0 || (restores == 1 && !game.found.isEmpty) || game.status == .won {
            let recovered = try JSONDecoder().decode(GameSession.self, from: encoder.encode(game))
            guard recovered == game else { correct = false; break }
            game = recovered; restores += 1
        }
    }
    return AutomatedPlaythrough(passed: correct && game.status == .won && game.lives == game.config.initialLives,
                                status: game.status.rawValue, found: game.found.count, livesRemaining: game.lives,
                                logicalHintsApplied: logicalHints, contradictionHintsApplied: contradictionHints,
                                sameStateRestoreChecks: restores)
}

do {
    if args.contains("--audit-existing") {
        try runHintQualityAudit(
            inputURL: URL(fileURLWithPath: argument("--catalog", fallback: "Resources/levels.json")),
            baselineURL: URL(fileURLWithPath: argument("--baseline", fallback: "Validation/levels-report.json")),
            outputURL: outputDirectory.appendingPathComponent("Validation/hint-quality-audit.json"))
        exit(0)
    }
    if args.contains("--audit-production") {
        struct RebuildRow: Codable {
            var level: Int
            var rebuiltFromSeed: Bool
            var fingerprint: String
            var tutorialSteps: [TutorialStep]?
        }
        let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: URL(fileURLWithPath: argument("--catalog", fallback: "Resources/levels.json"))))
        let rows = try puzzles.map { puzzle in
            RebuildRow(level: puzzle.id, rebuiltFromSeed: try PuzzleGenerator.rebuild(puzzle) == puzzle,
                fingerprint: puzzle.fingerprint, tutorialSteps: puzzle.id == 1 ? PuzzleHints.tutorial(puzzle: puzzle) : nil)
        }
        let folder = outputDirectory.appendingPathComponent("Validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(rows).write(to: folder.appendingPathComponent("production-rebuild-audit.json"), options: .atomic)
        guard rows.allSatisfy({ $0.rebuiltFromSeed }) else { throw PuzzleGenerationError.exhausted(attempts: rows.count) }
        print("PASS: \(rows.count) selected candidates rebuilt exactly from generation metadata; tutorial mapping exported.")
        exit(0)
    }
    guard first > 0, count > 0, count <= 10_000 else { throw PuzzleGenerationError.invalidLevel }
    var catalog: DifficultyProfileCatalog?
    if args.contains("--profiles") {
        let imported = try DifficultyProfileCatalog.importing(Data(contentsOf: URL(fileURLWithPath: argument("--profiles", fallback: ""))))
        try FileManager.default.createDirectory(at: outputDirectory.appendingPathComponent("Validation"), withIntermediateDirectories: true)
        try encoder.encode(imported.1).write(to: outputDirectory.appendingPathComponent("Validation/profile-import-report.json"))
        guard imported.1.errors.isEmpty else { throw NSError(domain: "Profiles", code: 1, userInfo: [NSLocalizedDescriptionKey: imported.1.errors.joined(separator: ", ")]) }
        catalog = imported.0
    }
    if args.contains("--export-profiles") {
        let profiles = DifficultyProfileCatalog(version: DifficultyProfile.provisionalVersion, profiles: (first..<(first + count)).map { .provisional(level: $0) })
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try encoder.encode(profiles).write(to: outputDirectory.appendingPathComponent("difficulty-profiles.json"), options: .atomic)
        print("Exported explicitly unverified local profiles.")
        exit(0)
    }
    var corpus: [SimilarityCorpusEntry] = []
    if args.contains("--history-levels") {
        let prior = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: URL(fileURLWithPath: argument("--history-levels", fallback: ""))))
        corpus = prior.map { SimilarityCorpusEntry(game: "CapyDoku", puzzle: $0) }
    }
    var similarity = SimilarityConfiguration.strict
    if args.contains("--similarity-corpus") {
        corpus += try JSONDecoder().decode([SimilarityCorpusEntry].self, from: Data(contentsOf: URL(fileURLWithPath: argument("--similarity-corpus", fallback: ""))))
        similarity.crossProductCorpusAvailable = corpus.contains { $0.game != "CapyDoku" }
    }
    var puzzles: [Puzzle] = [], records: [LevelRecord] = [], fingerprints = Set<String>()
    for level in first..<(first + count) {
        if let catalog = catalog, catalog.profile(level: level) == nil {
            throw NSError(domain: "Profiles", code: level, userInfo: [NSLocalizedDescriptionKey: "Imported catalog is missing level \(level); cannot silently substitute local estimates."])
        }
        let began = ProcessInfo.processInfo.systemUptime
        var accepted: Puzzle?
        var acceptedPipeline: GenerationPipelineReport?
        for retry in 0..<20 {
            let seed = UInt64(level) &* 0x9E3779B97F4A7C15 &+ 0xCA9D0C0 &+ UInt64(retry) &* 0xD1B54A32D192ED03
            let result = try PuzzleGenerator.generateAudited(level: level, seed: seed, profile: catalog?.profile(level: level),
                corpus: corpus, similarityConfiguration: similarity)
            guard let puzzle = result.puzzle else {
                let folder = outputDirectory.appendingPathComponent("Validation")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try encoder.encode(result.report).write(to: folder.appendingPathComponent("rejected-level-\(level)-batch-\(retry).json"))
                if result.report.termination == "invalid_profile" { throw PuzzleGenerationError.invalidLevel }
                continue
            }
            if fingerprints.insert(puzzle.fingerprint).inserted { accepted = puzzle; acceptedPipeline = result.report; break }
        }
        guard let puzzle = accepted else { throw PuzzleGenerationError.exhausted(attempts: 20) }
        let validation = PuzzleSolver.validate(puzzle)
        guard validation.valid else { throw PuzzleGenerationError.exhausted(attempts: 500) }
        let walkthrough = (level <= 20 || puzzle.difficulty == "Hard" || puzzle.difficulty == "Recovery" || experimental)
            ? try playthrough(puzzle) : nil
        if let walkthrough = walkthrough, !walkthrough.passed {
            throw NSError(domain: "AutomatedPlaythrough", code: level, userInfo: [NSLocalizedDescriptionKey: "Solver-guided playthrough failed for level \(level)"])
        }
        puzzles.append(puzzle)
        corpus.append(SimilarityCorpusEntry(game: "CapyDoku", puzzle: puzzle))
        records.append(LevelRecord(level: level, size: puzzle.size, seed: puzzle.seed,
                                   fingerprint: puzzle.fingerprint, difficulty: puzzle.difficulty,
                                   generationMilliseconds: Int((ProcessInfo.processInfo.systemUptime - began) * 1_000),
                                   validation: validation, automatedPlaythrough: walkthrough, pipeline: acceptedPipeline))
        print("Level \(level): \(puzzle.size)×\(puzzle.size), \(puzzle.fingerprint), unique + connected, \(records.last!.generationMilliseconds) ms")
    }
    let resources = outputDirectory.appendingPathComponent("Resources", isDirectory: true)
    let validation = outputDirectory.appendingPathComponent("Validation", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: validation, withIntermediateDirectories: true)
    let report = GenerationReport(count: puzzles.count, uniqueFingerprints: fingerprints.count,
                                  allValid: records.allSatisfy { $0.validation.valid }, levels: records)
    if !experimental { try encoder.encode(puzzles).write(to: resources.appendingPathComponent("levels.json"), options: .atomic) }
    else { try encoder.encode(puzzles).write(to: validation.appendingPathComponent("experimental-levels.json"), options: .atomic) }
    try encoder.encode(report).write(to: validation.appendingPathComponent(experimental ? "experimental-levels-report.json" : "levels-report.json"), options: .atomic)
    print("PASS: \(puzzles.count) valid unique connected boards, \(fingerprints.count) distinct geometries.")
} catch {
    FileHandle.standardError.write(Data("Generation failed: \(error)\n".utf8))
    exit(1)
}
