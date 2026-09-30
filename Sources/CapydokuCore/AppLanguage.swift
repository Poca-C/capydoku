import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }
    public var localeIdentifier: String { rawValue }
    public var nativeName: String { self == .simplifiedChinese ? "简体中文" : "English" }
    public var displayName: String { nativeName }
}
