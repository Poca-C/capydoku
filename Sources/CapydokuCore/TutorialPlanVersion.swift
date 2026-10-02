/// Pins the step identities and targets used by an in-progress introduction.
/// Saves written before this field existed use `legacy`; new attempts use `current`.
public enum TutorialPlanVersion: Int, Codable, Sendable {
    case legacy = 1
    case boardDriven = 2
    case playAlong = 3

    public static let current = Self.playAlong
}
