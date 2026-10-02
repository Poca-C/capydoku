import Foundation

public struct DifficultyRange: Codable, Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public init(_ minimum: Double, _ maximum: Double) { self.minimum = minimum; self.maximum = maximum }
    public var midpoint: Double { (minimum + maximum) / 2 }
    public func contains(_ value: Double) -> Bool { value.isFinite && value >= minimum && value <= maximum }
    public var valid: Bool { minimum.isFinite && maximum.isFinite && minimum <= maximum }
}

public enum DifficultyBand: String, Codable, CaseIterable, Sendable {
    case tutorial = "Tutorial", flow = "Flow", recovery = "Recovery", medium = "Medium"
    case challenge = "Challenge", preHard = "Pre-Hard", hard = "Hard", peak = "Peak"
}

public struct DifficultyProvenance: Codable, Equatable, Sendable {
    public var status: String
    public var source: String
    public var referenceVersion: String?
    public var sampledAt: String?
    public var referenceChecksum: String?
    public static let provisional = DifficultyProvenance(status: "unverified_local_demo", source: "Original Word chapter 3 role sequence; numeric targets are local solver estimates. Frozen Pawdoku sampling is missing.")
    public var isFrozenReference: Bool {
        status == "imported_frozen_reference" && !(referenceVersion ?? "").isEmpty
            && !(sampledAt ?? "").isEmpty && !(referenceChecksum ?? "").isEmpty
    }
}

/// A target contains no region map, answer coordinates or competitor puzzle data.
public struct DifficultyProfile: Codable, Equatable, Sendable {
    public var profileVersion: String
    public var levelID: Int
    public var referenceLevelRange: DifficultyRange?
    public var difficultyBand: DifficultyBand
    public var difficultyRole: String
    public var difficultyScoreTarget: DifficultyRange
    public var bandScoreRange: DifficultyRange
    public var boardSizeCurveTarget: DifficultyRange
    public var regionCountTarget: DifficultyRange
    public var regionComplexityTarget: DifficultyRange
    public var forcedMoveDensityTarget: DifficultyRange
    public var candidateDensityTarget: DifficultyRange
    public var reasoningDepthTarget: DifficultyRange
    public var logicalStepCountTarget: DifficultyRange
    public var errorRiskTarget: DifficultyRange
    public var solveTimeTarget: DifficultyRange
    public var hintPressureTarget: DifficultyRange
    public var failPressureTarget: DifficultyRange
    public var trialAllowed: Bool
    public var tolerancePercent: Double
    public var candidateBatchSize: Int
    public var provenance: DifficultyProvenance
    public var eliminationChainLengthTarget: DifficultyRange? = nil
    public static let provisionalVersion = "original-ch3-local-bounded-v2"
    public static let provisionalEndlessVersion = "original-ch3-endless-bounded-v3"
    public static let endlessReasoningDepthCap = 3

