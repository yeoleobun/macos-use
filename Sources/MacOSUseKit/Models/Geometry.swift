#if !arch(arm64) || !os(macOS)
#error("macos-use requires Apple Silicon (arm64) on latest macOS")
#endif

import CoreGraphics
import Foundation
import Vision

/// A 2D point in Global Quartz Logical Points (`(0, 0)` at top-left of main display).
public struct ScreenPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// A rectangle in Global Quartz Logical Points (`(0, 0)` at top-left of main display, `+X` right, `+Y` down).
public struct ScreenRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public init(cgRect: CGRect) {
        self.x = cgRect.origin.x
        self.y = cgRect.origin.y
        self.width = max(0, cgRect.size.width)
        self.height = max(0, cgRect.size.height)
    }

    public var centerX: Double { x + width / 2.0 }
    public var centerY: Double { y + height / 2.0 }
    public var center: ScreenPoint { ScreenPoint(x: centerX, y: centerY) }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }

    public func contains(_ point: ScreenPoint) -> Bool {
        contains(x: point.x, y: point.y)
    }

    public func intersection(with other: ScreenRect) -> ScreenRect? {
        let ix = max(x, other.x)
        let iy = max(y, other.y)
        let imaxX = min(maxX, other.maxX)
        let imaxY = min(maxY, other.maxY)
        let iw = imaxX - ix
        let ih = imaxY - iy
        guard iw > 0, ih > 0 else { return nil }
        return ScreenRect(x: ix, y: iy, width: iw, height: ih)
    }

    public func iou(with other: ScreenRect) -> Double {
        guard let inter = intersection(with: other) else { return 0.0 }
        let unionArea = area + other.area - inter.area
        guard unionArea > 0 else { return 0.0 }
        return inter.area / unionArea
    }

    public func padded(by delta: Double) -> ScreenRect {
        ScreenRect(
            x: x - delta,
            y: y - delta,
            width: max(0, width + delta * 2.0),
            height: max(0, height + delta * 2.0)
        )
    }

    public func union(with other: ScreenRect) -> ScreenRect {
        let ux = min(x, other.x)
        let uy = min(y, other.y)
        let umaxX = max(maxX, other.maxX)
        let umaxY = max(maxY, other.maxY)
        return ScreenRect(x: ux, y: uy, width: umaxX - ux, height: umaxY - uy)
    }
}

/// Maps between a captured `CGImage`'s pixel space, Vision normalized coordinates, and Global Quartz Logical Points.
public struct CaptureTransform: Codable, Sendable, Equatable {
    public var originX: Double
    public var originY: Double
    public var logicalWidth: Double
    public var logicalHeight: Double
    public var imageWidth: Int
    public var imageHeight: Int

    public init(
        originX: Double,
        originY: Double,
        logicalWidth: Double,
        logicalHeight: Double,
        imageWidth: Int,
        imageHeight: Int
    ) {
        self.originX = originX
        self.originY = originY
        self.logicalWidth = max(1, logicalWidth)
        self.logicalHeight = max(1, logicalHeight)
        self.imageWidth = max(1, imageWidth)
        self.imageHeight = max(1, imageHeight)
    }

    public var logicalBounds: ScreenRect {
        ScreenRect(x: originX, y: originY, width: logicalWidth, height: logicalHeight)
    }

    public var scaleX: Double {
        Double(imageWidth) / logicalWidth
    }

    public var scaleY: Double {
        Double(imageHeight) / logicalHeight
    }

    /// Converts image-space top-left pixel coordinates `(x, y)` to Global Quartz Logical Points.
    public func imagePixelToGlobal(x: Double, y: Double) -> CGPoint {
        let gx = originX + (x / Double(imageWidth)) * logicalWidth
        let gy = originY + (y / Double(imageHeight)) * logicalHeight
        return CGPoint(x: gx, y: gy)
    }

    /// Converts a Global Quartz Logical `ScreenRect` into top-left-origin image pixel coordinates.
    public func globalToImageTopLeft(_ rect: ScreenRect) -> CGRect {
        let ix = ((rect.x - originX) / logicalWidth) * Double(imageWidth)
        let iy = ((rect.y - originY) / logicalHeight) * Double(imageHeight)
        let iw = (rect.width / logicalWidth) * Double(imageWidth)
        let ih = (rect.height / logicalHeight) * Double(imageHeight)
        return CGRect(x: ix, y: iy, width: iw, height: ih)
    }

    /// Converts a Vision `NormalizedRect` (bottom-left normalized `[0, 1]`) into Global Quartz Logical Points.
    public func visionNormalizedToGlobal(_ norm: NormalizedRect) -> ScreenRect {
        let localRect = norm.toImageCoordinates(
            CGSize(width: logicalWidth, height: logicalHeight),
            origin: .upperLeft
        )
        return ScreenRect(
            x: originX + localRect.origin.x,
            y: originY + localRect.origin.y,
            width: localRect.size.width,
            height: localRect.size.height
        )
    }
}
