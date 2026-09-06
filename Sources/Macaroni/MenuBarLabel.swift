import AppKit

/// Draws the menu bar item: the Macaroni glyph with two lines of throughput
/// beside it.
///
/// SwiftUI's MenuBarExtra label is built for a single symbol, so rather than
/// fighting it with stacked Text views, we render exactly what we want into an
/// NSImage and hand that over. Marked as a template image, so macOS tints it
/// for light or dark menu bars and highlights it correctly when clicked.
enum MenuBarLabel {

    private static let textWidth: CGFloat = 50
    private static let iconSize: CGFloat = 13
    private static let gap: CGFloat = 3.5
    private static let height: CGFloat = 20

    /// Used when the network readout is switched off — the item shrinks back to
    /// just the glyph rather than showing a frozen 0 B/s.
    static func iconOnly() -> NSImage {
        let icon = symbol()
        let image = NSImage(size: NSSize(width: 18, height: height), flipped: false) { _ in
            icon?.draw(in: NSRect(x: 2, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
            return true
        }
        image.isTemplate = true
        return image
    }

    static func render(download: String, upload: String) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        // Squeeze two lines into menu bar height: without a fixed line height
        // the second line falls off the bottom.
        paragraph.minimumLineHeight = 9.5
        paragraph.maximumLineHeight = 9.5

        let attributes: [NSAttributedString.Key: Any] = [
            // Monospaced digits keep the item from resizing as numbers change,
            // which would jitter every icon to its left.
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: "\(download)\n\(upload)", attributes: attributes)

        let icon = symbol()
        let width = iconSize + gap + textWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            icon?.draw(
                in: NSRect(
                    x: 0,
                    y: (height - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                )
            )
            text.draw(in: NSRect(
                x: iconSize + gap,
                y: 0,
                width: textWidth,
                height: height - 0.5
            ))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbol() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Macaroni")
        return image?.withSymbolConfiguration(configuration)
    }
}
