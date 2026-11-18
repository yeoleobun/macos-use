import AppKit
import Carbon
import CoreGraphics
import Foundation

public enum FocusMode: String, Sendable {
    case auto
    case background
    case foreground
    case restore

    public static func resolve(background: Bool?, focusMode: String?) throws -> FocusMode {
        if background == true {
            return .background
        }
        guard let raw = focusMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .auto
        }
        guard let mode = FocusMode(rawValue: raw) else {
            throw MacOSUseError.invalidArgument(
                "Unsupported focus_mode '\(raw)'. Expected auto, background, foreground, or restore."
            )
        }
        return mode
    }
}

public struct ClickOutcome: Sendable {
    public let methodUsed: String
    public let point: ScreenPoint
    public let matchedElement: UIElement?
    public let focusMode: FocusMode
    public let verification: ActionVerification?

    public init(
        methodUsed: String,
        point: ScreenPoint,
        matchedElement: UIElement?,
        focusMode: FocusMode,
        verification: ActionVerification? = nil
    ) {
        self.methodUsed = methodUsed
        self.point = point
        self.matchedElement = matchedElement
        self.focusMode = focusMode
        self.verification = verification
    }
}

public struct TypeOutcome: Sendable {
    public let methodUsed: String
    public let verified: Bool
    public let valueMatched: Bool
    public let escalated: Bool
    public let focusMode: FocusMode

    public init(
        methodUsed: String,
        verified: Bool,
        valueMatched: Bool,
        escalated: Bool,
        focusMode: FocusMode
    ) {
        self.methodUsed = methodUsed
        self.verified = verified
        self.valueMatched = valueMatched
        self.escalated = escalated
        self.focusMode = focusMode
    }
}

