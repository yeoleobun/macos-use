@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

private final class AXNotificationCollector: Sendable {
    struct State: Sendable {
        var count: Int = 0
        var lastTime: ContinuousClock.Instant?
        var names: [String] = []
    }

    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func record(_ name: String) {
        lock.withLock { state in
            state.count += 1
            state.lastTime = .now
            if !state.names.contains(name) && state.names.count < 24 {
                state.names.append(name)
            }
        }
    }

    func snapshot() -> State {
        lock.withLock { $0 }
    }
}

@MainActor
private final class AXObserverHandle {
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?
    let collector: AXNotificationCollector

    init?(pid: Int32) {
        let collector = AXNotificationCollector()
        self.collector = collector
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let col = Unmanaged<AXNotificationCollector>.fromOpaque(refcon).takeUnretainedValue()
            col.record(notification as String)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else {
            return nil
        }
        self.observer = obs
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(collector).toOpaque()
        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXValueChangedNotification,
            kAXTitleChangedNotification,
            kAXLayoutChangedNotification,
            "AXMenuOpened",
            "AXMenuClosed",
            kAXSheetCreatedNotification
        ]
        for notif in notifications {
            _ = AXObserverAddNotification(obs, appElement, notif as CFString, refcon)
        }
        let src = AXObserverGetRunLoopSource(obs)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    func invalidate() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        observer = nil
    }
}

/// Observes live `AXObserver` UI mutations and frame-diff stability to detect when the UI has settled.
public enum UIEventObserver {
    public static func computeGrayscaleSignature(image: CGImage, gridSize: Int = 48) -> [UInt8] {
        let side = max(8, min(gridSize, 128))
        var pixels = [UInt8](repeating: 0, count: side * side)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return []
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    public static func capturePatchSignature(
        rect: ScreenRect? = nil,
        windowID: UInt32? = nil,
        pid: Int32? = nil,
        gridSize: Int = 48
    ) async -> [UInt8]? {
        guard PermissionsManager.currentStatus().screenRecording else {
            return nil
        }
        let target: CaptureTargetScope
        if let rect, rect.width >= 2, rect.height >= 2 {
            target = .region(rect)
        } else if let windowID {
            target = .window(id: windowID)
        } else if let pid {
            target = .app(name: nil, bundleID: nil, pid: pid)
        } else {
            return nil
        }

        guard let captured = try? await ScreenCapturer.capture(
            target: target,
            maxCaptureDimension: 256,
            showCursor: false
        ) else {
            return nil
        }
        return computeGrayscaleSignature(image: captured.image, gridSize: gridSize)
    }

    public static func pixelDelta(_ a: [UInt8]?, _ b: [UInt8]?) -> Double {
        guard let a, let b, !a.isEmpty, a.count == b.count else {
            return 0.0
        }
        var sumDiff = 0
        for i in 0..<a.count {
            sumDiff += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sumDiff) / (Double(a.count) * 255.0)
    }

    public static func waitForSettle(
        pid: Int32?,
        windowID: UInt32? = nil,
        region: ScreenRect? = nil,
        maxWaitMs: Int = 450,
        quietWindowMs: Int = 85,
        checkVisual: Bool = true
    ) async -> SettleResult {
        let clampedMax = max(40, min(maxWaitMs, 15000))
        let clampedQuiet = max(30, min(quietWindowMs, 2000))
        let start = ContinuousClock.now
        let deadline = start + .milliseconds(clampedMax)

        let axHandle: AXObserverHandle? = await MainActor.run {
            guard AXIsProcessTrusted(), let pid else { return nil }
            return AXObserverHandle(pid: pid)
        }
        let collector = axHandle?.collector

        var previousSig: [UInt8]? = checkVisual
            ? await capturePatchSignature(rect: region, windowID: windowID, pid: pid)
            : nil
        var lastVisualDelta = 0.0
        var settled = false

        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let elapsed = durationMs(from: start, to: .now)
            let axState = collector?.snapshot()

            let axQuiet: Bool
            if let lastAX = axState?.lastTime {
                axQuiet = durationMs(from: lastAX, to: .now) >= clampedQuiet
            } else {
                axQuiet = elapsed >= min(60, clampedMax)
            }

            if elapsed >= min(60, clampedMax) && axQuiet {
                if checkVisual {
                    let currentSig = await capturePatchSignature(rect: region, windowID: windowID, pid: pid)
                    if let prev = previousSig, let curr = currentSig {
                        let delta = pixelDelta(prev, curr)
                        lastVisualDelta = delta
                        previousSig = curr
                        if delta < 0.008 {
                            settled = true
                            break
                        }
                    } else {
                        settled = true
                        break
                    }
                } else {
                    settled = true
                    break
                }
            } else if checkVisual, let currentSig = await capturePatchSignature(rect: region, windowID: windowID, pid: pid) {
                lastVisualDelta = pixelDelta(previousSig, currentSig)
                previousSig = currentSig
            }
        }

        let finalState = collector?.snapshot()
        let finalElapsed = durationMs(from: start, to: .now)
        if let axHandle {
            await MainActor.run {
                axHandle.invalidate()
            }
        }
        return withExtendedLifetime(collector) {
            SettleResult(
                settled: settled,
                elapsedMs: finalElapsed,
                axNotifications: finalState?.names ?? [],
                visualDeltaScore: (lastVisualDelta * 10000.0).rounded() / 10000.0
            )
        }
    }

    private static func durationMs(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: end)
        let ms = Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1e15
        return max(0, Int(ms.rounded()))
    }
}
