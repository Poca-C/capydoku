import Foundation
import CapydokuCore

/// Audits the shipped catalog without regenerating or changing any board.
func runHintQualityAudit(inputURL: URL, baselineURL: URL, outputURL: URL) throws {
    let puzzles = try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: inputURL))
    let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: baselineURL)) as? [String: Any]
    let oldRows = baseline?["levels"] as? [[String: Any]] ?? []
    let prior = Dictionary(uniqueKeysWithValues: oldRows.compactMap { row -> (String, Bool)? in
        guard let fingerprint = row["fingerprint"] as? String,
              let validation = row["validation"] as? [String: Any],
              let metrics = validation["logicalMetrics"] as? [String: Any],
              let search = metrics["requiresSearch"] as? Bool else { return nil }
        return (fingerprint, search)
    })
    var rows: [[String: Any]] = [], totals: [String: Int] = [:]
    var symmetry: [String: [Int]] = [:]
    var baselineSolved = 0, solved = 0, allSafe = true, allPlayed = true, answerIndependent = true
    var slowestHintMilliseconds = 0.0
    var commonConflictLevels = [Int]()
    for p in puzzles {
        let report = PuzzleSolver.validate(p)
        let before = prior[p.fingerprint]
        if before == false { baselineSolved += 1 }
        if !report.logicalMetrics.requiresSearch { solved += 1 }
        symmetry[symmetryKey(p), default: []].append(p.id)
        var marks = Set<Int>(), found = Set<Int>(), rules: [String: Int] = [:]
        var safe = true, independent = true, steps = 0
        var levelSlowestHintMilliseconds = 0.0
        for _ in 0..<(p.size * p.size * 3) where found.count != p.size {
            steps += 1
            if let forced = (0..<p.size).compactMap({ row -> Int? in
                guard !found.contains(where: { $0 / p.size == row }) else { return nil }
                let cells = (0..<p.size).map { row * p.size + $0 }.filter { !marks.contains($0) }
                return cells.count == 1 ? cells[0] : nil
            }).first {
                guard p.isSolutionCell(forced) else { safe = false; break }
                found.insert(forced)
            } else {
                let started = ProcessInfo.processInfo.systemUptime
                guard let hint = PuzzleHints.next(puzzle: p, found: found, marks: marks) else { break }
                let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                levelSlowestHintMilliseconds = max(levelSlowestHintMilliseconds, milliseconds)
                slowestHintMilliseconds = max(slowestHintMilliseconds, milliseconds)
                var answerless = p
                answerless.solution = []
                if PuzzleHints.next(puzzle: answerless, found: found, marks: marks) != hint { independent = false }
                let selected = Set(hint.cells)
                if selected.isEmpty || !selected.isDisjoint(with: Set(p.solution)) || !selected.isDisjoint(with: marks) {
                    safe = false; break
                }
                marks.formUnion(selected)
                rules[hint.rule, default: 0] += 1
                totals[hint.rule, default: 0] += 1
            }
        }
        if rules["Common conflict", default: 0] > 0 { commonConflictLevels.append(p.id) }
        allSafe = allSafe && safe && report.valid
        allPlayed = allPlayed && found.count == p.size
        answerIndependent = answerIndependent && independent
        rows.append([
            "level": p.id, "size": p.size, "fingerprint": p.fingerprint,
            "provisionalRole": p.difficulty, "baselineMatched": before != nil,
            "baselineRequiresSearch": before as Any? ?? NSNull(),
            "logicRequiresSearch": report.logicalMetrics.requiresSearch,
            "remainingUnresolved": report.logicalMetrics.remainingUnresolved,
            "deductionSteps": report.logicalMetrics.deductionSteps,
            "allHintsSafe": safe, "answerIndependent": independent,
            "slowestHintMilliseconds": levelSlowestHintMilliseconds,
            "automatedPlaythroughPassed": found.count == p.size, "playthroughActions": steps,
            "hintRuleCounts": rules
        ])
    }
    let groups = symmetry.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    let document: [String: Any] = [
        "auditVersion": "demo-hint-audit-v1",
        "testedAtUTC": ISO8601DateFormatter().string(from: Date()),
        "catalog": inputURL.lastPathComponent,
        "catalogMutated": false,
        "scope": "Fixed original 150-level internal-demo catalog. Human-readable deduction coverage is a provisional engineering metric, not Pawdoku difficulty equivalence, human playtesting, or formal cross-product similarity acceptance.",
        "method": "Replay safe hints and row-single placements; verify every exclusion against the independently solver-validated unique answer. Repeating each hint with an empty stored solution must produce exactly the same hint. Player marks are not logical premises. Contradiction checks remain honestly labeled exhaustive search.",
        "baselineMethod": "Only matching geometry entries from the supplied baseline report are counted. Do not interpret this as a before/after improvement when the catalogs differ.",
        "newRules": ["Common conflict: a cell outside a row, column or region conflicts with every remaining candidate in that unit.",
                     "Two-unit lock: two rows, columns or regions have all candidates inside two units of another family, reserving those units for the pair."],
        "count": puzzles.count,
        "baselineLogicallySolved": baselineSolved,
        "logicallySolved": solved,
        "stillRequireSearch": puzzles.count - solved,
        "allHintsSafe": allSafe,
        "allAutomatedPlaythroughsPassed": allPlayed,
        "allHintsIndependentOfStoredAnswer": answerIndependent,
        "slowestHintMillisecondsOnAuditHost": slowestHintMilliseconds,
        "timingScope": "Release command-line build on this Mac; simulator and real-device interaction latency must be checked separately.",
        "hintRuleCounts": totals,
        "levelsUsingCommonConflict": commonConflictLevels,
        "symmetryAudit": [
            "method": "Normalize region names, then compare all 4 rotations and their reflections. Report only; no boards or labels changed.",
            "exactUniqueFingerprints": Set(puzzles.map(\.fingerprint)).count,
            "distinctGeometryOrbits": symmetry.count,
            "duplicateOrbitGroups": groups,
            "levelsInDuplicateOrbits": groups.flatMap { $0 }.count
        ],
        "levels": rows
    ]
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: outputURL, options: .atomic)
    print("HINT AUDIT: logic-only \(baselineSolved) → \(solved)/\(puzzles.count); safe=\(allSafe), answer-independent=\(answerIndependent), playthrough=\(allPlayed); \(groups.count) symmetry duplicate groups.")
    guard allSafe && allPlayed && answerIndependent else {
        throw NSError(domain: "HintQualityAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hint safety, independence or playthrough audit failed"])
    }
}

private func symmetryKey(_ p: Puzzle) -> String {
    var variants = [String]()
    for reflected in [false, true] {
        for rotations in 0..<4 {
            var transformed = Array(repeating: 0, count: p.regions.count)
            for cell in p.regions.indices {
                var row = cell / p.size, col = cell % p.size
                if reflected { col = p.size - 1 - col }
                for _ in 0..<rotations { (row, col) = (col, p.size - 1 - row) }
                transformed[row * p.size + col] = p.regions[cell]
            }
            var names = [Int: Int]()
            let canonical = transformed.map { value -> String in
                if let name = names[value] { return String(name) }
                let name = names.count; names[value] = name; return String(name)
            }
            variants.append("\(p.size):" + canonical.joined(separator: ","))
        }
    }
    return variants.min()!
}
