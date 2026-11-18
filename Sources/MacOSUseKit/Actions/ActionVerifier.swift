@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

public struct PreActionSnapshot: Sendable {
    public let pid: Int32?
    public let windowID: UInt32?
    public let point: ScreenPoint?
    public let windowIDs: Set<UInt32>
    public let focusedSig: String?
    public let elementSig: String?
    public let patchRect: ScreenRect?
    public let patchPixels: [UInt8]?
    public let windowPixels: [UInt8]?
    public let timestamp: ContinuousClock.Instant
}

/// Captures pre/post Accessibility, window-topology, and ScreenCaptureKit pixel state to verify action impact.
public enum ActionVerifier {
    public static func capturePreState(
        pid: Int32?,
        point: CGPoint?,
        element: StoredElement?,
        windowID: UInt32? = nil,
        captureVisual: Bool = true
    ) async -> PreActionSnapshot {
        let resolvedWID = windowID ?? element?.ui.windowID
        let winIDs = queryWindowIDs(forPID: pid)
        let focusedSig = pid.flatMap { AXInspector.focusedElementSignature(pid: $0) }
        let elementSig = element?.axRef.flatMap { AXInspector.elementStateSignature($0) }

        let patchRect = buildPatchRect(point: point, element: element)
        var patchPixels: [UInt8]?
        var windowPixels: [UInt8]?
        if captureVisual {
            let captured = await captureVisualPair(pid: pid, windowID: resolvedWID, patchRect: patchRect)
            patchPixels = captured.patch
            windowPixels = captured.window
        }

        return PreActionSnapshot(
            pid: pid,
            windowID: resolvedWID,
            point: point.map { ScreenPoint(x: $0.x, y: $0.y) },
            windowIDs: winIDs,
            focusedSig: focusedSig,
            elementSig: elementSig,
            patchRect: patchRect,
            patchPixels: patchPixels,
            windowPixels: windowPixels,
            timestamp: .now
        )
    }

    public static func verifyPostState(
        before: PreActionSnapshot,
        element: StoredElement?,
        attempts: [String],
        settleMs: Int = 160
    ) async -> ActionVerification {
        let start = ContinuousClock.now
        let settle = await UIEventObserver.waitForSettle(
            pid: before.pid,
            windowID: before.windowID,
            region: nil,
            maxWaitMs: max(60, min(settleMs, 2000)),
            quietWindowMs: 55,
            checkVisual: false
        )

        var signals: [String] = []
        let afterWindowIDs = queryWindowIDs(forPID: before.pid)
        if !afterWindowIDs.subtracting(before.windowIDs).isEmpty {
            signals.append("window_opened")
        }
        if !before.windowIDs.subtracting(afterWindowIDs).isEmpty {
            signals.append("window_closed")
        }

        for notif in settle.axNotifications.prefix(4) {
            signals.append("ax:\(notif)")
        }

        if let beforeElSig = before.elementSig, let axRef = element?.axRef {
            let afterElSig = AXInspector.elementStateSignature(axRef)
            if afterElSig == nil {
                signals.append("element_destroyed_or_navigated")
            } else if afterElSig != beforeElSig {
                signals.append("element_state_changed")
            }
        }

        if let pid = before.pid {
            let afterFocus = AXInspector.focusedElementSignature(pid: pid)
            if afterFocus != before.focusedSig {
                signals.append("focus_changed")
            }
        }

        var maxDelta = 0.0
        if before.patchPixels != nil || before.windowPixels != nil {
            let afterVisual = await captureVisualPair(
                pid: before.pid,
                windowID: before.windowID,
                patchRect: before.patchRect
            )
            let patchDelta = UIEventObserver.pixelDelta(before.patchPixels, afterVisual.patch)
            let winDelta = UIEventObserver.pixelDelta(before.windowPixels, afterVisual.window)
            maxDelta = max(patchDelta, winDelta)
            if patchDelta >= 0.015 {
                signals.append("visual_patch_changed")
            } else if winDelta >= 0.010 {
                signals.append("visual_window_changed")
            }
        }

        let elapsed = durationMs(from: start, to: .now)
        let uiChanged = !signals.isEmpty
        return ActionVerification(
            verified: uiChanged,
            uiChanged: uiChanged,
            escalated: attempts.count > 1,
            attempts: attempts,
            signals: signals,
            visualDelta: (maxDelta * 10000.0).rounded() / 10000.0,
            elapsedMs: elapsed
        )
    }

    private static func queryWindowIDs(forPID pid: Int32?) -> Set<UInt32> {
        guard let pid else { return [] }
        let rawList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var ids = Set<UInt32>()
        for dict in rawList {
            guard let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber,
                  pidNum.int32Value == pid,
                  let num = dict[kCGWindowNumber as String] as? NSNumber
            else { continue }
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer < 0 || layer > 2000 { continue }
            if let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               rect.width >= 20, rect.height >= 16
            {
                ids.insert(num.uint32Value)
            }
        }
        return ids
    }

    private static func buildPatchRect(point: CGPoint?, element: StoredElement?) -> ScreenRect? {
        if let elemFrame = element?.ui.frame, elemFrame.width >= 8, elemFrame.height >= 8 {
            return elemFrame.padded(by: 12.0)
        }
        guard let point else { return nil }
        return ScreenRect(x: point.x - 48.0, y: point.y - 48.0, width: 96.0, height: 96.0)
    }

    private static func captureVisualPair(
        pid: Int32?,
        windowID: UInt32?,
        patchRect: ScreenRect?
    ) async -> (patch: [UInt8]?, window: [UInt8]?) {
        guard PermissionsManager.currentStatus().screenRecording else {
            return (nil, nil)
        }
        let target: CaptureTargetScope?
        if let windowID {
            target = .window(id: windowID)
        } else if let pid {
            target = .app(name: nil, bundleID: nil, pid: pid)
        } else if let patchRect {
            target = .region(patchRect)
        } else {
            target = nil
        }

        guard let target,
              let captured = try? await ScreenCapturer.capture(
                  target: target,
                  maxCaptureDimension: 900,
                  showCursor: false
              )
        else {
            return (nil, nil)
        }

        let winSig = UIEventObserver.computeGrayscaleSignature(image: captured.image, gridSize: 32)
        var patchSig: [UInt8]?

        if let patchRect,
           let clamped = patchRect.intersection(with: captured.transform.logicalBounds),
           clamped.width >= 6, clamped.height >= 6
        {
            let cropRect = captured.transform.globalToImageTopLeft(clamped).integral
            let boundedCrop = cropRect.intersection(
                CGRect(x: 0, y: 0, width: captured.image.width, height: captured.image.height)
            )
            if boundedCrop.width >= 4, boundedCrop.height >= 4,
               let croppedImg = captured.image.cropping(to: boundedCrop)
            {
                patchSig = UIEventObserver.computeGrayscaleSignature(image: croppedImg, gridSize: 32)
            }
        }
        return (patchSig, winSig)
    }

    private static func durationMs(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: end)
        let ms = Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1e15
        return max(0, Int(ms.rounded()))
    }
}
