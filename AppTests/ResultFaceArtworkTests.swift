import XCTest
import UIKit
@testable import Capydoku

final class ResultFaceArtworkTests: XCTestCase {
    @MainActor private func bundledResources() throws -> (Data, UIImage) {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "result-face-artwork-0231", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let atlas = try XCTUnwrap(UIImage(named: "CapyResultFaces0231"))
        XCTAssertNotNil(atlas.cgImage)
        return (data, atlas)
    }

    private func images(_ parts: ResultFaceParts) -> [UIImage] {
        [parts.base, parts.openEyes.image, parts.closedEyes.image, parts.restMouth.image, parts.activeMouth.image]
    }

    private func changingPiece(_ name: String, in data: Data, change: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var parts = try XCTUnwrap(json["parts"] as? [String: [String: Any]])
        var piece = try XCTUnwrap(parts[name])
        change(&piece); parts[name] = piece; json["parts"] = parts
        return try JSONSerialization.data(withJSONObject: json)
    }

    /// A failed optional set must stay entirely unavailable for this cache's
    /// lifetime, even if callers immediately ask for the other expression or
    /// a later layout supplies working resources. A new cache owns any retry.
    @MainActor private func assertWholeSetFailsWithoutRetry(metadata initialData: Data?, atlas initialAtlas: UIImage?,
                                                           repairedData: Data, repairedAtlas: UIImage,
                                                           file: StaticString = #filePath, line: UInt = #line) {
        var suppliedData = initialData, suppliedAtlas = initialAtlas
        var metadataLoads = 0, atlasLoads = 0
        let cache = ResultFaceImageCache(metadata: {
            metadataLoads += 1; return suppliedData
        }, load: { _ in
            atlasLoads += 1; return suppliedAtlas
        })
        // Request happy first: late validation of a sad piece must not leak an
        // already-decoded happy half into the character before failure.
        XCTAssertNil(cache.parts(for: .joyfulRaise), file: file, line: line)
        XCTAssertNil(cache.parts(for: .gentleRetry), file: file, line: line)
        XCTAssertNil(cache.parts(for: .starHug), file: file, line: line)
        XCTAssertFalse(cache.prepare(), file: file, line: line)
        let attemptedLoads = (metadataLoads, atlasLoads)
        suppliedData = repairedData; suppliedAtlas = repairedAtlas
        for performance in ResultCharacterPerformance.allCases {
            XCTAssertNil(cache.parts(for: performance), "A failed set cannot silently change faces during a later layout.", file: file, line: line)
        }
        XCTAssertFalse(cache.prepare(), file: file, line: line)
        XCTAssertEqual(metadataLoads, 1, file: file, line: line)
        XCTAssertEqual(metadataLoads, attemptedLoads.0, file: file, line: line)
        XCTAssertEqual(atlasLoads, attemptedLoads.1, file: file, line: line)
    }

    @MainActor func testFinalBundledAtlasLoadsOnceAndAllTenRasterPartsKeepStableIdentity() throws {
        let (data, atlas) = try bundledResources()
        var metadataLoads = 0, atlasNames: [String] = []
        let cache = ResultFaceImageCache(metadata: {
            metadataLoads += 1; return data
        }, load: { name in
            atlasNames.append(name)
            return name == "CapyResultFaces0231" ? atlas : nil
        })
        XCTAssertTrue(cache.prepare())
        let happy = try XCTUnwrap(cache.parts(for: .joyfulRaise))
        let sad = try XCTUnwrap(cache.parts(for: .gentleRetry))
        let originals = images(happy) + images(sad)
        XCTAssertEqual(Set(originals.map(ObjectIdentifier.init)).count, 10)
        let decodedPixels = try originals.map { image -> Data in
            let raster = try XCTUnwrap(image.cgImage)
            XCTAssertGreaterThan(raster.width, 0); XCTAssertGreaterThan(raster.height, 0)
            return try XCTUnwrap(raster.dataProvider?.data) as Data
        }
        XCTAssertEqual(Set(decodedPixels).count, 10, "Distinct real base/eyes/mouth pixels must exist, not ten wrappers around one stand-in.")
        for _ in 0..<4 {
            XCTAssertTrue(cache.prepare())
            for performance in ResultCharacterPerformance.allCases {
                let current = images(try XCTUnwrap(cache.parts(for: performance)))
                let expected = performance == .gentleRetry ? images(sad) : images(happy)
                XCTAssertTrue(zip(current, expected).allSatisfy { pair in pair.0 === pair.1 }, "Stable cached images keep repeated layout from cancelling facial motion.")
            }
        }
        XCTAssertEqual(metadataLoads, 1)
        XCTAssertEqual(atlasNames, ["CapyResultFaces0231"])
    }

