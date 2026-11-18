import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import os

public enum CaptureTargetScope: Sendable {
    case frontmostWindow
    case window(id: UInt32)
    case app(name: String?, bundleID: String?, pid: Int32?)
    case display(id: UInt32?)
    case region(ScreenRect)
}

public enum CaptureImageFormat: String, Codable, Sendable {
    case jpeg
    case png

    public var mimeType: String {
        switch self {
        case .jpeg: return "image/jpeg"
        case .png: return "image/png"
        }
    }

    public var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }
}

public struct CapturedScreen: @unchecked Sendable {
    public let image: CGImage
    public let transform: CaptureTransform
    public let window: WindowInfo?
    public let display: DisplayInfo?
    public let scopeDescription: String
}

/// Captures crisp Retina images via `ScreenCaptureKit` (`SCScreenshotManager`) and encodes/resizes via `CoreGraphics` + `ImageIO`.
public enum ScreenCapturer {
    public static func capture(
        target: CaptureTargetScope,
        maxCaptureDimension: Int = 2400,
        showCursor: Bool = false
    ) async throws -> CapturedScreen {
        guard PermissionsManager.currentStatus().screenRecording else {
            throw MacOSUseError.permissionDenied(
                "Screen Recording permission is required. Grant Screen Recording access in System Settings > Privacy & Security."
            )
        }

        let displays = try await WindowManager.listDisplays()
        guard let mainDisplay = displays.first(where: { $0.isMain }) ?? displays.first else {
            throw MacOSUseError.captureFailed("No active displays found.")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        switch target {
        case .display(let id):
            let targetID = id ?? mainDisplay.displayID
            guard let scDisplay = content.displays.first(where: { $0.displayID == targetID })
                ?? content.displays.first(where: { $0.displayID == mainDisplay.displayID })
                ?? content.displays.first,
                let dispInfo = displays.first(where: { $0.displayID == scDisplay.displayID }) ?? displays.first
            else {
                throw MacOSUseError.targetNotFound("Display \(targetID) not found.")
            }
            return try await captureDisplay(
                scDisplay: scDisplay,
                displayInfo: dispInfo,
                region: nil,
                maxDimension: maxCaptureDimension,
                showCursor: showCursor
            )

        case .region(let rect):
            guard rect.width >= 2, rect.height >= 2 else {
                throw MacOSUseError.invalidArgument("Region width and height must be >= 2 logical points.")
            }
            let dispInfo = bestDisplay(for: rect, in: displays) ?? mainDisplay
            guard let scDisplay = content.displays.first(where: { $0.displayID == dispInfo.displayID }) else {
                throw MacOSUseError.targetNotFound("Backing display for region not found.")
            }
            return try await captureDisplay(
                scDisplay: scDisplay,
                displayInfo: dispInfo,
                region: rect,
                maxDimension: maxCaptureDimension,
                showCursor: showCursor
            )

        case .window(let wid):
            var windows = try await WindowManager.listWindows(includeSystemLayers: true, onScreenOnly: true)
            var activeContent = content
            if !windows.contains(where: { $0.windowID == wid }) {
                activeContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                windows = try await WindowManager.listWindows(includeSystemLayers: true, onScreenOnly: false)
                if let hiddenWin = windows.first(where: { $0.windowID == wid }) {
                    _ = await WindowManager.unhideAppIfHidden(pid: hiddenWin.ownerPID)
                    _ = AXInspector.unminimizeWindowsIfNeeded(pid: hiddenWin.ownerPID)
                    activeContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    windows = try await WindowManager.listWindows(includeSystemLayers: true, onScreenOnly: false)
                }
            }
            guard let winInfo = windows.first(where: { $0.windowID == wid }),
                  let scWin = activeContent.windows.first(where: { $0.windowID == wid })
            else {
                throw MacOSUseError.targetNotFound("Window \(wid) not found.")
            }
            let dispInfo = bestDisplay(for: winInfo.frame, in: displays) ?? mainDisplay
            return try await captureWindow(
                scWindow: scWin,
                windowInfo: winInfo,
                displayInfo: dispInfo,
                maxDimension: maxCaptureDimension,
                showCursor: showCursor
            )

        case .app(let name, let bundleID, let pid):
            let matchPredicate: (WindowInfo) -> Bool = { win in
                if let pid, win.ownerPID != pid { return false }
                if let bundleID, !bundleID.isEmpty,
                   (win.bundleID?.localizedCaseInsensitiveContains(bundleID) ?? false)
                {
                    return true
                }
                if let name, !name.isEmpty {
                    let q = name.lowercased()
                    if win.appName.lowercased().contains(q)
                        || (win.bundleID?.lowercased().contains(q) ?? false)
                        || win.title.lowercased().contains(q)
                    {
                        return true
                    }
                }
                return pid != nil && win.ownerPID == pid
            }

            var windows = try await WindowManager.listWindows(includeSystemLayers: false, onScreenOnly: true)
            var activeContent = content
            var matched = windows.first(where: matchPredicate)

            if matched == nil {
                // Retry with off-screen/hidden/minimized windows and unhide/unminimize without foreground activation
                if let running = await WindowManager.findRunningApp(pid: pid, appName: name, bundleID: bundleID) {
                    let unhid = await WindowManager.unhideAppIfHidden(pid: running.processIdentifier)
                    let unminimized = AXInspector.unminimizeWindowsIfNeeded(pid: running.processIdentifier)
                    if unhid || unminimized {
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                }
                activeContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                windows = try await WindowManager.listWindows(includeSystemLayers: false, onScreenOnly: false)
                matched = windows.first(where: matchPredicate)
            }

            guard let winInfo = matched,
                  let scWin = activeContent.windows.first(where: { $0.windowID == winInfo.windowID })
            else {
                let desc = bundleID ?? name ?? pid.map(String.init) ?? "<unspecified>"
                throw MacOSUseError.targetNotFound("No window found for app '\(desc)'.")
            }
            let dispInfo = bestDisplay(for: winInfo.frame, in: displays) ?? mainDisplay
            return try await captureWindow(
                scWindow: scWin,
                windowInfo: winInfo,
                displayInfo: dispInfo,
                maxDimension: maxCaptureDimension,
                showCursor: showCursor
            )

        case .frontmostWindow:
            let windows = try await WindowManager.listWindows(includeSystemLayers: false, onScreenOnly: true)
            if let frontWin = windows.first(where: { $0.isFrontmostApp }) ?? windows.first,
               let scWin = content.windows.first(where: { $0.windowID == frontWin.windowID })
            {
                let dispInfo = bestDisplay(for: frontWin.frame, in: displays) ?? mainDisplay
                return try await captureWindow(
                    scWindow: scWin,
                    windowInfo: frontWin,
                    displayInfo: dispInfo,
                    maxDimension: maxCaptureDimension,
                    showCursor: showCursor
                )
            }
            guard let scDisplay = content.displays.first(where: { $0.displayID == mainDisplay.displayID })
                ?? content.displays.first
            else {
                throw MacOSUseError.captureFailed("No window or display available to capture.")
            }
            return try await captureDisplay(
                scDisplay: scDisplay,
                displayInfo: mainDisplay,
                region: nil,
                maxDimension: maxCaptureDimension,
                showCursor: showCursor
            )
        }
    }

    private static func captureWindow(
        scWindow: SCWindow,
        windowInfo: WindowInfo,
        displayInfo: DisplayInfo,
        maxDimension: Int,
        showCursor: Bool
    ) async throws -> CapturedScreen {
        // Check if this process currently has an active overlay/popup/sheet (layer > 0) extending outside window bounds
        if let overlays = try? await WindowManager.listOverlayWindows(forPID: windowInfo.ownerPID) {
            let ownOverlays = overlays.filter { $0.ownerPID == windowInfo.ownerPID && $0.layer > 0 && $0.layer < 500 }
            if !ownOverlays.isEmpty {
                var unionFrame = windowInfo.frame
                var extendsOutside = false
                for ov in ownOverlays {
                    // Only merge overlays overlapping or near the target window on the same display
                    if ov.frame.intersection(with: displayInfo.frame) != nil
                        && ov.frame.intersection(with: windowInfo.frame.padded(by: 80.0)) != nil
                    {
                        let nextUnion = unionFrame.union(with: ov.frame)
                        if nextUnion.area > unionFrame.area * 1.01 {
                            extendsOutside = true
                            unionFrame = nextUnion
                        }
                    }
                }
                if extendsOutside,
                   let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                   let scDisplay = content.displays.first(where: { $0.displayID == displayInfo.displayID })
                {
                    let regionCapture = try await captureDisplay(
                        scDisplay: scDisplay,
                        displayInfo: displayInfo,
                        region: unionFrame,
                        maxDimension: maxDimension,
                        showCursor: showCursor
                    )
                    let titleSuffix = windowInfo.title.isEmpty ? "" : " - \"\(windowInfo.title)\""
                    return CapturedScreen(
                        image: regionCapture.image,
                        transform: regionCapture.transform,
                        window: windowInfo,
                        display: displayInfo,
                        scopeDescription: "window \(windowInfo.windowID) + overlay (\(windowInfo.appName)\(titleSuffix))"
                    )
                }
            }
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let logicalW = max(1.0, windowInfo.frame.width)
        let logicalH = max(1.0, windowInfo.frame.height)
        let (pixelW, pixelH) = scaledDimensions(
            logicalWidth: logicalW,
            logicalHeight: logicalH,
            scale: displayInfo.scaleFactor,
            maxDimension: maxDimension
        )

        let cfg = SCStreamConfiguration()
        cfg.width = pixelW
        cfg.height = pixelH
        cfg.showsCursor = showCursor
        cfg.scalesToFit = true

        let image = try await captureImageResilient(
            filter: filter,
            configuration: cfg,
            windowID: windowInfo.windowID,
            fallbackGlobalRect: windowInfo.frame,
            maxDimension: maxDimension
        )
        let transform = CaptureTransform(
            originX: windowInfo.frame.x,
            originY: windowInfo.frame.y,
            logicalWidth: logicalW,
            logicalHeight: logicalH,
            imageWidth: image.width,
            imageHeight: image.height
        )
        let titleSuffix = windowInfo.title.isEmpty ? "" : " - \"\(windowInfo.title)\""
        return CapturedScreen(
            image: image,
            transform: transform,
            window: windowInfo,
            display: displayInfo,
            scopeDescription: "window \(windowInfo.windowID) (\(windowInfo.appName)\(titleSuffix))"
        )
    }

    private static func captureDisplay(
        scDisplay: SCDisplay,
        displayInfo: DisplayInfo,
        region: ScreenRect?,
        maxDimension: Int,
        showCursor: Bool
    ) async throws -> CapturedScreen {
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = showCursor
        cfg.scalesToFit = true

        let targetBounds: ScreenRect
        if let region {
            let clamped = region.intersection(with: displayInfo.frame) ?? region
            targetBounds = clamped
            cfg.sourceRect = CGRect(
                x: clamped.x - displayInfo.frame.x,
                y: clamped.y - displayInfo.frame.y,
                width: clamped.width,
                height: clamped.height
            )
        } else {
            targetBounds = displayInfo.frame
        }

        let (pixelW, pixelH) = scaledDimensions(
            logicalWidth: targetBounds.width,
            logicalHeight: targetBounds.height,
            scale: displayInfo.scaleFactor,
            maxDimension: maxDimension
        )
        cfg.width = pixelW
        cfg.height = pixelH

        let image = try await captureImageResilient(
            filter: filter,
            configuration: cfg,
            windowID: nil,
            fallbackGlobalRect: targetBounds,
            maxDimension: maxDimension
        )
        let transform = CaptureTransform(
            originX: targetBounds.x,
            originY: targetBounds.y,
            logicalWidth: targetBounds.width,
            logicalHeight: targetBounds.height,
            imageWidth: image.width,
            imageHeight: image.height
        )
        let desc = region == nil
            ? "display \(displayInfo.displayID) (\(Int(targetBounds.width))x\(Int(targetBounds.height))pt)"
            : "region (\(Int(targetBounds.x)),\(Int(targetBounds.y)) \(Int(targetBounds.width))x\(Int(targetBounds.height))pt)"
        return CapturedScreen(
            image: image,
            transform: transform,
            window: nil,
            display: displayInfo,
            scopeDescription: desc
        )
    }

    private static func bestDisplay(for rect: ScreenRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        let center = rect.center
        if let containing = displays.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        return displays.max { lhs, rhs in
            let la = lhs.frame.intersection(with: rect)?.area ?? 0
            let ra = rhs.frame.intersection(with: rect)?.area ?? 0
            return la < ra
        }
    }

    private static func scaledDimensions(
        logicalWidth: Double,
        logicalHeight: Double,
        scale: Double,
        maxDimension: Int
    ) -> (Int, Int) {
        let rawW = max(1.0, logicalWidth * max(1.0, scale))
        let rawH = max(1.0, logicalHeight * max(1.0, scale))
        let cap = Double(max(64, maxDimension))
        let longest = max(rawW, rawH)
        let ratio = longest > cap ? (cap / longest) : 1.0
        return (max(1, Int((rawW * ratio).rounded())), max(1, Int((rawH * ratio).rounded())))
    }

    // MARK: - Image Resizing & Encoding

    public static func resizeIfNeeded(_ image: CGImage, maxDimension: Int) -> CGImage {
        let maxSide = max(image.width, image.height)
        guard maxDimension > 0, maxSide > maxDimension else {
            return image
        }
        let ratio = Double(maxDimension) / Double(maxSide)
        let targetW = max(1, Int((Double(image.width) * ratio).rounded()))
        let targetH = max(1, Int((Double(image.height) * ratio).rounded()))

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? image
    }

    public static func encodeImage(
        _ image: CGImage,
        format: CaptureImageFormat,
        jpegQuality: Double = 0.80
    ) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw MacOSUseError.captureFailed("Failed to initialize ImageIO destination for \(format.rawValue).")
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(jpegQuality, 0.1), 1.0)
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw MacOSUseError.captureFailed("Failed to finalize \(format.rawValue) image encoding.")
        }
        return data as Data
    }

