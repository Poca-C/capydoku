import XCTest
import SwiftUI
import CryptoKit
import CapydokuCore
@testable import Capydoku

final class CheckInDateRecoveryTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("checkin-date-recovery-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func corruptDay(_ url: URL, day: Int) throws -> Data {
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var checkIn = try XCTUnwrap(value["checkIn"] as? [String: Any])
        checkIn["lastClaimedDay"] = day; value["checkIn"] = checkIn
        let changed = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        envelope["payload"] = changed.base64EncodedString()
        envelope["checksum"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try bytes.write(to: url, options: .atomic)
        return bytes
    }

    @MainActor private func renderCheckIn(_ model: AppModel, name: String) {
        model.screen = .checkIn
        let host = UIHostingController(rootView: CheckInView().environmentObject(model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true; window.rootViewController = nil
    }

    @MainActor func testInvalidPrimaryDateRestoresBackupInventoryAndRendersCalendar() throws {
        let directory = directory(), store = SaveStore(directory: directory)
        var original = PlayerProgress()
        let today = Date()
        for daysAgo in stride(from: 6, through: 0, by: -1) {
            _ = original.claimCheckIn(on: today.addingTimeInterval(-Double(daysAgo) * 86_400))
        }
        XCTAssertEqual(original.bonusHints, 7)
        XCTAssertEqual(original.bonusDirect, 1)
        try store.save(original); try store.save(original)
        let rejected = try corruptDay(directory.appendingPathComponent("progress.json"), day: .max)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(model.progress, original)
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix("progress.preserved-") && (try? Data(contentsOf: $0)) == rejected })
        renderCheckIn(model, name: "checkin-invalid-date-backup")
        let before = model.progress
        model.claim()
        XCTAssertEqual(model.progress, before, "A restored claim for today cannot issue the reward again.")
    }

    @MainActor func testInvalidDateWithoutBackupResetsSafelyAndPreservesRejectedBytes() throws {
        let directory = directory(), store = SaveStore(directory: directory)
        try store.save(PlayerProgress())
        let rejected = try corruptDay(directory.appendingPathComponent("progress.json"), day: .max)
        let model = AppModel(saveDirectory: directory, runsTimer: false, feedbackEnabled: false)
        XCTAssertEqual(model.progress.checkIn, CheckInState())
        XCTAssertEqual(model.progress.bonusHints, 0)
        XCTAssertEqual(model.progress.bonusDirect, 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("progress.json")), rejected)
        model.save(force: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .contains { $0.lastPathComponent.hasPrefix("progress.preserved-") && (try? Data(contentsOf: $0)) == rejected })
        renderCheckIn(model, name: "checkin-invalid-date-reset")
    }
}
