import XCTest
import UIKit
@testable import Capydoku

@MainActor private final class CharacterChoreographyRig {
    let window: UIWindow
    let view: ResultCharacterUIView
    private let previous: UIWindow?
    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.ink)
        window.rootViewController = controller; window.makeKeyAndVisible()
        view = ResultCharacterUIView(frame: CGRect(x: 30, y: 120, width: 168, height: 168))
        controller.view.addSubview(view); view.layoutIfNeeded()
    }
    func configure(_ performance: ResultCharacterPerformance, event: UUID?, reduceMotion: Bool = false) {
        view.configure(won: performance != .gentleRetry,
            variant: performance == .starHug ? .proudCrown : .joyfulBounce,
            animationID: event, reduceMotion: reduceMotion, presentationEnabled: true, lowPower: false)
        view.layoutIfNeeded()
    }
    func close() {
        view.cancelPresentation(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
    }
}

final class ResultCharacterChoreographyTests: XCTestCase {
    private func pixels(_ source: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        let succeeded = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            return true
        }
        XCTAssertTrue(succeeded)
        return bytes
    }

    @MainActor func testAllNineBundledPosesAreDistinctTransparentCompleteSquareImages() throws {
        var identities = Set<Data>()
        for performance in ResultCharacterPerformance.allCases {
            let source = try XCTUnwrap(UIImage(named: performance.assetName)?.cgImage)
            XCTAssertEqual(source.width, source.height * 3, "Atlas cells must be complete equal squares")
            let poses = ResultCharacterArtwork.poses(for: performance)
            XCTAssertEqual(poses.count, 3)
            for pose in poses {
                let image = try XCTUnwrap(pose.cgImage)
                XCTAssertEqual(image.width, 512); XCTAssertEqual(image.height, 512)
                let data = try pixels(image)
                identities.insert(Data(data))
                let alpha = stride(from: 3, to: data.count, by: 4).map { data[$0] }
                let transparent = alpha.filter { $0 == 0 }.count
                let opaque = alpha.filter { $0 > 240 }.count
                XCTAssertGreaterThan(transparent, image.width * image.height / 5, "Transparent space must not be a baked matte")
                XCTAssertGreaterThan(opaque, image.width * image.height / 4, "A real full-body pose must be present")
                for x in 0..<image.width {
                    XCTAssertLessThanOrEqual(alpha[x], 16, "No visible artwork may touch the atlas seam")
                    XCTAssertLessThanOrEqual(alpha[(image.height - 1) * image.width + x], 16)
                }
                for y in 0..<image.height {
                    XCTAssertLessThanOrEqual(alpha[y * image.width], 16, "Adjacent poses may not visibly bleed into one another")
                    XCTAssertLessThanOrEqual(alpha[y * image.width + image.width - 1], 16)
                }
            }
        }
        XCTAssertEqual(identities.count, 9, "Each key pose must contain distinct drawn pixels")
    }

    @MainActor func testMissingOrMalformedAtlasFallsBackOnceWithoutCrashingOrReusingAnotherPerformance() throws {
        let fallback = try XCTUnwrap(UIImage(named: "CapyMascot"))
        let malformed = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 20)) }
        var calls: [String] = []
        let cache = ResultCharacterImageCache { name in
            calls.append(name)
            return name == ResultCharacterPerformance.starHug.assetName ? malformed : (name == "CapyMascot" ? fallback : nil)
        }
        XCTAssertEqual(cache.poses(for: .starHug).count, 3)
        XCTAssertEqual(cache.poses(for: .starHug).count, 3)
        XCTAssertEqual(calls.filter { $0 == ResultCharacterPerformance.starHug.assetName }.count, 1)
        XCTAssertTrue(cache.poses(for: .gentleRetry).isEmpty)
        XCTAssertTrue(cache.poses(for: .gentleRetry).isEmpty)
        XCTAssertEqual(calls.filter { $0 == "CapySad" }.count, 1)
    }

    @MainActor func testFreshResultUsesRealPoseContentsAndCancellationImmediatelyRestoresFinalPose() throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        for performance in ResultCharacterPerformance.allCases {
            rig.configure(performance, event: nil)
            let character = try XCTUnwrap(rig.view.layer.sublayers?.first { $0.name == "result-character" })
            let settled = try XCTUnwrap(character.contents) as AnyObject
            let expected = try XCTUnwrap(ResultCharacterArtwork.poses(for: performance).last?.cgImage)
            XCTAssertTrue(settled === expected, "The layer must retain the cached terminal pose")
            XCTAssertNil(character.animation(forKey: "result-pose-sequence"))
            rig.configure(performance, event: UUID())
            let sequence = try XCTUnwrap(character.animation(forKey: "result-pose-sequence") as? CAKeyframeAnimation)
            XCTAssertEqual(sequence.calculationMode, .discrete)
            let images = try XCTUnwrap(sequence.values as? [CGImage])
            XCTAssertEqual(Set(try images.map { Data(try pixels($0)) }).count, 3)
            XCTAssertEqual(sequence.repeatCount, 0); XCTAssertLessThanOrEqual(sequence.duration, 1.2)
            rig.view.cancelPresentation()
            XCTAssertNil(character.animation(forKey: "result-pose-sequence"))
            let cancelled = try XCTUnwrap(character.contents) as AnyObject
            XCTAssertTrue(cancelled === expected, "Cancelling must expose the same terminal pose immediately")
        }
    }

    @MainActor func testReducedMotionRetainsExpressiveFinalPoseWithoutAnyMotionOrLaterReplay() throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        for performance in ResultCharacterPerformance.allCases {
            let event = UUID(); rig.configure(performance, event: event, reduceMotion: true)
            let character = try XCTUnwrap(rig.view.layer.sublayers?.first { $0.name == "result-character" })
            XCTAssertTrue(character.animationKeys()?.isEmpty ?? true)
            let expected = try XCTUnwrap(ResultCharacterArtwork.poses(for: performance).last?.cgImage)
            let settled = try XCTUnwrap(character.contents) as AnyObject
            XCTAssertTrue(settled === expected, "Reduce Motion still displays the expressive terminal pose")
            rig.configure(performance, event: event)
            XCTAssertEqual(rig.view.playedEventCount, 0)
        }
    }

    @MainActor func testActualSmallHostCapturesAnticipationActionAndRecoveryForThreePerformances() async throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        var samples: [UIImage] = []
        for performance in ResultCharacterPerformance.allCases {
            rig.configure(performance, event: UUID())
            var elapsed: UInt64 = 0
            for sample in [100_000_000, 350_000_000, 900_000_000] as [UInt64] {
                try await Task.sleep(nanoseconds: sample - elapsed); elapsed = sample
                let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                samples.append(UIGraphicsImageRenderer(size: rig.view.bounds.size, format: format).image { context in
                    UIColor(CapyPalette.ink).setFill(); context.fill(rig.view.bounds)
                    (rig.view.layer.presentation() ?? rig.view.layer).render(in: context.cgContext)
                })
            }
            rig.view.cancelPresentation()
        }
        let tile: CGFloat = 168
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
        let contactSheet = UIGraphicsImageRenderer(size: CGSize(width: tile * 3, height: tile * 3), format: format).image { context in
            UIColor(CapyPalette.ink).setFill(); context.fill(CGRect(x: 0, y: 0, width: tile * 3, height: tile * 3))
            for (index, sample) in samples.enumerated() {
                sample.draw(in: CGRect(x: CGFloat(index % 3) * tile, y: CGFloat(index / 3) * tile, width: tile, height: tile))
            }
        }
        let attachment = XCTAttachment(image: contactSheet)
        attachment.name = "result-real-pose-choreography-rows-joy-star-retry-columns-100-350-900ms"
        attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(samples.count, 9)
        for row in 0..<3 {
            XCTAssertNotEqual(samples[row * 3].pngData(), samples[row * 3 + 1].pngData())
            XCTAssertNotEqual(samples[row * 3 + 1].pngData(), samples[row * 3 + 2].pngData())
        }
    }
}