    public var validationErrors: [String] {
        var errors: [String] = []
        if levelID < 1 || profileVersion.isEmpty { errors.append("missing_level_or_version") }
        if !["unverified_local_demo", "imported_frozen_reference"].contains(provenance.status) || provenance.source.isEmpty { errors.append("invalid_provenance") }
        if levelID <= 150 && (referenceLevelRange == nil || referenceLevelRange?.valid != true || (referenceLevelRange?.minimum ?? 0) < 1) { errors.append("missing_reference_level_range") }
        let ranges = [difficultyScoreTarget, bandScoreRange, boardSizeCurveTarget, regionCountTarget,
                      regionComplexityTarget, forcedMoveDensityTarget, candidateDensityTarget,
                      reasoningDepthTarget, logicalStepCountTarget, errorRiskTarget, solveTimeTarget,
                      hintPressureTarget, failPressureTarget]
        if !ranges.allSatisfy(\.valid) { errors.append("invalid_range") }
        if let chain = eliminationChainLengthTarget,
           !chain.valid || chain.minimum < 0 || chain.maximum > 40 { errors.append("invalid_elimination_chain_range") }
        if difficultyScoreTarget.midpoint > 0 && (difficultyScoreTarget.maximum - difficultyScoreTarget.minimum) / (2 * difficultyScoreTarget.midpoint) > tolerancePercent + 0.000_001 {
            errors.append("score_interval_exceeds_tolerance")
        }
        let densities = [forcedMoveDensityTarget, candidateDensityTarget, errorRiskTarget, hintPressureTarget, failPressureTarget]
        if densities.contains(where: { $0.minimum < 0 || $0.maximum > 1 }) { errors.append("density_or_pressure_outside_0_to_1") }
        if tolerancePercent < 0.10 || tolerancePercent > 0.15 { errors.append("tolerance_must_be_10_to_15_percent") }
        if !(100...500).contains(candidateBatchSize) { errors.append("candidate_batch_must_be_100_to_500") }
        if boardSizeCurveTarget.minimum < 4 || boardSizeCurveTarget.maximum > 10 { errors.append("unsupported_board_size") }
        if levelID == 1 && (boardSizeCurveTarget != DifficultyRange(4, 4) || reasoningDepthTarget.maximum > 1 || trialAllowed || forcedMoveDensityTarget.minimum < 0.75 || errorRiskTarget.maximum > 0.35) { errors.append("tutorial_constraints") }
        if levelID % 10 == 0 && difficultyBand != .hard { errors.append("x0_must_be_hard") }
        if levelID > 150 && reasoningDepthTarget.maximum > Double(Self.endlessReasoningDepthCap) { errors.append("endless_reasoning_cap") }
        if provenance.status == "imported_frozen_reference" && !provenance.isFrozenReference { errors.append("incomplete_reference_evidence") }
        return errors
    }

    public static func role(for level: Int) -> (DifficultyBand, String) {
        guard level > 0 else { return (.flow, "Invalid") }
        switch level {
        case 1: return (.tutorial, "Tutorial")
        case 2...5: return (.flow, "Entry / Flow")
        case 6...8: return (.medium, "Basic Mastery")
        case 9: return (.preHard, "Scale Up")
        case 11...14: return (.flow, "Deep Dive / Flow")
        case 15: return (.challenge, "Error Spike")
        case 16: return (.peak, "Thinking Peak")
        case 17: return (.recovery, "Recovery")
        case 18...19: return (.challenge, "High Mastery")
        case 20: return (.hard, "Hard / Compact Hard")
        default:
            let band: DifficultyBand = [.hard, .flow, .flow, .medium, .medium, .challenge, .recovery, .medium, .challenge, .preHard][level % 10]
            return (band, band.rawValue)
        }
    }