    // MARK: - Timeout-Guarded Capture & Native Fallbacks

    private final class OnceGate: Sendable {
        private let claimed = OSAllocatedUnfairLock<Bool>(initialState: false)
        func claim() -> Bool {
            claimed.withLock { flag in
                if flag { return false }
                flag = true
                return true
            }
        }
    }

    private static let scStreamCooldownUntil = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    private static func captureImageResilient(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        windowID: UInt32?,
        fallbackGlobalRect: ScreenRect,
        maxDimension: Int
    ) async throws -> CGImage {
        let inCooldown = scStreamCooldownUntil.withLock { until in
            if let until, ContinuousClock.now < until { return true }
            return false
        }

        if !inCooldown {
            if let img = try? await captureWithTimeout(ms: 900, invoke: { finish in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    finish(image, error)
                }
            }) {
                return img
            }
            scStreamCooldownUntil.withLock { $0 = ContinuousClock.now + .seconds(30) }
        }

        // Tier 2A: Native /usr/sbin/screencapture window capture (preserves occluded/background window fidelity)
        if let windowID,
           let winImage = runNativeScreencapture(arguments: ["-x", "-o", "-t", "png", "-l", "\(windowID)"])
        {
            return resizeIfNeeded(winImage, maxDimension: maxDimension)
        }

