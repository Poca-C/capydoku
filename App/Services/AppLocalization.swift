import Foundation
import SwiftUI
import CapydokuCore

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .simplifiedChinese
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

extension AppLanguage {
    func text(_ source: String) -> String { AppLocalization.text(source, language: self) }
}

/// Presentation-only localization. Stable English source keys (including saved
/// hint explanations) remain unchanged in game saves and analytics. Switching
/// language rerenders the same state without creating a new board or hint use.
enum AppLocalization {
    static let resourceNames = ["UIStringsCore", "UIStringsGame", "UIStringsSupport", "UIStringsStartup"]

    struct Catalog {
        var strings: [String: String] = [:]
        var issues: [String] = []
    }

    static func loadCatalog(bundle: Bundle = .main) -> Catalog {
        var catalog = Catalog()
        for name in resourceNames {
            guard let url = bundle.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let values = try? JSONDecoder().decode([String: String].self, from: data) else {
                catalog.issues.append("Missing or invalid localization resource: \(name)")
                continue
            }
            for (source, translated) in values {
                if let existing = catalog.strings[source], existing != translated {
                    catalog.issues.append("Conflicting translation for: \(source)")
                }
                if translated.isEmpty { catalog.issues.append("Empty translation for: \(source)") }
                catalog.strings[source] = translated
            }
        }
        return catalog
    }

    static let catalog = loadCatalog()
    private static let marker = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    private struct Template {
        let source: String
        let translated: String
        let expression: NSRegularExpression
        let arguments: [String]
        let literalLength: Int
    }

    private static let templates: [Template] = catalog.strings.compactMap { source, translated in
        let matches = marker.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return nil }
        var pattern = "^", names: [String] = [], cursor = source.startIndex, literalLength = 0
        for match in matches {
            guard let range = Range(match.range, in: source) else { return nil }
            let literal = String(source[cursor..<range.lowerBound])
            literalLength += literal.count
            pattern += NSRegularExpression.escapedPattern(for: literal) + "([\\s\\S]*?)"
            names.append(String(source[range]))
            cursor = range.upperBound
        }
        let suffix = String(source[cursor...])
        literalLength += suffix.count
        // Never allow an all-placeholder template to translate arbitrary data.
        guard literalLength > 0 else { return nil }
        pattern += NSRegularExpression.escapedPattern(for: suffix) + "$"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return Template(source: source, translated: translated, expression: expression,
                        arguments: names, literalLength: literalLength)
    }.sorted {
        $0.literalLength != $1.literalLength ? $0.literalLength > $1.literalLength : $0.source < $1.source
    }

    static func text(_ source: String, language: AppLanguage) -> String {
        guard language == .simplifiedChinese, !source.isEmpty else { return source }
        return translate(source, depth: 0)
    }

    private static func translate(_ source: String, depth: Int) -> String {
        if let exact = catalog.strings[source] { return exact }
        guard depth < 6 else { return source }
        if source.contains("\n") {
            return source.components(separatedBy: "\n").map { translate($0, depth: depth + 1) }.joined(separator: "\n")
        }
        let range = NSRange(source.startIndex..., in: source)
        for template in templates {
            guard let match = template.expression.firstMatch(in: source, range: range) else { continue }
            var arguments: [String: String] = [:]
            var consistent = true
            for (index, name) in template.arguments.enumerated() {
                guard let range = Range(match.range(at: index + 1), in: source) else { continue }
                let value = String(source[range])
                if let previous = arguments[name], previous != value { consistent = false; break }
                arguments[name] = value
            }
            guard consistent else { continue }
            // Replace placeholders from the template, never rescanning the
            // argument bytes as syntax. Values may themselves use a known key.
            var result = template.translated
            let slots = marker.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for slot in slots {
                guard let slotRange = Range(slot.range, in: result) else { continue }
                let name = String(result[slotRange])
                guard let value = arguments[name] else { continue }
                result.replaceSubrange(slotRange, with: translate(value, depth: depth + 1))
            }
            return result
        }
        return source
    }
}
