import AVFoundation
import UIKit

enum FeedbackEvent {
    case tap, mark, erase, correct, wrong, win, combo(Int)
}

/// Temporary sounds are synthesized here. No external recording or game asset is used.
@MainActor
final class FeedbackPlayer {
    struct Settings: Equatable {
        var sound: Bool = true
        var haptic: Bool = true
        var voice: Bool = false
        var music: Bool = false
    }

    private(set) var settings = Settings()
    private var paused = false
    private var effects: [AVAudioPlayer] = []
    private var musicPlayer: AVAudioPlayer?
    private let speech = AVSpeechSynthesizer()
    private var sessionReady = false
    private var lastEventTime: TimeInterval = 0

    func apply(settings: Settings) {
        let previous = self.settings
        self.settings = settings
        if !settings.sound { effects.forEach { $0.stop() }; effects.removeAll() }
        if !settings.voice { speech.stopSpeaking(at: .immediate) }
        if settings.music != previous.music { updateMusic() }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            effects.forEach { $0.stop() }
            effects.removeAll()
            musicPlayer?.pause()
            speech.stopSpeaking(at: .immediate)
        } else {
            updateMusic()
        }
    }

    func play(_ event: FeedbackEvent) {
        guard !paused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // A swept row receives many cells; one gentle feedback cue is sufficient.
        switch event {
        case .tap, .mark, .erase:
            guard now - lastEventTime > 0.045 else { return }
        default: break
        }
        lastEventTime = now
        if settings.haptic { haptic(event) }
        if settings.sound && !isUITesting {
            prepareSession()
            let notes: [(Double, Double)]
            switch event {
            case .tap: notes = [(520, 0.035)]
            case .mark: notes = [(440, 0.045)]
            case .erase: notes = [(330, 0.045)]
            case .correct: notes = [(660, 0.10), (880, 0.12)]
            case .wrong: notes = [(220, 0.10), (175, 0.15)]
            case .win: notes = [(523.25, 0.12), (659.25, 0.12), (783.99, 0.12), (1046.50, 0.28)]
            case .combo(let count): notes = [(min(1320, 660 + Double(max(0, count)) * 35), 0.13)]
            }
            if let player = try? AVAudioPlayer(data: Self.toneData(notes: notes)) {
                effects.removeAll { !$0.isPlaying }
                if effects.count >= 4 { effects.removeFirst().stop() }
                effects.append(player)
                player.volume = 0.24
                player.prepareToPlay()
                player.play()
            }
        }
        if settings.voice && !isUITesting { speak(event) }
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing") ||
        ProcessInfo.processInfo.arguments.contains("-ui-testing") ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func prepareSession() {
        guard !sessionReady else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            sessionReady = true
        } catch {
            // Audio is optional; an unavailable session must never interrupt a puzzle.
            sessionReady = false
        }
    }

    private func updateMusic() {
        guard settings.music, !paused, !isUITesting else { musicPlayer?.pause(); return }
        prepareSession()
        if musicPlayer == nil {
            musicPlayer = try? AVAudioPlayer(data: Self.musicData())
            musicPlayer?.numberOfLoops = -1
            musicPlayer?.volume = 0.11
            musicPlayer?.prepareToPlay()
        }
        musicPlayer?.play()
    }

    private func haptic(_ event: FeedbackEvent) {
        guard !isUITesting else { return }
        switch event {
        case .wrong: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .win: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .correct, .combo: UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.75)
        case .tap, .mark, .erase: UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func speak(_ event: FeedbackEvent) {
        let text: String
        switch event {
        case .correct: text = "Found one!"
        case .wrong: text = "Try again"
        case .win: text = "Wonderful! You found them all!"
        case .combo(let count): text = "\(count) in a row!"
        default: return
        }
        prepareSession()
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.46
        utterance.volume = 0.55
        speech.speak(utterance)
    }

    private static let sampleRate = 22_050

    private static func toneData(notes: [(Double, Double)]) -> Data {
        var samples: [Int16] = []
        for (frequency, duration) in notes {
            let count = Int(duration * Double(sampleRate))
            for index in 0..<count {
                let time = Double(index) / Double(sampleRate)
                let progress = Double(index) / Double(max(1, count - 1))
                let envelope = min(1, progress * 14) * pow(1 - progress, 1.7)
                let fundamental = sin(2 * .pi * frequency * time)
                let harmonic = sin(2 * .pi * frequency * 2 * time) * 0.12
                samples.append(Int16((fundamental + harmonic) * envelope * 14_000))
            }
        }
        return wave(samples: samples)
    }

    private static func musicData() -> Data {
        // Original gentle four-bar marimba-like loop, deliberately quiet and sparse.
        let melody: [Double] = [261.63, 329.63, 392.00, 329.63, 220, 261.63, 329.63, 261.63,
                                174.61, 220, 261.63, 220, 196, 246.94, 293.66, 246.94]
        let step = 0.4
        let count = Int(Double(melody.count) * step * Double(sampleRate))
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let noteIndex = min(melody.count - 1, Int(time / step))
            let localTime = time - Double(noteIndex) * step
            let envelope = min(1, localTime / 0.014) * exp(-localTime * 9)
            let frequency = melody[noteIndex]
            let tone = sin(2 * .pi * frequency * localTime) + 0.18 * sin(2 * .pi * frequency * 3 * localTime)
            let fade = min(1, Double(count - index) / (Double(sampleRate) * 0.06))
            samples[index] = Int16(tone * envelope * fade * 9_000)
        }
        return wave(samples: samples)
    }

    private static func wave(samples: [Int16]) -> Data {
        var data = Data()
        func appendText(_ value: String) { data.append(contentsOf: value.utf8) }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        appendText("RIFF"); append32(36 + bytes); appendText("WAVE")
        appendText("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        appendText("data"); append32(bytes)
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        return data
    }
}
