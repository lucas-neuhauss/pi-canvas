import AppKit
import Foundation

/// Renders markdown for the note preview without a web view.
///
/// Foundation parses markdown into an `AttributedString` carrying
/// `presentationIntent` (block structure: headings, lists, quotes, code) and
/// `inlinePresentationIntent` (emphasis, code, strikethrough), but AppKit does
/// not turn either into visual attributes, and the parser does not keep the
/// newlines between blocks. This maps both onto fonts, paragraph styles and
/// separation, which is all the preview needs. Links keep their `link`
/// attribute, so the text view styles and opens them.
enum MarkdownPreview {

    @MainActor
    static func render(
        _ markdown: String,
        baseFontSize: CGFloat,
        textColor: NSColor,
        secondaryColor: NSColor,
        linkColor: NSColor,
        codeColor: NSColor,
        codeBackground: NSColor
    ) -> NSAttributedString {
        let source = taskListGlyphs(markdown)
        guard let parsed = try? AttributedString(markdown: source) else {
            return NSAttributedString(
                string: markdown,
                attributes: [
                    .font: NSFont.systemFont(ofSize: baseFontSize),
                    .foregroundColor: textColor
                ]
            )
        }

        let result = NSMutableAttributedString()
        var lastIntent: PresentationIntent?
        var block = Block()
        block.font = NSFont.systemFont(ofSize: baseFontSize)
        block.color = textColor

        for run in parsed.runs {
            let intent = run.presentationIntent
            let text = String(parsed[run.range].characters)

            if intent != lastIntent {
                // Blocks arrive with no separator between them; the parser only
                // marks where one ends and the next begins.
                if !result.string.isEmpty, !result.string.hasSuffix("\n") {
                    result.append(NSAttributedString(string: "\n"))
                }
                lastIntent = intent
                block = Block(
                    intent: intent,
                    baseFontSize: baseFontSize,
                    textColor: textColor,
                    secondaryColor: secondaryColor,
                    codeBackground: codeBackground
                )
                block.isTask = text.hasPrefix("\u{2610}") || text.hasPrefix("\u{2611}")
                block.isChecked = text.hasPrefix("\u{2611}")
                if let marker = block.marker, !block.isTask {
                    result.append(NSAttributedString(string: marker, attributes: [
                        .font: block.font,
                        .foregroundColor: block.color,
                        .paragraphStyle: block.paragraph
                    ]))
                }
                if let prefix = block.prefix {
                    result.append(NSAttributedString(string: prefix, attributes: [
                        .font: block.font,
                        .foregroundColor: block.color,
                        .paragraphStyle: block.paragraph
                    ]))
                }
            }

            var font = block.font
            var color = block.color
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: block.paragraph
            ]

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) {
                    font = strong(font)
                }
                if inline.contains(.emphasized) {
                    font = italic(font)
                }
                if inline.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.95, weight: .regular)
                    color = codeColor
                    attributes[.backgroundColor] = codeBackground
                }
                if inline.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }

            if block.isTask, block.isChecked {
                // A done item reads as done.
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                color = secondaryColor
            }

            attributes[.font] = font
            attributes[.foregroundColor] = color

            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        if !result.string.isEmpty {
            result.append(NSAttributedString(string: "\n"))
        }
        return result
    }

    // MARK: - Emphasis

    /// Explicit variants rather than `NSFontManager` conversion, which can
    /// silently return the original font for the system face.
    private static func strong(_ font: NSFont) -> NSFont {
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
        }
        return NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
    }

    private static func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Task lists

    /// GitHub-style task lists are not CommonMark. Turn their markers into box
    /// glyphs before parsing so they render as checkboxes; the source file is
    /// untouched.
    static func taskListGlyphs(_ markdown: String) -> String {
        let unchecked = replacing(#"(?m)^(\s*[-*+]\s+)\[ \]"#, with: "$1\u{2610}", in: markdown)
        return replacing(#"(?m)^(\s*[-*+]\s+)\[[xX]\]"#, with: "$1\u{2611}", in: unchecked)
    }

    private static func replacing(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// Everything shared by the runs of one markdown block.
    private struct Block {
        var font = NSFont.systemFont(ofSize: 14)
        var color = NSColor.labelColor
        var paragraph = NSMutableParagraphStyle()
        /// A list bullet or number, when the block is a list item.
        var marker: String?
        /// A leading glyph for blocks that read better with one (a quote bar).
        var prefix: String?
        /// Whether this list item is a rendered task list checkbox.
        var isTask = false
        var isChecked = false

        init() {}

        init(
            intent: PresentationIntent?,
            baseFontSize: CGFloat,
            textColor: NSColor,
            secondaryColor: NSColor,
            codeBackground: NSColor
        ) {
            font = NSFont.systemFont(ofSize: baseFontSize)
            color = textColor
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = baseFontSize * 0.35

            var listDepth = 0
            var ordinal = 1
            var ordered = false
            var isListItem = false

            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    let scale: CGFloat
                    switch level {
                    case 1: scale = 1.7
                    case 2: scale = 1.4
                    case 3: scale = 1.2
                    default: scale = 1.1
                    }
                    font = NSFont.systemFont(ofSize: baseFontSize * scale, weight: .semibold)
                    paragraph.paragraphSpacingBefore = baseFontSize
                    paragraph.paragraphSpacing = baseFontSize * 0.35
                case .codeBlock:
                    font = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.95, weight: .regular)
                    // A full-width block behind the code, not just glyph backgrounds.
                    let textBlock = NSTextBlock()
                    textBlock.backgroundColor = codeBackground
                    textBlock.setValue(100, type: .percentageValueType, for: .width)
                    textBlock.setWidth(8, type: .absoluteValueType, for: .padding)
                    paragraph.textBlocks = [textBlock]
                    paragraph.paragraphSpacingBefore = baseFontSize * 0.5
                    paragraph.paragraphSpacing = baseFontSize * 0.5
                case .blockQuote:
                    color = secondaryColor
                    prefix = "\u{258E}  "
                    paragraph.headIndent = 16
                    paragraph.firstLineHeadIndent = 16
                case .listItem(let value):
                    isListItem = true
                    ordinal = value
                    listDepth += 1
                case .orderedList:
                    // Components run parent → child, so the last one wins: the
                    // innermost list decides which marker a nested item gets.
                    ordered = true
                case .unorderedList:
                    ordered = false
                case .thematicBreak:
                    color = secondaryColor
                default:
                    break
                }
            }

            if isListItem {
                let indent = 2 + CGFloat(max(listDepth - 1, 0)) * 16
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + 16
                paragraph.paragraphSpacing = baseFontSize * 0.15
                marker = ordered ? "\(ordinal). " : "\u{2022}  "
            }
        }
    }
}
