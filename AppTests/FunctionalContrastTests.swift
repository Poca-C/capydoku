import XCTest
import SwiftUI
import UIKit
@testable import Capydoku

/// Checks the actual functional palette, including the existing pressed opacity.
/// This does not claim a full visual or system-accessibility audit.
final class FunctionalContrastTests: XCTestCase {
    @MainActor private func rgb(_ color: Color) throws -> [Double] {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(alpha, 1, accuracy: 0.001, "Functional palette colors must be opaque before the pressed-state composite.")
        return [Double(red), Double(green), Double(blue)]
    }

    private func luminance(_ rgb: [Double]) -> Double {
        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return zip(linear, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func contrast(_ foreground: [Double], _ background: [Double]) -> Double {
        let first = luminance(foreground), second = luminance(background)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func composite(_ color: [Double], opacity: Double, over background: [Double]) -> [Double] {
        zip(color, background).map { $0.0 * opacity + $0.1 * (1 - opacity) }
    }

    @MainActor func testSmallSwitchStateLabelsMeetContrastOnBothTracks() throws {
        let text = try rgb(.white)
        for (name, color) in [("ON", CapyPalette.switchOnTrack), ("OFF", CapyPalette.switchOffTrack)] {
            XCTAssertGreaterThanOrEqual(contrast(text, try rgb(color)), 4.5, "The 12pt \(name) label must remain readable.")
        }
    }

    @MainActor func testSwitchStateLabelsRemainReadableDuringPressedOpacity() throws {
        let paper = try rgb(CapyPalette.paper)
        // CapyPressStyle composites the entire enabled control at 0.8 opacity
        // while pressed; both its white text and its track sit over paper.
        let text = composite(try rgb(.white), opacity: 0.8, over: paper)
        for (name, color) in [("ON", CapyPalette.switchOnTrack), ("OFF", CapyPalette.switchOffTrack)] {
            let track = composite(try rgb(color), opacity: 0.8, over: paper)
            XCTAssertGreaterThanOrEqual(contrast(text, track), 4.5, "Pressed \(name) text must not lose its readability.")
        }
    }

    @MainActor func testCheckInStreakAndAvailableOrClaimedWeekdaysMeetContrast() throws {
        XCTAssertGreaterThanOrEqual(contrast(try rgb(CapyPalette.actionOrange), try rgb(CapyPalette.cream)), 4.5)
    }

    @MainActor func testFutureCheckInWeekdaysRemainReadableAsStatusText() throws {
        XCTAssertGreaterThanOrEqual(contrast(try rgb(CapyPalette.checkInSecondaryText), try rgb(CapyPalette.cream)), 4.5)
    }

    @MainActor func testWelcomeBodyLegalLinksAndHeadingMeetContrast() throws {
        let paper = try rgb(CapyPalette.paper)
        let text = try rgb(CapyPalette.ink)
        XCTAssertGreaterThanOrEqual(contrast(text, paper), 4.5, "Welcome body and legal links use 18pt medium text.")
        let headingBackground = composite(try rgb(.orange), opacity: 0.10, over: paper)
        XCTAssertGreaterThanOrEqual(contrast(text, headingBackground), 4.5, "The tinted Welcome heading retains readable brand ink.")
        let pressedLink = composite(text, opacity: StartupWelcomeButtonStyle.pressedOpacity, over: paper)
        XCTAssertGreaterThanOrEqual(contrast(pressedLink, paper), 4.5, "Pressing either legal link must keep its text readable.")
    }

    @MainActor func testWelcomeAcceptLabelMeetsContrastBeforeAndDuringPress() throws {
        let paper = try rgb(CapyPalette.paper)
        let text = try rgb(.white)
        let fill = try rgb(CapyPalette.actionOrange)
        XCTAssertGreaterThanOrEqual(contrast(text, fill), 4.5)
        let opacity = StartupWelcomeButtonStyle.pressedOpacity
        let pressedText = composite(text, opacity: opacity, over: paper)
        let pressedFill = composite(fill, opacity: opacity, over: paper)
        // The existing Accept label is 22pt bold, so the large-text criterion
        // is 3:1. Check its actual whole-control opacity, not just its base fill.
        XCTAssertGreaterThanOrEqual(contrast(pressedText, pressedFill), 3)
    }
}
