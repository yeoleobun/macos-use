@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

public struct ObserveResult: @unchecked Sendable {
    public let snapshot: UISnapshot
    public let image: CGImage?
    public let encodedImageData: Data?
    public let imageFormat: CaptureImageFormat
    public let axCount: Int
    public let visionCount: Int
}

/// Coordinates capture, AX inspection, Vision grounding, fusion, SoM rendering, and snapshot storage.
public enum PerceptionEngine {
    public static func observe(
        target: CaptureTargetScope,
        includeImage: Bool = true,
        annotate: Bool = true,
        includeVision: Bool = true,
        detectContours: Bool = true,
        classifyIcons: Bool = true,
        includePopups: Bool = true,
        maxElements: Int = 160,
        maxDimension: Int = 1600,
        imageFormat: CaptureImageFormat = .jpeg,
        jpegQuality: Double = 0.80,
        showCursor: Bool = false
    ) async throws -> ObserveResult {
        let internalMaxDim = (includeVision || classifyIcons) ? max(maxDimension, 2200) : maxDimension
        let captured = try await ScreenCapturer.capture(
            target: target,
            maxCaptureDimension: internalMaxDim,
            showCursor: showCursor
        )

        let axTrusted = AXIsProcessTrusted()
        let axOptions = AXInspector.InspectionOptions(includePopups: includePopups)
        let axElements = axTrusted
            ? AXInspector.inspectWindow(window: captured.window, bounds: captured.transform.logicalBounds, options: axOptions)
            : []

        let visionElements: [StoredElement]
        if includeVision {
            visionElements = try await VisionInspector.inspect(
                image: captured.image,
                transform: captured.transform,
                window: captured.window,
                axTrusted: axTrusted,
                options: VisionInspector.VisionOptions(detectContours: detectContours)
            )
        } else {
            visionElements = []
        }

        var fused = UIFusionEngine.fuse(
            axElements: axElements,
            visionElements: visionElements,
            maxElements: max(10, min(maxElements, 400))
        )

        if classifyIcons {
            fused = await IconClassifier.shared.classifyIcons(
                elements: fused,
                image: captured.image,
                transform: captured.transform
            )
        }

        let outputBaseImage = ScreenCapturer.resizeIfNeeded(captured.image, maxDimension: maxDimension)
        let outputTransform = CaptureTransform(
            originX: captured.transform.originX,
            originY: captured.transform.originY,
            logicalWidth: captured.transform.logicalWidth,
            logicalHeight: captured.transform.logicalHeight,
            imageWidth: outputBaseImage.width,
            imageHeight: outputBaseImage.height
        )

        let snapshot = await SnapshotStore.shared.save(
            scopeDescription: captured.scopeDescription,
            ownerPID: captured.window?.ownerPID,
            windowID: captured.window?.windowID,
            transform: outputTransform,
            axTrusted: axTrusted,
            elements: fused
        )

        guard includeImage else {
            return ObserveResult(
                snapshot: snapshot,
                image: nil,
                encodedImageData: nil,
                imageFormat: imageFormat,
                axCount: axElements.count,
                visionCount: visionElements.count
            )
        }

        let finalImage = annotate
            ? SoMAnnotator.annotate(
                image: outputBaseImage,
                transform: outputTransform,
                elements: fused.map(\.ui)
            )
            : outputBaseImage
        let encoded = try ScreenCapturer.encodeImage(finalImage, format: imageFormat, jpegQuality: jpegQuality)

        return ObserveResult(
            snapshot: snapshot,
            image: finalImage,
            encodedImageData: encoded,
            imageFormat: imageFormat,
            axCount: axElements.count,
            visionCount: visionElements.count
        )
    }

    public static func resolveTargetScope(
        scope: String?,
        windowID: UInt32?,
        appName: String?,
        bundleID: String?,
        displayID: UInt32?,
        region: ScreenRect?
    ) throws -> CaptureTargetScope {
        if let region {
            return .region(region)
        }
        if let windowID {
            return .window(id: windowID)
        }
        if let bundleID, !bundleID.isEmpty {
            return .app(name: appName, bundleID: bundleID, pid: nil)
        }
        if let appName, !appName.isEmpty {
            return .app(name: appName, bundleID: nil, pid: nil)
        }
        if let displayID {
            return .display(id: displayID)
        }
        switch (scope ?? "frontmost_window").lowercased() {
        case "display", "screen", "full", "fullscreen":
            return .display(id: nil)
        case "frontmost", "frontmost_window", "window", "":
            return .frontmostWindow
        default:
            throw MacOSUseError.invalidArgument(
                "Unknown target scope '\(scope ?? "")'. Expected frontmost_window, window, app, display, or region."
            )
        }
    }
}
