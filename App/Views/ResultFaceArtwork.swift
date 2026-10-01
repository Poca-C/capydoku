import UIKit

struct ResultFaceFeature {
    let image: UIImage
    /// Registration inside the fixed head, not inside the source atlas.
    let frame: CGRect
}

struct ResultFaceParts {
    let base: UIImage
    let openEyes: ResultFaceFeature
    let closedEyes: ResultFaceFeature
    let restMouth: ResultFaceFeature
    let activeMouth: ResultFaceFeature
    let sighAnchor: CGPoint
}

enum ResultFaceArtwork {
    private static let cache = ResultFaceImageCache(
        metadata: {
            Bundle.main.url(forResource: "result-face-artwork-0231", withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) }
        }, load: { UIImage(named: $0) })

    @discardableResult static func prewarm() -> Bool { cache.prepare() }
    static func parts(for performance: ResultCharacterPerformance) -> ResultFaceParts? {
        cache.parts(for: performance)
    }
}

/// A facial set is optional as a whole. Missing or incompatible artwork keeps
/// the complete previous head; it must never leave a face without eyes/mouth.
final class ResultFaceImageCache {
    private struct Descriptor: Decodable {
        struct Piece: Decodable { let rect: [Double]; let frame: [Double] }
        let schemaVersion: Int
        let atlasName: String
        let width: Int
        let height: Int
        let alphaDigest: String
        let parts: [String: Piece]
        let sadSighAnchor: [Double]
    }

    private static let names = ["happyBase", "happyOpenEyes", "happyClosedEyes", "happySmileMouth", "happyCheerMouth",
                                "sadBase", "sadOpenEyes", "sadClosedEyes", "sadFrownMouth", "sadSighMouth"]
    private let metadata: () -> Data?
    private let load: (String) -> UIImage?
    private var prepared = false
    private var happy: ResultFaceParts?
    private var sad: ResultFaceParts?
    private(set) var digestChecks = 0
    private(set) var decodedParts = 0

    init(metadata: @escaping () -> Data?, load: @escaping (String) -> UIImage?) {
        self.metadata = metadata; self.load = load
    }

    func parts(for performance: ResultCharacterPerformance) -> ResultFaceParts? {
        guard prepare() else { return nil }
        return performance == .gentleRetry ? sad : happy
    }

    @discardableResult func prepare() -> Bool {
        if prepared { return happy != nil && sad != nil }
        prepared = true
        guard let data = metadata(), let info = try? JSONDecoder().decode(Descriptor.self, from: data),
              info.schemaVersion == 1, info.atlasName == "CapyResultFaces0231",
              (1...4096).contains(info.width), (1...4096).contains(info.height),
              Set(info.parts.keys) == Set(Self.names), info.sadSighAnchor.count == 2,
              info.sadSighAnchor.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let atlas = load(info.atlasName), atlas.imageOrientation == .up, let source = atlas.cgImage,
              source.width == info.width, source.height == info.height else { return false }
        digestChecks += 1
        guard CapyAlphaPlane.digest(in: source) == info.alphaDigest else { return false }
        let sourceBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        var pieces: [String: ResultFaceFeature] = [:]
        for name in Self.names {
            guard let description = info.parts[name], let cropRect = rect(description.rect),
                  description.rect.allSatisfy({ $0.rounded() == $0 }), sourceBounds.contains(cropRect),
                  let registration = rect(description.frame), unitBounds.contains(registration),
                  let crop = source.cropping(to: cropRect) else { return false }
            // Explicit measured rectangles already include transparent padding.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
            let size = CGSize(width: crop.width, height: crop.height)
            let decoded = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
            }
            pieces[name] = ResultFaceFeature(image: decoded, frame: registration)
            decodedParts += 1
        }
        func group(_ prefix: String, rest: String, active: String) -> ResultFaceParts? {
            guard let base = pieces[prefix + "Base"], let open = pieces[prefix + "OpenEyes"],
                  let closed = pieces[prefix + "ClosedEyes"], let rest = pieces[prefix + rest],
                  let active = pieces[prefix + active] else { return nil }
            return ResultFaceParts(base: base.image, openEyes: open, closedEyes: closed,
                                   restMouth: rest, activeMouth: active,
                                   sighAnchor: CGPoint(x: info.sadSighAnchor[0], y: info.sadSighAnchor[1]))
        }
        // Publish only a complete validated pair, never partially decoded parts.
        guard let readyHappy = group("happy", rest: "SmileMouth", active: "CheerMouth"),
              let readySad = group("sad", rest: "FrownMouth", active: "SighMouth") else { return false }
        happy = readyHappy; sad = readySad
        return true
    }

    private func rect(_ values: [Double]) -> CGRect? {
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
