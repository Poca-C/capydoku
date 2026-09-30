import Foundation

/// Deliberately provisional tuning, never represented as frozen reference-game values.
public struct DemoConfig: Codable, Equatable, Sendable {
    public var version: String
    public var initialLives: Int
    public var hintsPerLevel: Int
    public var directPerLevel: Int
    public var baseScore: Int
    public var comboBonus: Int
    public var comboThresholds: [Int]
    public var dailyHintReward: Int
    public var cycleDirectReward: Int
    public var checkInCycleDays: Int
    public var generatorBudgetMilliseconds: Int
    public var generatorCandidateLimit: Int
    /// Implementation ceiling, not an independently adjustable difficulty setting.
    public let maximumBoardSize: Int

    public static let `default` = DemoConfig()

    public init(version: String = "demo-2026-09-v2", initialLives: Int = 3,
                hintsPerLevel: Int = 1, directPerLevel: Int = 1,
                baseScore: Int = 100, comboBonus: Int = 20,
                comboThresholds: [Int] = [2, 3, 4], dailyHintReward: Int = 1,
                cycleDirectReward: Int = 1, checkInCycleDays: Int = 7,
                generatorBudgetMilliseconds: Int = 4_000,
                generatorCandidateLimit: Int = 150) {
        self.version = version
        self.initialLives = max(1, min(initialLives, 99))
        self.hintsPerLevel = max(0, hintsPerLevel)
        self.directPerLevel = max(0, directPerLevel)
        self.baseScore = max(0, baseScore)
        self.comboBonus = max(0, comboBonus)
        self.comboThresholds = comboThresholds.filter { $0 > 0 }.sorted()
        self.dailyHintReward = max(0, dailyHintReward)
        self.cycleDirectReward = max(0, cycleDirectReward)
        self.checkInCycleDays = max(1, checkInCycleDays)
        self.generatorBudgetMilliseconds = max(100, min(8_000, generatorBudgetMilliseconds))
        self.generatorCandidateLimit = max(1, min(500, generatorCandidateLimit))
        self.maximumBoardSize = PuzzleGenerator.maximumBoardSize
    }
}

public struct GameSettings: Codable, Equatable, Sendable {
    public var musicEnabled: Bool
    public var soundEnabled: Bool
    public var voiceEnabled: Bool
    public var hapticsEnabled: Bool

    public init(musicEnabled: Bool = true, soundEnabled: Bool = true,
                voiceEnabled: Bool = true, hapticsEnabled: Bool = true) {
        self.musicEnabled = musicEnabled
        self.soundEnabled = soundEnabled
        self.voiceEnabled = voiceEnabled
        self.hapticsEnabled = hapticsEnabled
    }
}