    /// These ranges are executable local hypotheses, explicitly not a Pawdoku mirror.
    public static func provisional(level: Int) -> DifficultyProfile {
        let (band, role) = role(for: level)
        let size: Int
        if level <= 2 { size = 4 }
        else if level <= 50 { size = 6 }
        else if level <= 100 { size = 8 }
        else if level <= 150 { size = band == .hard ? 8 : 10 }
        else { size = [.flow, .recovery].contains(band) ? 6 : 8 }
        // Bands are evaluated from inference effort, ambiguity and error risk, not board size.
        let scores: DifficultyRange
        switch band {
        case .tutorial: scores = .init(0, 15)
        case .flow, .recovery: scores = .init(0, 36)
        case .medium: scores = .init(30, 48)
        case .challenge: scores = .init(44, 60)
        case .preHard: scores = .init(50, 65)
        case .hard: scores = .init(60, 100)
        case .peak: scores = .init(60, 100)
        }
        let scoreCenter: Double
        switch band {
        case .tutorial: scoreCenter = 9
        case .flow: scoreCenter = level <= 5 ? 9.5 : 30
        case .recovery: scoreCenter = 30
        case .medium: scoreCenter = 40
        case .challenge: scoreCenter = 50
        case .preHard: scoreCenter = 57
        case .hard: scoreCenter = 70
        case .peak: scoreCenter = 74
        }
        let depthMaximum: Double = level <= 5 ? 1 : ([.flow, .recovery, .medium].contains(band) ? 2 : 3)
        let depthMinimum: Double = band == .peak ? 3 : ([.hard, .preHard].contains(band) ? 2 : 0)
        // A fixed 6×6 pool has only 90 non-touching answer permutations. Keep
        // the same effort/score caps while allowing other supported sizes; size
        // alone never promotes a candidate into the requested difficulty band.
        let maximumSize = level > 150 ? 10 : size
        // Versioned engineering bounds, chosen by role rather than copied from a
        // reference game. Existing pack measurements are a feasibility check;
        // neither those measurements nor these ranges are player calibration.
        let forcedRange: DifficultyRange, candidateRange: DifficultyRange
        let riskRange: DifficultyRange, hintRange: DifficultyRange, secondsRange: DifficultyRange
        let chainRange: DifficultyRange, maximumSteps: Double
        if level <= 5 {
            forcedRange = .init(0.9, 1); candidateRange = .init(0.2, 0.6)
            riskRange = .init(0, 0.22); hintRange = .init(0, 0.08); secondsRange = .init(10, 90)
            chainRange = .init(0, 1); maximumSteps = Double(maximumSize) * 1.2
        } else {
            switch band {
            case .tutorial, .flow, .recovery:
                forcedRange = .init(0.75, 1); candidateRange = .init(0.2, 0.6)
                riskRange = .init(0.05, 0.25); hintRange = .init(0, 0.15); secondsRange = .init(20, 120)
                chainRange = .init(0, 3); maximumSteps = Double(maximumSize) * 1.4
            case .medium:
                forcedRange = .init(0.45, 0.8); candidateRange = .init(0.2, 0.65)
                riskRange = .init(0.1, 0.4); hintRange = .init(0.1, 0.35); secondsRange = .init(40, 180)
                chainRange = .init(1, 7); maximumSteps = Double(maximumSize) * 3
            case .challenge, .preHard:
                forcedRange = .init(0.25, 0.8); candidateRange = .init(0.25, 0.7)
                riskRange = .init(level == 15 ? 0.35 : 0.15, 0.5)
                hintRange = .init(0.12, 0.5); secondsRange = .init(50, 260)
                chainRange = .init(1, 10); maximumSteps = Double(maximumSize) * 4
            case .hard, .peak:
                forcedRange = .init(0.2, 0.6); candidateRange = .init(0.3, 0.75)
                riskRange = .init(0.22, 0.6); hintRange = .init(0.24, 0.55); secondsRange = .init(70, 300)
                chainRange = .init(1, 12); maximumSteps = Double(maximumSize) * 6
            }
        }
        return DifficultyProfile(profileVersion: level > 150 ? provisionalEndlessVersion : provisionalVersion, levelID: level,
            referenceLevelRange: level <= 150 ? .init(Double(level), Double(level)) : nil,
            difficultyBand: band, difficultyRole: role, difficultyScoreTarget: .init(scoreCenter * 0.85, scoreCenter * 1.15), bandScoreRange: scores,
            boardSizeCurveTarget: .init(Double(size), Double(maximumSize)), regionCountTarget: .init(Double(size), Double(maximumSize)),
            regionComplexityTarget: .init(0.15, 0.65), forcedMoveDensityTarget: forcedRange,
            candidateDensityTarget: candidateRange, reasoningDepthTarget: .init(depthMinimum, depthMaximum),
            logicalStepCountTarget: .init(Double(size), maximumSteps), errorRiskTarget: riskRange,
            solveTimeTarget: secondsRange, hintPressureTarget: hintRange, failPressureTarget: riskRange,
            trialAllowed: false, tolerancePercent: 0.15, candidateBatchSize: 100,
            provenance: .provisional, eliminationChainLengthTarget: chainRange)
    }
}

public struct DifficultyProfileImportReport: Codable, Sendable {
    public var oldVersion: String?
    public var newVersion: String
    public var changedLevelIDs: [Int]
    public var fieldDifferences: [String: [String]]
    public var errors: [String]
    public var frozenReferenceVerified: Bool
    public var referenceEvidenceComplete: Bool
}

