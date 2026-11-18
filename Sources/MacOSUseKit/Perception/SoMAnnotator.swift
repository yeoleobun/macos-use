import CoreGraphics
import CoreText
import Foundation

/// Draws crisp Set-of-Mark (SoM) bounding boxes and numbered pill tags `[1]..[N]` onto a captured `CGImage`.
public enum SoMAnnotator {
    public static func annotate(
        image: CGImage,
        transform: CaptureTransform,
        elements: [UIElement]
    ) -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        // Draw original screenshot into CGContext (bottom-left CoreGraphics origin)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scaleHint = max(1.0, Double(max(width, height)) / 1000.0)
        let lineWidth = CGFloat(min(3.0, max(1.5, 1.8 * scaleHint)))
        let fontSize = CGFloat(min(18.0, max(11.0, 12.0 * scaleHint)))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)

        for elem in elements {
            let topLeftRect = transform.globalToImageTopLeft(elem.frame)
            guard topLeftRect.width >= 4, topLeftRect.height >= 4 else { continue }

            // Convert top-left pixel rect into CoreGraphics bottom-left coordinate space
            let cgY = CGFloat(height) - topLeftRect.origin.y - topLeftRect.size.height
            let boxRect = CGRect(
                x: topLeftRect.origin.x,
                y: cgY,
                width: topLeftRect.size.width,
                height: topLeftRect.size.height
            )

            let color = badgeColor(for: elem)
            ctx.saveGState()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lineWidth)
            ctx.stroke(boxRect.insetBy(dx: 0.5, dy: 0.5))

            // Render numbered pill badge at top-left corner of the bounding box
            let badgeText = "\(elem.index)" as CFString
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
            if let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, badgeText, attrs as CFDictionary) {
                let line = CTLineCreateWithAttributedString(attrStr)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                let padX: CGFloat = max(4.0, fontSize * 0.35)
                let padY: CGFloat = max(2.0, fontSize * 0.2)
                let pillW = textWidth + padX * 2.0
                let pillH = ascent + descent + padY * 2.0

                // Place pill just above box top edge if room, otherwise anchored inside top-left
                let preferredY = boxRect.maxY
                let pillY = (preferredY + pillH <= CGFloat(height))
                    ? preferredY
                    : max(0, boxRect.maxY - pillH)
                let pillX = min(max(0, boxRect.minX), max(0, CGFloat(width) - pillW))
                let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)

                ctx.setFillColor(color)
                let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
                ctx.addPath(pillPath)
                ctx.fillPath()

                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: pillRect.minX + padX, y: pillRect.minY + padY + descent)
                CTLineDraw(line, ctx)
            }
            ctx.restoreGState()
        }

        return ctx.makeImage() ?? image
    }

    private static func badgeColor(for elem: UIElement) -> CGColor {
        switch elem.role {
        case "button", "close_button", "minimize_button", "zoom_button":
            return CGColor(red: 0.09, green: 0.45, blue: 0.95, alpha: 0.95)
        case "textfield":
            return CGColor(red: 0.08, green: 0.62, blue: 0.36, alpha: 0.95)
        case "icon_button":
            return CGColor(red: 0.56, green: 0.27, blue: 0.88, alpha: 0.95)
        case "text_button", "link", "menuitem", "tab":
            return CGColor(red: 0.90, green: 0.42, blue: 0.08, alpha: 0.95)
        default:
            return elem.isInteractive
                ? CGColor(red: 0.82, green: 0.16, blue: 0.34, alpha: 0.95)
                : CGColor(red: 0.38, green: 0.42, blue: 0.48, alpha: 0.85)
        }
    }
}