/// Synthesizes hardware-grade Quartz `CGEvent` mouse/keyboard inputs, background `postToPid`, and native `AXAction` triggers.
public enum InputController {
    private static func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0.0
        return source
    }

    private static func ensurePostAccess() throws {
        guard CGPreflightPostEventAccess() else {
            throw MacOSUseError.permissionDenied(
                "CGEvent post-event access is denied. Enable Accessibility / Input Control in System Settings > Privacy & Security."
            )
        }
    }

    @MainActor
    private static func captureFocusState() -> (pid: Int32?, cursor: CGPoint?) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cursor = CGEvent(source: nil)?.location
        return (pid, cursor)
    }

    @MainActor
    private static func restoreFocusState(_ saved: (pid: Int32?, cursor: CGPoint?)) async {
        if let cursor = saved.cursor, let source = makeSource(),
           let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: cursor, mouseButton: .left)
        {
            ev.post(tap: .cghidEventTap)
        }
        if let pid = saved.pid, let app = NSRunningApplication(processIdentifier: pid) {
            _ = app.activate(options: [.activateAllWindows])
        }
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - Mouse

    public static func moveMouse(to point: CGPoint, smooth: Bool = false) async throws {
        try ensurePostAccess()
        let source = makeSource()

        if smooth {
            let current = CGEvent(source: nil)?.location ?? point
            let steps = 8
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let p = CGPoint(
                    x: current.x + (point.x - current.x) * t,
                    y: current.y + (point.y - current.y) * t
                )
                if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
                    ev.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(for: .milliseconds(12))
            }
        } else {
            if let ev = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                ev.post(tap: .cghidEventTap)
            }
        }
    }

    public static func click(
        point: CGPoint?,
        element: StoredElement?,
        ownerPID: Int32?,
        windowID: UInt32? = nil,
        button: String = "left",
        clickCount: Int = 1,
        modifiers: [String] = [],
        method: String = "auto",
        focusMode: FocusMode = .auto,
        verify: Bool = false,
        settleMs: Int = 160,
        allowFocusFallback: Bool = false
    ) async throws -> ClickOutcome {
        let count = max(1, min(clickCount, 3))
        let btnLower = button.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetPID = ownerPID ?? element?.ui.ownerPID

        let targetPoint: CGPoint
        if let point {
            targetPoint = point
        } else if let element {
            targetPoint = element.ui.frame.center.cgPoint
        } else {
            throw MacOSUseError.invalidArgument("click requires either element_id, query, or (x, y) coordinates.")
        }

        let axEligible = element?.axRef != nil && btnLower == "left" && count == 1 && modifiers.isEmpty

        let preState: PreActionSnapshot? = verify
            ? await ActionVerifier.capturePreState(pid: targetPID, point: targetPoint, element: element, windowID: windowID)
            : nil

        // Background mode: never steal foreground focus or move the physical cursor
        if focusMode == .background || (focusMode == .auto && verify && normMethod == "auto" && targetPID != nil) {
            if (normMethod == "auto" || normMethod == "ax"), axEligible, let axRef = element?.axRef {
                if try AXInspector.pressForClick(axRef) {
                    let v = await preState.asyncMap {
                        await ActionVerifier.verifyPostState(before: $0, element: element, attempts: ["ax_press_background"], settleMs: settleMs)
                    }
                    return ClickOutcome(
                        methodUsed: "ax_press_background",
                        point: ScreenPoint(x: targetPoint.x, y: targetPoint.y),
                        matchedElement: element?.ui,
                        focusMode: focusMode,
                        verification: v
                    )
                }
                if normMethod == "ax" {
                    throw MacOSUseError.inputFailed("AXPress failed for element '\(element?.ui.id ?? "?")'.")
                }
            } else if normMethod == "ax" {
                throw MacOSUseError.invalidArgument("method='ax' requires a live Accessibility element reference.")
            }

            guard let pid = targetPID else {
                throw MacOSUseError.invalidArgument(
                    "Background CGEvent click requires a target app PID (specify app_name, bundle_id, window_id, or element_id)."
                )
            }
            try await sendPostToPidMouseClick(
                pid: pid,
                point: targetPoint,
                button: btnLower,
                clickCount: count,
                modifiers: modifiers
            )
            let methodName = "cgevent_pid_\(btnLower)_x\(count)"
            let v = await preState.asyncMap {
                await ActionVerifier.verifyPostState(before: $0, element: element, attempts: [methodName], settleMs: settleMs)
            }
            return ClickOutcome(
                methodUsed: methodName,
                point: ScreenPoint(x: targetPoint.x, y: targetPoint.y),
                matchedElement: element?.ui,
                focusMode: focusMode,
                verification: v
            )
        }

        // In auto mode with explicit method='ax', press without activating
        if focusMode == .auto && normMethod == "ax" {
            guard axEligible, let axRef = element?.axRef else {
                throw MacOSUseError.invalidArgument("method='ax' requires a live Accessibility element reference.")
            }
            guard try AXInspector.pressForClick(axRef) else {
                throw MacOSUseError.inputFailed("AXPress failed for element '\(element?.ui.id ?? "?")'.")
            }
            let v = await preState.asyncMap {
                await ActionVerifier.verifyPostState(before: $0, element: element, attempts: ["ax_press"], settleMs: settleMs)
            }
            return ClickOutcome(
                methodUsed: "ax_press",
                point: ScreenPoint(x: targetPoint.x, y: targetPoint.y),
                matchedElement: element?.ui,
                focusMode: .auto,
                verification: v
            )
        }

        let savedFocus = (focusMode == .restore) ? await captureFocusState() : (nil, nil)
        try await activateAndRaiseWindow(pid: targetPID, windowID: windowID, element: element)

        if (normMethod == "ax" || normMethod == "auto"), axEligible, let axRef = element?.axRef {
            if try AXInspector.pressForClick(axRef) {
                if focusMode == .restore {
                    try? await Task.sleep(for: .milliseconds(60))
                    await restoreFocusState(savedFocus)
                }
                let v = await preState.asyncMap {
                    await ActionVerifier.verifyPostState(before: $0, element: element, attempts: ["ax_press"], settleMs: settleMs)
                }
                return ClickOutcome(
                    methodUsed: "ax_press",
                    point: ScreenPoint(x: targetPoint.x, y: targetPoint.y),
                    matchedElement: element?.ui,
                    focusMode: focusMode,
                    verification: v
                )
            }
            if normMethod == "ax" {
                if focusMode == .restore {
                    await restoreFocusState(savedFocus)
                }
                throw MacOSUseError.inputFailed("AXPress failed for element '\(element?.ui.id ?? "?")'.")
            }
        } else if normMethod == "ax" {
            if focusMode == .restore {
                await restoreFocusState(savedFocus)
            }
            throw MacOSUseError.invalidArgument("method='ax' requires a live Accessibility element reference (AXIsProcessTrusted must be true).")
        }

        try await sendHardwareMouseClick(
            point: targetPoint,
            button: btnLower,
            clickCount: count,
            modifiers: modifiers
        )

        if focusMode == .restore {
            try? await Task.sleep(for: .milliseconds(60))
            await restoreFocusState(savedFocus)
        }

        let methodName = "cgevent_\(btnLower)_x\(count)"
        let v = await preState.asyncMap {
            await ActionVerifier.verifyPostState(before: $0, element: element, attempts: [methodName], settleMs: settleMs)
        }
        return ClickOutcome(
            methodUsed: methodName,
            point: ScreenPoint(x: targetPoint.x, y: targetPoint.y),
            matchedElement: element?.ui,
            focusMode: focusMode,
            verification: v
        )
    }

    @MainActor
    private static func activateAndRaiseWindow(pid: Int32?, windowID: UInt32?, element: StoredElement?) async throws {
        guard let pid else { return }
        try await WindowManager.requireAppActive(pid: pid)
        let resolvedWID = windowID ?? element?.ui.windowID
        let winFrame = resolvedWID.flatMap(windowFrameForID)
        if element?.axRef != nil || winFrame != nil {
            AXInspector.raiseContainingWindow(
                element: element?.axRef,
                pid: pid,
                windowFrame: winFrame
            )
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    private static func sendPostToPidMouseClick(
        pid: Int32,
        point: CGPoint,
        button: String,
        clickCount: Int,
        modifiers: [String]
    ) async throws {
        try ensurePostAccess()
        let flags = try KeyCodes.modifierFlags(modifiers)
        let (cgButton, downType, upType) = try resolveMouseButton(button)
        let source = makeSource()

        for clickNum in 1...clickCount {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton)
            else {
                throw MacOSUseError.inputFailed("Unable to allocate CGEvent for background mouse click.")
            }
            down.flags = flags
            up.flags = flags
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickNum))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickNum))
            down.postToPid(pid)
            try? await Task.sleep(for: .milliseconds(25))
            up.postToPid(pid)
            if clickNum < clickCount {
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private static func sendHardwareMouseClick(
        point: CGPoint,
        button: String,
        clickCount: Int,
        modifiers: [String]
    ) async throws {
        try ensurePostAccess()
        let flags = try KeyCodes.modifierFlags(modifiers)
        let (cgButton, downType, upType) = try resolveMouseButton(button)
        let source = makeSource()

        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: cgButton) {
            move.flags = flags
            move.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(20))

        for clickNum in 1...clickCount {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton)
            else {
                throw MacOSUseError.inputFailed("Unable to allocate CGEvent for mouse click.")
            }
            down.flags = flags
            up.flags = flags
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickNum))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickNum))
            down.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(25))
            up.post(tap: .cghidEventTap)
            if clickNum < clickCount {
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    public static func drag(
        from start: CGPoint,
        to end: CGPoint,
        durationMs: Int = 350,
        modifiers: [String] = []
    ) async throws {
        try ensurePostAccess()
        let flags = try KeyCodes.modifierFlags(modifiers)
        let source = makeSource()

        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left) {
            move.flags = flags
            move.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(for: .milliseconds(25))

        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            throw MacOSUseError.inputFailed("Unable to allocate leftMouseDown CGEvent.")
        }
        down.flags = flags
        down.post(tap: .cghidEventTap)

        let steps = 20
        let totalMs = max(120, min(durationMs, 5000))
        let stepMs = max(5, totalMs / steps)

        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let p = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            if let dragEv = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) {
                dragEv.flags = flags
                dragEv.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(stepMs))
        }

        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    public static func scroll(
        at point: CGPoint?,
        deltaX: Int,
        deltaY: Int,
        unit: String = "pixel"
    ) async throws {
        try ensurePostAccess()
        if let point {
            try await moveMouse(to: point, smooth: false)
            try? await Task.sleep(for: .milliseconds(15))
        }

        guard let wheelX = Int32(exactly: deltaX), let wheelY = Int32(exactly: deltaY) else {
            throw MacOSUseError.invalidArgument("Scroll deltas must fit in a signed 32-bit integer.")
        }
        let scrollUnit: CGScrollEventUnit = unit.lowercased() == "line" ? .line : .pixel
        let source = makeSource()
        guard let ev = CGEvent(
            scrollWheelEvent2Source: source,
            units: scrollUnit,
            wheelCount: 2,
            wheel1: wheelY,
            wheel2: wheelX,
            wheel3: 0
        ) else {
            throw MacOSUseError.inputFailed("Unable to allocate scrollWheelEvent2 CGEvent.")
        }
        ev.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    public static func pressKey(
        key: String,
        modifiers: [String] = [],
        repeatCount: Int = 1,
        targetPID: Int32? = nil,
        focusMode: FocusMode = .auto
    ) async throws {
        try ensurePostAccess()
        let mapping = try KeyCodes.lookup(key)
        var flags = try KeyCodes.modifierFlags(modifiers)
        if mapping.implicitShift {
            flags.insert(.maskShift)
        }

        let repeats = max(1, min(repeatCount, 50))
        let source = makeSource()

        if focusMode == .background {
            guard let pid = targetPID else {
                throw MacOSUseError.invalidArgument(
                    "Background press_key requires a target app PID (pass app_name, bundle_id, or pid)."
                )
            }
            for i in 0..<repeats {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: mapping.keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: mapping.keyCode, keyDown: false)
                else {
                    throw MacOSUseError.inputFailed("Unable to allocate background keyboard CGEvent.")
                }
                down.flags = flags
                up.flags = flags
                down.postToPid(pid)
                try? await Task.sleep(for: .milliseconds(14))
                up.postToPid(pid)
                if i < repeats - 1 {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            return
        }

        let savedFocus = (focusMode == .restore) ? await captureFocusState() : (nil, nil)
        if let targetPID {
            try await WindowManager.requireAppActive(pid: targetPID)
        }

        for i in 0..<repeats {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: mapping.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: mapping.keyCode, keyDown: false)
            else {
                throw MacOSUseError.inputFailed("Unable to allocate keyboard CGEvent.")
            }
            down.flags = flags
            up.flags = flags
            if let targetPID { down.postToPid(targetPID) } else { down.post(tap: .cghidEventTap) }
            try? await Task.sleep(for: .milliseconds(14))
            if let targetPID { up.postToPid(targetPID) } else { up.post(tap: .cghidEventTap) }
            if i < repeats - 1 {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        if focusMode == .restore {
            try? await Task.sleep(for: .milliseconds(60))
            await restoreFocusState(savedFocus)
        }
    }

    @discardableResult
    public static func typeText(
        text: String,
        element: StoredElement? = nil,
        targetPID: Int32? = nil,
        clearFirst: Bool = false,
        pressEnter: Bool = false,
        method: String = "auto",
        focusMode: FocusMode = .auto,
        verify: Bool = true
    ) async throws -> TypeOutcome {
        let resolvedPID = targetPID ?? element?.ui.ownerPID
        let normMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Background mode: zero foreground focus steal
        if focusMode == .background {
            if let axRef = element?.axRef {
                _ = AXInspector.focusElement(axRef)
            }

            if (normMethod == "ax_value" || normMethod == "auto"), let axRef = element?.axRef {
                if AXInspector.setValue(axRef, value: text) {
                    var valueMatched = true
                    var shouldEscalate = false
                    if verify && normMethod == "auto" && !text.isEmpty {
                        try? await Task.sleep(for: .milliseconds(30))
                        let readBack = AXInspector.readValueString(axRef) ?? ""
                        let isMasked = !readBack.isEmpty && readBack.allSatisfy { $0 == "•" || $0 == "*" }
                        let prefix = String(text.prefix(16))
                        if !isMasked && !readBack.contains(prefix) {
                            valueMatched = false
                            shouldEscalate = (resolvedPID != nil)
                        }
                    }

                    if !shouldEscalate {
                        if pressEnter {
                            guard let pid = resolvedPID else {
                                throw MacOSUseError.invalidArgument(
                                    "press_enter=true in background mode requires a target app PID."
                                )
                            }
                            try? await Task.sleep(for: .milliseconds(40))
                            try await pressKey(key: "return", targetPID: pid, focusMode: .background)
                        }
                        return TypeOutcome(
                            methodUsed: "ax_value",
                            verified: verify,
                            valueMatched: valueMatched,
                            escalated: false,
                            focusMode: .background
                        )
                    }
                    // Fall through to postToPid Unicode escalation
                }
                if normMethod == "ax_value" {
                    throw MacOSUseError.inputFailed("AXSetValue failed on element '\(element?.ui.id ?? "?")'.")
                }
            } else if normMethod == "ax_value" {
                throw MacOSUseError.invalidArgument("method='ax_value' requires an active Accessibility element reference.")
            }

            if normMethod == "paste" {
                throw MacOSUseError.invalidArgument("method='paste' requires foreground focus; use method='auto' or 'unicode' in background mode.")
            }

            guard let pid = resolvedPID else {
                throw MacOSUseError.invalidArgument(
                    "Background type_text requires a target app PID (specify app_name, bundle_id, window_id, or element_id)."
                )
            }
            try ensurePostAccess()

            if clearFirst {
                if let axRef = element?.axRef, AXInspector.setValue(axRef, value: "") {
                    try? await Task.sleep(for: .milliseconds(25))
                } else {
                    try await pressKey(key: "a", modifiers: ["command"], targetPID: pid, focusMode: .background)
                    try? await Task.sleep(for: .milliseconds(35))
                    try await pressKey(key: "delete", targetPID: pid, focusMode: .background)
                    try? await Task.sleep(for: .milliseconds(35))
                }
            }

            try await sendUnicodeString(text, targetPID: pid)

            if pressEnter {
                try? await Task.sleep(for: .milliseconds(35))
                try await pressKey(key: "return", targetPID: pid, focusMode: .background)
            }
            let matched = verify ? checkTypedReadback(element: element, expected: text) : true
            return TypeOutcome(
                methodUsed: "unicode_pid",
                verified: verify,
                valueMatched: matched,
                escalated: normMethod == "auto" && element?.axRef != nil,
                focusMode: .background
            )
        }

        // Foreground / auto / restore modes
        let savedFocus = (focusMode == .restore) ? await captureFocusState() : (nil, nil)
        if let resolvedPID {
            try await WindowManager.requireAppActive(pid: resolvedPID)
        }

        if let element, element.axRef == nil || normMethod != "ax_value" {
            _ = try await click(
                point: element.ui.frame.center.cgPoint,
                element: element,
                ownerPID: resolvedPID,
                method: "auto",
                focusMode: .foreground
            )
            try? await Task.sleep(for: .milliseconds(60))
        }

        if normMethod == "ax_value" {
            guard let axRef = element?.axRef else {
                throw MacOSUseError.invalidArgument("method='ax_value' requires an active Accessibility element reference.")
            }
            guard AXInspector.setValue(axRef, value: text) else {
                throw MacOSUseError.inputFailed("AXSetValue failed on element '\(element?.ui.id ?? "?")'.")
            }
            let matched = verify ? checkTypedReadback(element: element, expected: text) : true
            if pressEnter {
                try await pressKey(key: "return", targetPID: resolvedPID, focusMode: resolvedPID == nil ? .foreground : .background)
            }
            if focusMode == .restore {
                try? await Task.sleep(for: .milliseconds(60))
                await restoreFocusState(savedFocus)
            }
            return TypeOutcome(
                methodUsed: "ax_value",
                verified: verify,
                valueMatched: matched,
                escalated: false,
                focusMode: focusMode
            )
        }

        try ensurePostAccess()

        if clearFirst {
            try await pressKey(key: "a", modifiers: ["command"], targetPID: resolvedPID, focusMode: resolvedPID == nil ? .foreground : .background)
            try? await Task.sleep(for: .milliseconds(35))
            try await pressKey(key: "delete", targetPID: resolvedPID, focusMode: resolvedPID == nil ? .foreground : .background)
            try? await Task.sleep(for: .milliseconds(35))
        }

        let usedMethod: String
        if normMethod == "paste" {
            usedMethod = "paste"
            try await ClipboardManager.withTemporaryText(text) {
                try await pressKey(key: "v", modifiers: ["command"], targetPID: resolvedPID, focusMode: resolvedPID == nil ? .foreground : .background)
                try await Task.sleep(for: .milliseconds(90))
            }
        } else {
            usedMethod = "unicode"
            try await sendUnicodeString(text, targetPID: resolvedPID)
        }

        if pressEnter {
            try? await Task.sleep(for: .milliseconds(25))
            try await pressKey(key: "return", targetPID: resolvedPID, focusMode: resolvedPID == nil ? .foreground : .background)
        }

        let matched = verify ? checkTypedReadback(element: element, expected: text) : true
        if focusMode == .restore {
            try? await Task.sleep(for: .milliseconds(60))
            await restoreFocusState(savedFocus)
        }
        return TypeOutcome(
            methodUsed: usedMethod,
            verified: verify,
            valueMatched: matched,
            escalated: false,
            focusMode: focusMode
        )
    }

    public static func triggerContextMenu(
        element: StoredElement?,
        point: CGPoint?,
        pid: Int32,
        windowID: UInt32? = nil,
        menuPath: [String]? = nil
    ) async throws -> (items: [MenuItemInfo], triggered: String?) {
        var opened = false
        if let axRef = element?.axRef, AXInspector.performShowMenu(axRef) {
            opened = true
        } else {
            guard let pt = point ?? element?.ui.frame.center.cgPoint else {
                throw MacOSUseError.invalidArgument("context_menu requires element_id, query, or (x, y) coordinates.")
            }
            _ = try await click(
                point: pt,
                element: element,
                ownerPID: pid,
                windowID: windowID,
                button: "right",
                clickCount: 1,
                method: "cgevent",
                focusMode: .foreground,
                verify: false
            )
            opened = true
        }

        if opened {
            try? await Task.sleep(for: .milliseconds(160))
        }
        let items = AXInspector.inspectOpenMenus(pid: pid)
        var triggered: String?
        if let menuPath, !menuPath.isEmpty {
            triggered = try AXInspector.triggerOpenMenuEntry(pid: pid, menuPath: menuPath)
        }
        return (items, triggered)
    }

    private static func sendUnicodeString(_ text: String, targetPID: Int32?) async throws {
        let source = makeSource()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                try await pressKey(key: "return", targetPID: targetPID, focusMode: targetPID != nil ? .background : .foreground)
                continue
            }
            if scalar == "\t" {
                try await pressKey(key: "tab", targetPID: targetPID, focusMode: targetPID != nil ? .background : .foreground)
                continue
            }
            var utf16 = Array(String(scalar).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                throw MacOSUseError.inputFailed("Unable to create Unicode keyboard CGEvent.")
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            if let pid = targetPID {
                down.postToPid(pid)
                up.postToPid(pid)
            } else {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(6))
        }
    }

    private static func checkTypedReadback(element: StoredElement?, expected: String) -> Bool {
        guard !expected.isEmpty, let axRef = element?.axRef else { return true }
        guard let readBack = AXInspector.readValueString(axRef) else { return true }
        if readBack.allSatisfy({ $0 == "•" || $0 == "*" }) { return true }
        return readBack.contains(String(expected.prefix(16)))
    }

    // MARK: - Helpers

    private static func windowFrameForID(_ wid: UInt32) -> ScreenRect? {
        let rawList = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for dict in rawList {
            guard let num = dict[kCGWindowNumber as String] as? NSNumber,
                  num.uint32Value == wid,
                  let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            return ScreenRect(cgRect: cgRect)
        }
        return nil
    }

    private static func resolveMouseButton(_ button: String) throws -> (CGMouseButton, CGEventType, CGEventType) {
        switch button {
        case "left", "":
            return (.left, .leftMouseDown, .leftMouseUp)
        case "right":
            return (.right, .rightMouseDown, .rightMouseUp)
        case "middle", "center":
            return (.center, .otherMouseDown, .otherMouseUp)
        default:
            throw MacOSUseError.invalidArgument("Unsupported mouse button '\(button)'. Expected left, right, or middle.")
        }
    }
}

private extension Optional {
    func asyncMap<U>(_ transform: (Wrapped) async -> U) async -> U? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