public struct DifficultyProfileCatalog: Codable, Equatable, Sendable {
    public var version: String
    public var profiles: [DifficultyProfile]
    public init(version: String, profiles: [DifficultyProfile]) { self.version = version; self.profiles = profiles }
    public func profile(level: Int) -> DifficultyProfile? { profiles.first { $0.levelID == level } }
    public static func importing(_ data: Data, replacing old: DifficultyProfileCatalog? = nil) throws -> (DifficultyProfileCatalog, DifficultyProfileImportReport) {
        // Reject forbidden concrete puzzle fields, including nested ones, before decoding.
        let forbidden: Set<String> = ["regions", "region_map", "regionMap", "region_coordinates", "regionCoordinates", "region_shape", "regionShape", "answer_coordinates", "answerCoordinates", "solution", "answer_pattern", "answerPattern", "opening_state", "openingState", "breakthrough_position", "breakthroughPosition"]
        func keys(_ value: Any) -> Set<String> {
            if let dictionary = value as? [String: Any] { return Set(dictionary.keys).union(dictionary.values.reduce(into: Set<String>()) { $0.formUnion(keys($1)) }) }
            if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(keys($1)) } }
            return []
        }
        guard forbidden.isDisjoint(with: keys(try JSONSerialization.jsonObject(with: data))) else {
            throw NSError(domain: "DifficultyImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Concrete reference puzzle data is forbidden."])
        }
        let incoming = try JSONDecoder().decode(Self.self, from: data)
        var errors = incoming.profiles.flatMap { p in p.validationErrors.map { "L\(p.levelID):\($0)" } }
        if Set(incoming.profiles.map(\.levelID)).count != incoming.profiles.count { errors.append("duplicate_level_ids") }
        if incoming.version.isEmpty { errors.append("missing_catalog_version") }
        for profile in incoming.profiles where profile.levelID > 1 && profile.levelID % 10 == 1 {
            if let previous = incoming.profile(level: profile.levelID - 1),
               profile.difficultyScoreTarget.midpoint > previous.difficultyScoreTarget.midpoint {
                errors.append("L\(profile.levelID):post_hard_must_recover_or_stabilize")
            }
        }
        let completeBlockStarts = Set(incoming.profiles.filter { $0.levelID > 150 }.map { 151 + (($0.levelID - 151) / 10) * 10 })
        for start in completeBlockStarts {
            let block = (start..<(start + 10)).compactMap { incoming.profile(level: $0) }
            if block.count == 10 && (block.filter { $0.difficultyBand == .flow }.count < 2 || !block.contains { $0.difficultyBand == .recovery } || block.last?.difficultyBand != .hard) {
                errors.append("block_\(start):missing_flow_recovery_or_final_hard")
            }
        }
        var differences: [String: [String]] = [:]
        let encoder = JSONEncoder()
        for profile in incoming.profiles where old?.profile(level: profile.levelID) != profile {
            let current = try JSONSerialization.jsonObject(with: encoder.encode(profile)) as! [String: Any]
            let prior = try old?.profile(level: profile.levelID).map { try JSONSerialization.jsonObject(with: encoder.encode($0)) as! [String: Any] } ?? [:]
            differences[String(profile.levelID)] = Set(current.keys).union(prior.keys).filter { key in
                guard let value = current[key] as? NSObject else { return prior[key] != nil }
                return !value.isEqual(prior[key])
            }.sorted()
        }
        return (incoming, DifficultyProfileImportReport(oldVersion: old?.version, newVersion: incoming.version,
            changedLevelIDs: differences.keys.compactMap(Int.init).sorted(), fieldDifferences: differences, errors: errors,
            frozenReferenceVerified: false,
            referenceEvidenceComplete: errors.isEmpty && !incoming.profiles.isEmpty && incoming.profiles.allSatisfy { $0.provenance.isFrozenReference }))
    }
}