    @MainActor func testMissingMetadataMalformedMetadataAndMissingAtlasNeverPublishPartialFacesOrRetry() throws {
        let (data, atlas) = try bundledResources()
        assertWholeSetFailsWithoutRetry(metadata: nil, atlas: atlas, repairedData: data, repairedAtlas: atlas)
        assertWholeSetFailsWithoutRetry(metadata: Data("{\"schemaVersion\":".utf8), atlas: atlas, repairedData: data, repairedAtlas: atlas)
        assertWholeSetFailsWithoutRetry(metadata: data, atlas: nil, repairedData: data, repairedAtlas: atlas)
    }

    @MainActor func testWrongAtlasDimensionsOrFlattenedAlphaFallsBackAsOneSetWithoutRetry() throws {
        let (data, atlas) = try bundledResources()
        let source = try XCTUnwrap(atlas.cgImage)
        let cropped = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: source.width - 1, height: source.height)))
        assertWholeSetFailsWithoutRetry(metadata: data, atlas: UIImage(cgImage: cropped), repairedData: data, repairedAtlas: atlas)
        // A common malformed export keeps the dimensions but bakes a matte.
        // Derive it from the actual final atlas, not substitute facial artwork.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let size = CGSize(width: source.width, height: source.height)
        let flattened = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(bounds)
            atlas.draw(in: bounds)
        }
        let flattenedRaster = try XCTUnwrap(flattened.cgImage)
        XCTAssertEqual(flattenedRaster.width, source.width)
        XCTAssertEqual(flattenedRaster.height, source.height)
        XCTAssertNotEqual(CapyAlphaPlane.digest(in: flattenedRaster), CapyAlphaPlane.digest(in: source),
                          "The malformed export fixture must actually alter alpha before testing rejection.")
        assertWholeSetFailsWithoutRetry(metadata: data, atlas: flattened, repairedData: data, repairedAtlas: atlas)
    }

    @MainActor func testMissingLastPieceOrOutOfBoundsCropAndRegistrationRejectsAlsoTheValidHappyHalf() throws {
        let (data, atlas) = try bundledResources()
        var missing = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var parts = try XCTUnwrap(missing["parts"] as? [String: [String: Any]])
        parts.removeValue(forKey: "sadSighMouth"); missing["parts"] = parts
        let missingData = try JSONSerialization.data(withJSONObject: missing)
        assertWholeSetFailsWithoutRetry(metadata: missingData, atlas: atlas, repairedData: data, repairedAtlas: atlas)
        let source = try XCTUnwrap(atlas.cgImage)
        let invalidCrop = try changingPiece("sadSighMouth", in: data) {
            $0["rect"] = [source.width - 4, source.height - 4, 12, 12]
        }
        assertWholeSetFailsWithoutRetry(metadata: invalidCrop, atlas: atlas, repairedData: data, repairedAtlas: atlas)
        let invalidFrame = try changingPiece("sadSighMouth", in: data) {
            $0["frame"] = [0.95, 0.95, 0.2, 0.2]
        }
        assertWholeSetFailsWithoutRetry(metadata: invalidFrame, atlas: atlas, repairedData: data, repairedAtlas: atlas)
    }
}
