import XCTest
import CryptoKit
@testable import CapydokuCore

final class CheckInDateStorageTests: XCTestCase {
    // Foundation Gregorian's historical calendar cutover matches the existing
    // weekday UI. This is a technical representable-date boundary, not a new
    // check-in timezone, reward policy, or server-time contract.
    private let minimumDay = -719_164
    private let maximumDay = 2_932_896
    private var invalidDays: [Int] { [Int.min, minimumDay - 1, maximumDay + 1, Int.max] }

    private func directory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("check-in-date-storage-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func progress(day: Int?) -> PlayerProgress {
        var progress = PlayerProgress()
        progress.settings.language = .english
        progress.settings.hapticsEnabled = false
        progress.bonusHints = 5
        progress.bonusDirect = 2
        if let day { progress.checkIn = .init(lastClaimedDay: day, streak: 3, cycleDay: 3, completedCycles: 2) }
        return progress
    }

    /// Reproduces a well-formed schema-4 file that the old SaveStore accepted.
    /// The checksum is correct, so fallback must come from date validation.
    @discardableResult private func writeUnchecked(_ progress: PlayerProgress, to url: URL) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(progress)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let envelope: [String: Any] = ["schemaVersion": 4, "payload": payload.base64EncodedString(), "checksum": checksum]
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return bytes
    }

    private func assertPreserved(_ bytes: Data, in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("progress.preserved-") }
        XCTAssertTrue(try preserved.contains { try Data(contentsOf: $0) == bytes }, "Rejected original bytes must remain recoverable.", file: file, line: line)
    }

    func testStoredBoundsMatchTheExistingFoundationGregorianUTCCalendar() throws {
        XCTAssertEqual(CheckInState.storedDayRange.lowerBound, minimumDay)
        XCTAssertEqual(CheckInState.storedDayRange.upperBound, maximumDay)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let cases = [(minimumDay, 1, 1, 1), (maximumDay, 9999, 12, 31)]
        for (ordinal, year, month, day) in cases {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(era: 1, year: year, month: month, day: day)))
            XCTAssertEqual(date.timeIntervalSince1970 / 86_400, Double(ordinal))
            XCTAssertEqual(CheckInState.utcDay(for: date), ordinal)
            let components = calendar.dateComponents([.era, .year, .month, .day, .weekday], from: Date(timeIntervalSince1970: Double(ordinal) * 86_400))
            XCTAssertEqual(components.era, 1)
            XCTAssertEqual(components.year, year)
            XCTAssertEqual(components.month, month)
            XCTAssertEqual(components.day, day)
            XCTAssertTrue((1...7).contains(try XCTUnwrap(components.weekday)))
        }
    }

    func testNilBoundsAndPreEpochDatesRoundTripWithoutChangingPlayerState() throws {
        for day in [nil, minimumDay, minimumDay + 1, -1, 0, 20_000, maximumDay] as [Int?] {
            let expected = progress(day: day), store = SaveStore(directory: directory())
            try store.save(expected)
            let restored = SaveStore(directory: store.directory).load()
            XCTAssertEqual(restored.source, .primary)
            XCTAssertEqual(restored.progress, expected)
            XCTAssertFalse(restored.didMigrate)
            XCTAssertTrue(restored.warnings.isEmpty)
            XCTAssertEqual(restored.progress.checkIn.lastClaimedDay, day)
        }
    }

    func testSavingInvalidDatesRejectsBeforeChangingPrimaryOrBackup() throws {
        for invalid in invalidDays {
            let store = SaveStore(directory: directory()), expected = progress(day: 20_000)
            try store.save(expected); try store.save(expected)
            let primary = try Data(contentsOf: store.primaryURL), backup = try Data(contentsOf: store.backupURL)
            var changed = expected; changed.checkIn.lastClaimedDay = invalid
            XCTAssertThrowsError(try store.save(changed), "Invalid day \(invalid) must not become a saved date.")
            XCTAssertEqual(try Data(contentsOf: store.primaryURL), primary)
            XCTAssertEqual(try Data(contentsOf: store.backupURL), backup)
            XCTAssertEqual(store.load().progress, expected)
        }
    }

    func testChecksumValidInvalidPrimaryRecoversBackupAndPreservesOriginalBytes() throws {
        for invalid in invalidDays {
            let store = SaveStore(directory: directory()), expected = progress(day: 20_000)
            try store.save(expected); try store.save(expected)
            var changed = expected
            // Int.max + zero counters is the complete minimal UI crash sample:
            // shownStreak previously evaluated lastClaimedDay + 1 unguarded.
            changed.checkIn = .init(lastClaimedDay: invalid)
            let originalBytes = try writeUnchecked(changed, to: store.primaryURL)
            let restored = SaveStore(directory: store.directory).load()
            XCTAssertEqual(restored.source, .backup, "Invalid day \(invalid) must not be accepted from a checksum-valid primary.")
            XCTAssertEqual(restored.progress, expected)
            XCTAssertFalse(restored.warnings.isEmpty)
            try assertPreserved(originalBytes, in: store.directory)
            let next = SaveStore(directory: store.directory).load()
            XCTAssertEqual(next.source, .primary)
            XCTAssertEqual(next.progress, expected)
        }
    }

    func testChecksumValidInvalidPrimaryWithoutBackupResetsAndRetainsOriginalBytes() throws {
        for invalid in invalidDays {
            let store = SaveStore(directory: directory())
            var invalidProgress = progress(day: nil)
            invalidProgress.checkIn = .init(lastClaimedDay: invalid)
            let originalBytes = try writeUnchecked(invalidProgress, to: store.primaryURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
            let restored = SaveStore(directory: store.directory).load()
            XCTAssertEqual(restored.source, .resetAfterCorruption)
            XCTAssertEqual(restored.progress, PlayerProgress())
            XCTAssertFalse(restored.warnings.isEmpty)
            XCTAssertEqual(try Data(contentsOf: store.primaryURL), originalBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))

            // A later normal save may replace the primary only after preserving
            // the rejected file. It must never turn that file into a valid backup.
            try store.save(restored.progress)
            try assertPreserved(originalBytes, in: store.directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
            XCTAssertEqual(SaveStore(directory: store.directory).load().progress, PlayerProgress())
        }
    }
}
