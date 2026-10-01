import XCTest
@testable import CapydokuCore

final class VisibleConflictAnalysisTests: XCTestCase {
    // Four connected regions, chosen to distinguish geometry from region membership.
    private let regions = [0, 0, 0, 1,
                           0, 2, 2, 1,
                           0, 2, 3, 1,
                           3, 3, 3, 1]

    func testRegionConflictDoesNotRequireSharedRowColumnOrAdjacency() {
        XCTAssertEqual(conflicts(candidate: 2, found: [8]), [
            VisiblePuzzleConflict(otherCell: 8, kinds: [.region])
        ])
    }

    func testRowConflictAcrossRegions() {
        XCTAssertEqual(conflicts(candidate: 0, found: [3]), [
            VisiblePuzzleConflict(otherCell: 3, kinds: [.row])
        ])
    }

    func testColumnConflictAcrossRegions() {
        XCTAssertEqual(conflicts(candidate: 0, found: [12]), [
            VisiblePuzzleConflict(otherCell: 12, kinds: [.column])
        ])
    }

    func testDiagonalNeighborsConflictAcrossRegionsInBothDirections() {
        XCTAssertEqual(conflicts(candidate: 0, found: [5]), [
            VisiblePuzzleConflict(otherCell: 5, kinds: [.adjacent])
        ])
        XCTAssertEqual(conflicts(candidate: 5, found: [0]), [
            VisiblePuzzleConflict(otherCell: 0, kinds: [.adjacent])
        ])
    }

    func testAllSimultaneousKindsAreReturnedInStableOrder() {
        XCTAssertEqual(conflicts(candidate: 0, found: Set([15, 5, 4, 1])), [
            VisiblePuzzleConflict(otherCell: 1, kinds: [.region, .row, .adjacent]),
            VisiblePuzzleConflict(otherCell: 4, kinds: [.region, .column, .adjacent]),
            VisiblePuzzleConflict(otherCell: 5, kinds: [.adjacent])
        ])
    }

    func testNoVisibleConflictDoesNotInferHiddenAnswersOrWrapBoardEdges() {
        XCTAssertEqual(conflicts(candidate: 0, found: []), [])
        XCTAssertEqual(conflicts(candidate: 0, found: [10, 15]), [])
        // Consecutive indices at a row break are not adjacent cells.
        XCTAssertEqual(conflicts(candidate: 3, found: [4]), [])
    }

    func testAlreadyFoundCandidateHasNoNewConflictExplanation() {
        XCTAssertEqual(conflicts(candidate: 0, found: [0]), [])
        XCTAssertEqual(conflicts(candidate: 0, found: [0, 1, 4, 5]), [])
    }

    func testMalformedShapeAndOutOfRangeInputsReturnEmptyWithoutOverflow() {
        for size in [Int.min, -1, 0, 17, Int.max] {
            XCTAssertEqual(VisibleConflictAnalysis.conflicts(size: size, regions: regions,
                                                             candidate: 0, found: [1]), [])
        }
        var negativeRegion = regions
        negativeRegion[15] = -1
        var oversizedRegion = regions
        oversizedRegion[15] = 4
        for shape in [[], Array(regions.dropLast()), negativeRegion, oversizedRegion,
                      Array(repeating: 0, count: 16)] {
            XCTAssertEqual(VisibleConflictAnalysis.conflicts(size: 4, regions: shape,
                                                             candidate: 0, found: [1]), [])
        }
        for candidate in [Int.min, -1, 16, Int.max] {
            XCTAssertEqual(conflicts(candidate: candidate, found: [1]), [])
        }
        for invalidFound in [Int.min, -1, 16, Int.max] {
            // Do not produce a partial explanation from malformed visible state.
            XCTAssertEqual(conflicts(candidate: 0, found: [1, invalidFound]), [])
        }
    }

    private func conflicts(candidate: Int, found: Set<Int>) -> [VisiblePuzzleConflict] {
        VisibleConflictAnalysis.conflicts(size: 4, regions: regions, candidate: candidate, found: found)
    }
}