        // Tier 2B: SCScreenshotManager.captureImage(in:) rect proxy (bypasses SCStream)
        if fallbackGlobalRect.width >= 2, fallbackGlobalRect.height >= 2 {
            let rect = fallbackGlobalRect.cgRect
            if let rectImage = try? await captureWithTimeout(ms: 700, invoke: { finish in
                SCScreenshotManager.captureImage(in: rect) { image, error in
                    finish(image, error)
                }
            }) {
                return resizeIfNeeded(rectImage, maxDimension: maxDimension)
            }
        }

        // Tier 2C: Native /usr/sbin/screencapture region capture
        let rx = Int(fallbackGlobalRect.x.rounded())
        let ry = Int(fallbackGlobalRect.y.rounded())
        let rw = max(1, Int(fallbackGlobalRect.width.rounded()))
        let rh = max(1, Int(fallbackGlobalRect.height.rounded()))
        if let regionImg = runNativeScreencapture(arguments: ["-x", "-t", "png", "-R", "\(rx),\(ry),\(rw),\(rh)"]) {
            return resizeIfNeeded(regionImg, maxDimension: maxDimension)
        }

        throw MacOSUseError.captureFailed("ScreenCaptureKit stream interrupted and native screencapture fallback failed.")
    }

    private static func captureWithTimeout(
        ms: Int,
        invoke: (@escaping @Sendable (CGImage?, (any Error)?) -> Void) -> Void
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGate()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(ms)) {
                if gate.claim() {
                    continuation.resume(throwing: MacOSUseError.timeout("SCScreenshotManager timed out after \(ms)ms."))
                }
            }
            invoke { image, error in
                guard gate.claim() else { return }
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? MacOSUseError.captureFailed("SCScreenshotManager returned nil image."))
                }
            }
        }
    }

    private static func runNativeScreencapture(arguments: [String]) -> CGImage? {
        let tmpPath = "/tmp/macos-use-cap-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = arguments + [tmpPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tmpPath),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmpPath) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            return nil
        }
        return img
    }
}
