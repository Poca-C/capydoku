import Foundation

/// One consumed hint, retained until it is applied or dismissed. Restoring it
/// presents the original preview without consuming another inventory item.
public struct HintUseState: Codable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var hint: PuzzleHint
    public var source: ToolInventorySource?
    public var inventoryBefore: Int
    public var inventoryAfter: Int
    public var previewPresented: Bool

    public init(id: UUID = UUID(), sessionID: UUID, hint: PuzzleHint,
                source: ToolInventorySource?, inventoryBefore: Int, inventoryAfter: Int,
                previewPresented: Bool = false) {
        self.id = id
        self.sessionID = sessionID
        self.hint = hint
        self.source = source
        self.inventoryBefore = inventoryBefore
        self.inventoryAfter = inventoryAfter
        self.previewPresented = previewPresented
    }
}
