import XCTest
import UIKit
@testable import Capydoku

@MainActor private final class CharacterChoreographyRig {
    let window: UIWindow
    let view: ResultCharacterUIView
    private let previous: UIWindow?
    init(side: CGFloat = 168) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(CapyPalette.ink)
        window.rootViewController = controller; window.makeKeyAndVisible()
        view = ResultCharacterUIView(frame: CGRect(x: 30, y: 120, width: side, height: side))
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

    @MainActor private func layers(_ root: CALayer) -> [CALayer] {
        [root] + (root.sublayers ?? []).flatMap(layers)
    }

    @MainActor private func modelPixels(_ view: UIView) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let picture = UIGraphicsImageRenderer(bounds:view.bounds,format:format).image { view.layer.render(in:$0.cgContext) }
        return try XCTUnwrap(picture.cgImage?.dataProvider?.data) as Data
    }

    @MainActor func testAllTwelveRigPartsPrepareOnceWithVerifiedBoundsAndCachedDecodedImages() throws {
        var calls:[String:Int] = [:]
        let cache = ResultRigImageCache { name in calls[name,default:0] += 1; return UIImage(named:name) }
        XCTAssertTrue(cache.prepare()); XCTAssertTrue(cache.prepare())
        XCTAssertEqual(cache.digestChecks,3); XCTAssertEqual(cache.alphaScanCount,0)
        var unique = Set<Data>()
        for part in ResultRigPart.allCases {
            let image = try XCTUnwrap(cache.image(part))
            XCTAssertTrue(image === cache.image(part))
            let bitmap = try XCTUnwrap(image.cgImage)
            let data = try pixels(bitmap); unique.insert(Data(data))
            let alpha = stride(from:3,to:data.count,by:4).map { data[$0] }
            XCTAssertGreaterThan(alpha.filter { $0 == 0 }.count, bitmap.width * bitmap.height / 100)
            XCTAssertGreaterThan(alpha.filter { $0 > 240 }.count, bitmap.width * bitmap.height / 5)
            XCTAssertLessThanOrEqual(max(bitmap.width,bitmap.height),640)
        }
        XCTAssertEqual(unique.count,12)
        XCTAssertEqual(calls,["CapyRigCore0229":1,"CapyRigLimbs0229":1,"CapyRigLimbs0230":1])
    }

    @MainActor func testArmRefinementRetainsOriginalHeadHandsFeetAndUsesOnlyFourEditedParts() throws {
        let unchanged: [(String, CGRect, ResultRigPart)] = [
            ("CapyRigCore0229", CGRect(x:45,y:102,width:569,height:505), .torso),
            ("CapyRigCore0229", CGRect(x:657,y:135,width:571,height:410), .happyHead),
            ("CapyRigCore0229", CGRect(x:47,y:722,width:576,height:420), .sadHead),
            ("CapyRigCore0229", CGRect(x:705,y:693,width:470,height:450), .star),
            ("CapyRigLimbs0229", CGRect(x:1003,y:187,width:213,height:214), .leftPaw),
            ("CapyRigLimbs0229", CGRect(x:1394,y:145,width:289,height:265), .leftFoot),
            ("CapyRigLimbs0229", CGRect(x:997,y:592,width:210,height:198), .rightPaw),
            ("CapyRigLimbs0229", CGRect(x:1399,y:553,width:296,height:269), .rightFoot)
        ]
        let edited: [(String, CGRect, ResultRigPart)] = [
            ("CapyRigLimbs0230", CGRect(x:117,y:57,width:251,height:370), .leftUpperArm),
            ("CapyRigLimbs0230", CGRect(x:594,y:86,width:196,height:320), .leftForearm),
            ("CapyRigLimbs0230", CGRect(x:104,y:474,width:247,height:363), .rightUpperArm),
            ("CapyRigLimbs0230", CGRect(x:566,y:496,width:208,height:314), .rightForearm)
        ]
        for (name, rect, part) in unchanged + edited {
            let source = try XCTUnwrap(UIImage(named:name)?.cgImage)
            let crop = try XCTUnwrap(source.cropping(to:rect.insetBy(dx:-2,dy:-2)))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let size = CGSize(width:crop.width,height:crop.height)
            let expected = UIGraphicsImageRenderer(size:size,format:format).image { _ in
                UIImage(cgImage:crop).draw(in:CGRect(origin:.zero,size:size))
            }
            XCTAssertEqual(try pixels(XCTUnwrap(ResultCharacterArtwork.rigImage(part)?.cgImage)),
                           try pixels(XCTUnwrap(expected.cgImage)), "\(part) must come from the approved source cutout")
        }
    }

    @MainActor func testUnknownReplacementRigCannotReuseStaleJointRectanglesOrPartiallyAssemble() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let replacement = UIGraphicsImageRenderer(size:CGSize(width:1254,height:1254),format:format).image {
            UIColor.orange.setFill(); $0.fill(CGRect(x:0,y:0,width:1254,height:1254))
        }
        var calls = 0
        let cache = ResultRigImageCache { _ in calls += 1; return replacement }
        XCTAssertFalse(cache.prepare()); XCTAssertFalse(cache.prepare())
        for part in ResultRigPart.allCases { XCTAssertNil(cache.image(part)) }
        XCTAssertEqual(calls,1); XCTAssertEqual(cache.digestChecks,1)
        let missingSecond = ResultRigImageCache { $0 == "CapyRigCore0229" ? UIImage(named:$0) : nil }
        XCTAssertFalse(missingSecond.prepare())
        for part in ResultRigPart.allCases { XCTAssertNil(missingSecond.image(part),"No headless or armless partial rig") }
        let missingRefinedArms = ResultRigImageCache { $0 == "CapyRigLimbs0230" ? nil : UIImage(named:$0) }
        XCTAssertFalse(missingRefinedArms.prepare())
        for part in ResultRigPart.allCases { XCTAssertNil(missingRefinedArms.image(part),"Do not keep a partial rig when the third atlas is absent") }
    }

    @MainActor func testFreshResultMovesIndependentJointsWithoutChangingTexturesAndCancelsToSameRig() throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        for performance in ResultCharacterPerformance.allCases {
            rig.configure(performance,event:nil)
            let settled = try modelPixels(rig.view)
            let character = try XCTUnwrap(rig.view.layer.sublayers?.first { $0.name == "result-character" })
            XCTAssertNil(character.contents,"A valid rig never displays a complete-character fallback image")
            let parts = try XCTUnwrap(character.sublayers)
            XCTAssertEqual(parts.count,12)
            XCTAssertEqual(parts.filter { $0.opacity > 0 }.count,performance == .starHug ? 11 : 10)
            let expectedHead = performance == .gentleRetry ? ResultRigPart.sadHead : .happyHead
            let head = try XCTUnwrap(parts.first { $0.name == expectedHead.layerName })
            let texture = try XCTUnwrap(head.contents) as AnyObject
            let expectedTexture = try XCTUnwrap(ResultCharacterArtwork.rigImage(expectedHead)?.cgImage)
            XCTAssertTrue(texture === expectedTexture)
            rig.configure(performance,event:UUID())
            for piece in parts where piece.opacity > 0 {
                XCTAssertNil(piece.animation(forKey:"contents"))
                XCTAssertNil(piece.animation(forKey:"result-opacity"),"No crossfaded duplicate silhouettes")
                let position = try XCTUnwrap(piece.animation(forKey:"result-rig-position") as? CAKeyframeAnimation)
                XCTAssertEqual(position.calculationMode,.linear)
                XCTAssertEqual(position.values?.count,ResultRigMotion.sampleCount)
                XCTAssertEqual(position.repeatCount,0)
                XCTAssertLessThanOrEqual(position.duration,1.2)
            }
            for part in [ResultRigPart.leftForearm,.rightForearm] {
                let piece = try XCTUnwrap(parts.first { $0.name == part.layerName })
                let rotation = try XCTUnwrap(piece.animation(forKey:"result-rig-rotation") as? CAKeyframeAnimation)
                let values = try XCTUnwrap(rotation.values as? [NSNumber]).map(\.doubleValue)
                XCTAssertGreaterThan(try XCTUnwrap(values.max()) - XCTUnwrap(values.min()),0.1,
                    "A forearm must articulate independently; whole-mascot motion alone is not a rig")
            }
            let lower = try XCTUnwrap(parts.firstIndex { $0.name == ResultRigPart.leftUpperArm.layerName })
            let torso = try XCTUnwrap(parts.firstIndex { $0.name == ResultRigPart.torso.layerName })
            XCTAssertLessThan(lower,torso,"Shoulder roots stay behind the body without changing layer order")
            rig.view.cancelPresentation()
            XCTAssertTrue(layers(rig.view.layer).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
            XCTAssertNil(character.contents)
            XCTAssertEqual(try modelPixels(rig.view),settled,"Completion/cancel must retain the same rig terminal pose")
        }
    }

    @MainActor func testReducedMotionShowsCompleteTerminalRigWithoutDelayedReplay() throws {
        let rig = try CharacterChoreographyRig(); defer { rig.close() }
        for performance in ResultCharacterPerformance.allCases {
            let event = UUID(); rig.configure(performance,event:event,reduceMotion:true)
            XCTAssertTrue(layers(rig.view.layer).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
            let character = try XCTUnwrap(rig.view.layer.sublayers?.first { $0.name == "result-character" })
            XCTAssertNil(character.contents)
            XCTAssertEqual(character.sublayers?.filter { $0.opacity > 0 }.count,performance == .starHug ? 11 : 10)
            let finalPixels = try modelPixels(rig.view)
            rig.configure(performance,event:event)
            XCTAssertEqual(rig.view.playedEventCount,0)
            XCTAssertEqual(try modelPixels(rig.view),finalPixels)
        }
    }

    func testContinuousTracksPreserveBoneLengthsStarGripAndSubpixelInterpolatedElbowContact() throws {
        for performance in ResultCharacterPerformance.allCases {
            let poses = ResultRigMotion.samples(performance)
            XCTAssertEqual(poses.count,73)
            for pose in poses {
                for arm in [pose.leftArm,pose.rightArm] {
                    let length:CGFloat = performance == .joyfulRaise ? 0.20 : 0.18
                    XCTAssertEqual(hypot(arm.elbow.x-arm.shoulder.x,arm.elbow.y-arm.shoulder.y),length,accuracy:0.000001)
                    XCTAssertEqual(hypot(arm.wrist.x-arm.elbow.x,arm.wrist.y-arm.elbow.y),length,accuracy:0.000001)
                }
                if let star = pose.parts[.star] {
                    XCTAssertEqual(pose.leftArm.wrist.x,star.center.x-0.11,accuracy:0.000001)
                    XCTAssertEqual(pose.leftArm.wrist.y,star.center.y+0.035,accuracy:0.000001)
                    XCTAssertEqual(pose.rightArm.wrist.x,star.center.x+0.11,accuracy:0.000001)
                    XCTAssertEqual(pose.rightArm.wrist.y,star.center.y+0.04,accuracy:0.000001)
                }
            }
            for i in 1..<poses.count {
                for pair in [(ResultRigPart.leftUpperArm,ResultRigPart.leftForearm),(.rightUpperArm,.rightForearm)] {
                    func interpolatedJoint(_ part:ResultRigPart,_ direction:CGFloat) throws -> CGPoint {
                        let a = try XCTUnwrap(poses[i-1].parts[part]), b = try XCTUnwrap(poses[i].parts[part])
                        let angles = ResultRigMotion.unwrapped([a.rotation,b.rotation])
                        let angle = (angles[0]+angles[1])/2 + .pi/2, halfLength = a.size.height * 0.64/2
                        return CGPoint(x:(a.center.x+b.center.x)/2 + cos(angle)*halfLength*direction,
                                       y:(a.center.y+b.center.y)/2 + sin(angle)*halfLength*direction)
                    }
                    let upperEnd = try interpolatedJoint(pair.0,1), lowerStart = try interpolatedJoint(pair.1,-1)
                    XCTAssertLessThan(hypot(upperEnd.x-lowerStart.x,upperEnd.y-lowerStart.y),0.0025,
                        "Interpolated elbow gap must remain under 0.5pt at the largest 250pt result (80% footprint)")
                }
            }
            for phase in stride(from:CGFloat(0.01),through:0.99,by:0.01) {
                let before = ResultRigMotion.pose(performance,phase:phase-0.00001)
                let after = ResultRigMotion.pose(performance,phase:phase+0.00001)
                for part in before.parts.keys {
                    let a = try XCTUnwrap(before.parts[part]), b = try XCTUnwrap(after.parts[part])
                    XCTAssertLessThan(hypot(a.center.x-b.center.x,a.center.y-b.center.y),0.001)
                    let angles = ResultRigMotion.unwrapped([a.rotation,b.rotation])
                    XCTAssertLessThan(abs(angles[1]-angles[0]),0.002,"No threshold may swap an elbow branch or full pose")
                }
            }
        }
    }

    @MainActor func testActualRigAtThreeSizesKeepsPartsInBoundsAndTexturesFixedWhileMoving() async throws {
        for side:CGFloat in [140,168,250] {
            let rig = try CharacterChoreographyRig(side:side); defer { rig.close() }
            for performance in ResultCharacterPerformance.allCases {
                rig.configure(performance,event:nil)
                let settled = try modelPixels(rig.view)
                rig.configure(performance,event:UUID())
                try await Task.sleep(nanoseconds:380_000_000)
                let root = try XCTUnwrap(rig.view.layer.presentation())
                let character = try XCTUnwrap(root.sublayers?.first { $0.name == "result-character" })
                for part in character.sublayers ?? [] where part.opacity > 0 {
                    let occupied = character.convert(part.frame,to:root)
                    XCTAssertTrue(rig.view.bounds.insetBy(dx:-0.5,dy:-0.5).contains(occupied),
                        "\(performance) \(side) \(part.name ?? "part") frame \(occupied) exceeds the allocated result decoration \(rig.view.bounds)")
                }
                let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                let image = UIGraphicsImageRenderer(size:rig.view.bounds.size,format:format).image {
                    UIColor(CapyPalette.ink).setFill(); $0.fill(rig.view.bounds); root.render(in:$0.cgContext)
                }
                let attachment = XCTAttachment(image:image)
                attachment.name = "rig-0229-\(performance)-\(Int(side))pt-actual-380ms"
                attachment.lifetime = .keepAlways; add(attachment)
                rig.view.cancelPresentation()
                XCTAssertEqual(try modelPixels(rig.view),settled)
            }
        }
    }

    /// Root records this test's real simulator window. Do not freeze or seek CA.
    /// The extra hold belongs to this evidence host, not to player animations.
    @MainActor func testActualRigPerformancesRunContinuouslyForVideoReview() async throws {
        let rig = try CharacterChoreographyRig(side:250); defer { rig.close() }
        let label = UILabel(frame:CGRect(x:30,y:72,width:320,height:36))
        label.textColor = UIColor(CapyPalette.paper); label.font = .systemFont(ofSize:24,weight:.bold)
        rig.window.rootViewController?.view.addSubview(label)
        for (performance,title) in [(ResultCharacterPerformance.joyfulRaise,"欢呼"),(.starHug,"抱星"),(.gentleRetry,"再试一次")] {
            label.text = title
            rig.configure(performance,event:UUID())
            try await Task.sleep(nanoseconds:1_400_000_000)
            XCTAssertNil(rig.view.activeEventID)
            XCTAssertTrue(layers(rig.view.layer).allSatisfy { $0.animationKeys()?.isEmpty ?? true })
        }
    }
}
