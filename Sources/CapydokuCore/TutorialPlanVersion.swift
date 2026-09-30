/// Pins the step identities and targets used by an in-progress introduction.
/// Saves written before this field existed use `legacy`; new attempts use `current`.
public enum TutorialPlanVersion: Int, Codable, Sendable {
    case legacy = 1
    case boardDriven = 2

    public static let current = Self.boardDriven
}
