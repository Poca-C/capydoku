import XCTest
import SwiftUI
import CapydokuCore
@testable import Capydoku

final class AppLocalizationTests: XCTestCase {
    private let chinese = AppLanguage.simplifiedChinese

    private func packagedPuzzles() throws -> [Puzzle] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "levels", withExtension: "json"))
        return try JSONDecoder().decode([Puzzle].self, from: Data(contentsOf: url))
    }

    private func placeholders(_ text: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    func testAllFourBundledCatalogsLoadWithoutMissingEmptyOrConflictingEntries() throws {
        XCTAssertEqual(Set(AppLocalization.resourceNames),
                       ["UIStringsCore", "UIStringsGame", "UIStringsSupport", "UIStringsStartup"])
        let catalog = AppLocalization.loadCatalog()
        XCTAssertTrue(catalog.issues.isEmpty, catalog.issues.joined(separator: "\n"))
        for name in AppLocalization.resourceNames {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json"), name)
            let entries = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
            XCTAssertFalse(entries.isEmpty, name)
            for (source, translated) in entries {
                XCTAssertFalse(source.isEmpty, name)
                XCTAssertFalse(translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source)
                XCTAssertEqual(catalog.strings[source], translated, source)
                // Error copy may intentionally omit technical arguments, but
                // a translation must never introduce an unavailable argument.
                XCTAssertTrue(try placeholders(translated).isSubset(of: placeholders(source)), source)
            }
        }
        XCTAssertEqual(catalog.strings["Your language preference could not be saved. Please try again."], "语言设置保存失败，请重试。")
        XCTAssertEqual(catalog.strings["Confirm capybara"], "确认卡皮巴拉")
        XCTAssertEqual(catalog.strings["Language"], "语言")
        XCTAssertEqual(catalog.strings["Accept"], "同意并继续")
    }

    func testChineseIsDefaultAndBothLanguageNamesRemainRecognizable() {
        XCTAssertEqual(EnvironmentValues().appLanguage, .simplifiedChinese)
        XCTAssertEqual(chinese.text("Settings"), "设置")
        XCTAssertEqual(chinese.text("简体中文"), "简体中文")
        XCTAssertEqual(chinese.text("English"), "English")
        XCTAssertEqual(AppLanguage.english.text("简体中文"), "简体中文")
        XCTAssertEqual(AppLanguage.english.text("English"), "English")
    }

    func testNumericAndSpecificTemplatesPreserveValuesAndChooseWholeSentence() {
        let examples: [(String, String)] = [
            ("Level 151", "第 151 关"),
            ("Level 150. Score 20480. 8 of 10 found.", "第 150 关。分数 20480。已找到 8 只，共 10 只。"),
            ("One heart left. 7 of 10 found", "只剩一颗爱心。已找到 7 只，共 10 只"),
            ("8 of 10 found", "已找到 8 只，共 10 只"),
            ("0 available", "剩余 0 次"),
            ("Row 10, column 8, region 3", "第 10 行，第 8 列，第 3 号区域"),
            ("Day 7, claimed", "第7天，已领取"),
            ("Day 1, not claimed", "第1天，未领取"),
            ("Starting lives: 3", "初始生命：3"),
            ("Free hints per new level: 0", "每个新关卡免费提示：0"),
            ("Free finds per new level: 5", "每个新关卡免费找答案：5"),
            ("12345 seconds", "12345秒"),
            ("4000 ms / 150 attempts", "4000毫秒 / 150次尝试")
        ]
        for (source, expected) in examples { XCTAssertEqual(chinese.text(source), expected, source) }
    }

    func testNestedRowColumnAndRegionNamesTranslateInsideSolverExplanations() {
        for (sourceUnit, translatedUnit) in [("Row 10", "第 10 行"), ("Column 8", "第 8 列"), ("Region 3", "第 3 号区域")] {
            let source = "\(sourceUnit) has only one candidate: row 10, column 8. Exclude other cells in its row, column, region and all touching cells."
            let expected = "\(translatedUnit)只剩一个候选格：第 10 行、第 8 列。请排除与它同行、同列、同区域的其他格，以及所有相邻格。"
            XCTAssertEqual(chinese.text(source), expected)
        }
        XCTAssertEqual(chinese.text("Region 4 must contain one capybara. Every highlighted cell conflicts with all remaining candidates in that unit: whichever candidate is chosen, the highlighted cells would break a row, column, region or touching rule."),
                       "第 4 号区域必须有一只卡皮巴拉。每个高亮格都与这个单元内的所有剩余候选格冲突：无论选择哪个候选格，高亮格都会违反行、列、区域或不能相邻的规则。")
        XCTAssertEqual(chinese.text("All candidates in region 9 lie in row 10. Exclude cells in that row outside this region."),
                       "第 9 号区域的所有候选格都在第 10 行。请排除这一行中不属于该区域的格子。")
        XCTAssertEqual(chinese.text("All candidates in region 9 lie in column 10. Exclude cells in that column outside this region."),
                       "第 9 号区域的所有候选格都在第 10 列。请排除这一列中不属于该区域的格子。")
    }

    func testTwoUnitLockRecursivelyTranslatesAllUnitFamiliesWithoutLosingIndices() {
        let families = [("rows", "行"), ("columns", "列"), ("regions", "区域")]
        for source in families {
            for target in families where source.0 != target.0 {
                let english = "The two \(source.0) 1 and 10 need two capybaras. All their remaining candidates lie in \(target.0) 3 and 8, so both of those \(target.0) are reserved for this pair. Exclude their highlighted cells outside the pair."
                let expected = "编号为 1、10 的\(source.1)各需要一只卡皮巴拉。它们的剩余候选格全部位于编号为 3、8 的\(target.1)内，因此这一对已占据相应的\(target.1)。请排除这两个目标单元内、不属于这一对的高亮格。"
                XCTAssertEqual(chinese.text(english), expected)
            }
        }
    }

    func testHintAccessibilitySentenceTranslatesRuleAndMultipleExplanationSentences() {
        let hint = "Hint. Single candidate. Row 10 has only one candidate: row 10, column 8. Exclude other cells in its row, column, region and all touching cells."
        XCTAssertEqual(chinese.text(hint),
                       "提示。唯一候选格。第 10 行只剩一个候选格：第 10 行、第 8 列。请排除与它同行、同列、同区域的其他格，以及所有相邻格。")
        let contradiction = "Hint. Contradiction check. Contradiction check: placing a capybara in row 8, column 10 leaves no complete arrangement satisfying all four rules. This cell can be excluded."
        XCTAssertEqual(chinese.text(contradiction),
                       "提示。反证检查。反证检查：如果在第 8 行、第 10 列放置卡皮巴拉，就无法找到同时满足四条规则的完整布局，因此可以排除这个格子。")
    }

    func testActualPackTutorialCoversAllFourRulesAndAllOperationsInChinese() throws {
        let puzzle = try XCTUnwrap(try packagedPuzzles().first { $0.id == 1 })
        let steps = PuzzleHints.tutorial(puzzle: puzzle)
        let expected: [(String, String, String)] = [
            ("row", "每行一只", "每一行恰好藏着一只卡皮巴拉。"),
            ("column", "每列一只", "每一列也恰好有一只卡皮巴拉。"),
            ("region", "每个区域一只", "每个连通的颜色区域恰好有一只卡皮巴拉。"),
            ("neighbors", "保持距离", "卡皮巴拉不能相邻，斜向也不行。"),
            ("mark", "单击标记 X", "只有一个格子的区域已经确定了卡皮巴拉的位置。高亮格与它冲突，请单击标记 X。"),
            ("undo", "再次单击撤销", "再次单击同一个格子，移除 X。"),
            ("swipe", "沿一行滑动", "从第一个高亮格滑到第二个，给两个格子都标记 X。"),
            ("swipeVertical", "沿一列滑动", "现在沿竖直方向滑过两个高亮格。横向或纵向滑动会标记 X，斜向滑动不会。"),
            ("find", "双击寻找", "高亮区域只有一个格子，卡皮巴拉一定在这里。双击找到它，再运用四条规则寻找其他卡皮巴拉。")
        ]
        XCTAssertEqual(steps.map(\.id), expected.map { $0.0 })
        for (id, title, instruction) in expected {
            let step = try XCTUnwrap(steps.first { $0.id == id })
            XCTAssertEqual(chinese.text(step.title), title, id)
            XCTAssertEqual(chinese.text(step.instruction), instruction, id)
            XCTAssertEqual(AppLanguage.english.text(step.title), step.title, id)
            XCTAssertEqual(AppLanguage.english.text(step.instruction), step.instruction, id)
        }
    }

    func testSavedEnglishHintsFromRealBoardsRemainUsableInEitherLanguage() throws {
        let puzzles = try packagedPuzzles()
        // Read real solver output, including harder representative boards;
        // do not substitute hand-written explanations for all integration cases.
        for id in [1, 2, 3, 10, 30, 60, 100, 150] {
            let puzzle = try XCTUnwrap(puzzles.first { $0.id == id })
            let hint = try XCTUnwrap(PuzzleHints.next(puzzle: puzzle, found: [], marks: []), "Level \(id)")
            let saved = try JSONEncoder().encode(hint)
            let restored = try JSONDecoder().decode(PuzzleHint.self, from: saved)
            let rule = chinese.text(restored.rule), explanation = chinese.text(restored.explanation)
            XCTAssertNotEqual(rule, restored.rule, "Untranslated rule on level \(id): \(restored.rule)")
            XCTAssertNotEqual(explanation, restored.explanation, "Untranslated hint on level \(id)")
            XCTAssertNotNil(explanation.range(of: #"[\u4E00-\u9FFF]"#, options: .regularExpression))
            for fragment in ["capybara", "candidate", "region", "column", "row", "{0}"] {
                XCTAssertFalse(explanation.lowercased().contains(fragment), "Level \(id): \(explanation)")
            }
            XCTAssertEqual(AppLanguage.english.text(restored.rule), hint.rule)
            XCTAssertEqual(AppLanguage.english.text(restored.explanation), hint.explanation)
            XCTAssertEqual(restored.cells, hint.cells)
            XCTAssertEqual(restored, hint, "Localization must work with existing English save data.")
        }
    }

    func testMultilineSaveWarningsTranslateEachKnownLineAndPreserveSeparators() {
        let source = "Primary save could not be read: Save integrity check failed.\nThe primary save was unavailable. Your previous valid backup has been restored.\n\nRecovered 2 interrupted tool reward(s) to your inventory. No board actions were replayed.\nThe recovered state could not be saved: Disk full.\n"
        let expected = "主存档读取失败。\n主存档不可用，已恢复最近的有效备份。\n\n已将 2 次中断的道具奖励补入库存，棋盘未重复执行操作。\n恢复后的进度保存失败，请重试。\n"
        XCTAssertEqual(chinese.text(source), expected)
        XCTAssertEqual(AppLanguage.english.text(source), source)
        XCTAssertEqual(chinese.text("Backup could not be read: missing file\nNo valid save could be recovered. Starting with initial progress; damaged or incompatible files have been retained."),
                       "备份存档读取失败。\n未找到可恢复的有效存档，已从初始进度开始。损坏或不兼容的文件已保留。")
    }

    func testExactMultilineCopyAndNestedLegalTitleUseTheirIntendedTranslations() {
        XCTAssertEqual(chinese.text("Follow the clues.\nFind every capy."), "循着线索，\n找齐卡皮巴拉。")
        XCTAssertEqual(chinese.text("A little logic.\nA lot of capy."), "动动脑筋，\n遇见卡皮巴拉。")
        XCTAssertEqual(chinese.text("1 Capy per\ncolumn and row"), "每行每列\n一只卡皮巴拉")
        XCTAssertEqual(chinese.text("The publisher has not supplied the final Privacy Policy for this internal build."),
                       "发行方尚未为本内部测试版提供正式的隐私政策。")
    }

    func testEnglishIsByteForByteSourceAndUnknownTechnicalValuesStayUnchanged() {
        for source in AppLocalization.catalog.strings.keys {
            XCTAssertEqual(AppLanguage.english.text(source), source)
        }
        let sourceValues = ["", " ", "\n", "18446744073709551615", "demo-v3.1+local", "A5D31D00-258C-42D8-AAC9-8750C44CE5CC", "🦫 玩家A / local", "  Unrecognized custom copy.\n"]
        for source in sourceValues {
            XCTAssertEqual(chinese.text(source), source)
            XCTAssertEqual(AppLanguage.english.text(source), source)
        }
        let rendered = "Level 150. Score 20480. 8 of 10 found."
        XCTAssertEqual(AppLanguage.english.text(rendered), rendered)
        // Literal braces in a captured value are data, not replacement syntax.
        XCTAssertEqual(chinese.text("Day {1}, claimed"), "第{1}天，已领取")
    }
}
