import AppKit

/// Draws the app icon at launch so the Dock does not show a generic icon.
enum AppIcon {

    static func make() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // Rounded background with a soft vertical gradient.
            let inset: CGFloat = 26
            let backgroundRect = rect.insetBy(dx: inset, dy: inset)
            let backgroundPath = NSBezierPath(
                roundedRect: backgroundRect,
                xRadius: 112,
                yRadius: 112
            )
            let gradient = NSGradient(colors: [
                NSColor(srgbRed: 0.157, green: 0.169, blue: 0.216, alpha: 1),
                NSColor(srgbRed: 0.075, green: 0.082, blue: 0.110, alpha: 1)
            ])
            gradient?.draw(in: backgroundPath, angle: -90)

            // Canvas dot grid.
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setFill()
            let spacing: CGFloat = 46
            var y = backgroundRect.minY + spacing
            while y < backgroundRect.maxY - spacing / 2 {
                var x = backgroundRect.minX + spacing
                while x < backgroundRect.maxX - spacing / 2 {
                    NSBezierPath(ovalIn: NSRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
                    x += spacing
                }
                y += spacing
            }

            // Two agent panels, the back one dimmer.
            let back = NSRect(x: 120, y: 268, width: 236, height: 150)
            let front = NSRect(x: 172, y: 96, width: 236, height: 150)

            func draw(panel rect: NSRect, border: NSColor, fill: NSColor, accent: NSColor, alpha: CGFloat) {
                context.saveGState()
                context.setAlpha(alpha)
                let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
                fill.setFill()
                path.fill()
                border.setStroke()
                path.lineWidth = 5
                path.stroke()

                NSBezierPath(ovalIn: NSRect(x: rect.minX + 20, y: rect.maxY - 34, width: 14, height: 14)).fill()
                accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 20, y: rect.maxY - 34, width: 14, height: 14)).fill()

                // Prompt-ish lines.
                accent.setFill()
                var lineY = rect.maxY - 74
                let widths: [CGFloat] = [0.62, 0.44, 0.72]
                for widthFraction in widths {
                    let lineWidth = (rect.width - 44) * widthFraction
                    NSBezierPath(
                        roundedRect: NSRect(x: rect.minX + 22, y: lineY, width: lineWidth, height: 10),
                        xRadius: 5,
                        yRadius: 5
                    ).fill()
                    lineY -= 24
                }
                context.restoreGState()
            }

            draw(
                panel: back,
                border: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14),
                fill: NSColor(srgbRed: 0.133, green: 0.141, blue: 0.180, alpha: 1),
                accent: NSColor(srgbRed: 0.42, green: 0.68, blue: 0.98, alpha: 1),
                alpha: 0.9
            )
            draw(
                panel: front,
                border: NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: 0.85),
                fill: NSColor(srgbRed: 0.106, green: 0.113, blue: 0.149, alpha: 1),
                accent: NSColor(srgbRed: 0.65, green: 0.51, blue: 0.98, alpha: 1),
                alpha: 1.0
            )

            return true
        }
        return image
    }
}
