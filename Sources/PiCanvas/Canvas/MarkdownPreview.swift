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
@MainActor
enum MarkdownPreview {

    static func render(
        _ markdown: String,
        baseFontSize: CGFloat,
        textColor: NSColor,
        secondaryColor: NSColor,
        linkColor: NSColor,
        codeColor: NSColor,
        codeBackground: NSColor
    ) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: markdown) else {
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
                block = Block(intent: intent, baseFontSize: baseFontSize, textColor: textColor, secondaryColor: secondaryColor)
                if let marker = block.marker {
                    result.append(NSAttributedString(string: marker, attributes: [
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
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if inline.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
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

    /// Everything shared by the runs of one markdown block.
    private struct Block {
        var font = NSFont.systemFont(ofSize: 14)
        var color = NSColor.labelColor
        var paragraph = NSMutableParagraphStyle()
        /// A list bullet or number, when the block is a list item.
        var marker: String?

        init() {}

        init(intent: PresentationIntent?, baseFontSize: CGFloat, textColor: NSColor, secondaryColor: NSColor) {
            font = NSFont.systemFont(ofSize: baseFontSize)
            color = textColor
            paragraph.lineSpacing = 2

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
                    paragraph.paragraphSpacingBefore = baseFontSize * 0.9
                    paragraph.paragraphSpacing = baseFontSize * 0.25
                case .codeBlock:
                    font = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.95, weight: .regular)
                case .blockQuote:
                    color = secondaryColor
                    paragraph.headIndent = 14
                    paragraph.firstLineHeadIndent = 14
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
                default:
                    break
                }
            }

            if isListItem {
                let indent = CGFloat(max(listDepth - 1, 0)) * 18
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent + 18
                marker = ordered ? "\(ordinal). " : "\u{2022}  "
            } else if paragraph.paragraphSpacing == 0 {
                paragraph.paragraphSpacing = baseFontSize * 0.3
            }
        }
    }
}
