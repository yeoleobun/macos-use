@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Inspects live `AXUIElement` trees and macOS menu bars when Accessibility TCC is granted.
public enum AXInspector {
    public struct InspectionOptions: Sendable {
        public var maxDepth: Int
        public var maxNodes: Int
        public var maxOutputElements: Int
        public var timeoutSeconds: Float
        public var includePopups: Bool

        public init(
            maxDepth: Int = 45,
            maxNodes: Int = 5000,
            maxOutputElements: Int = 220,
            timeoutSeconds: Float = 1.5,
            includePopups: Bool = true
        ) {
            self.maxDepth = maxDepth
            self.maxNodes = maxNodes
            self.maxOutputElements = maxOutputElements
            self.timeoutSeconds = timeoutSeconds
            self.includePopups = includePopups
        }
    }

    public static func inspectWindow(
        window: WindowInfo?,
        bounds: ScreenRect,
        options: InspectionOptions = InspectionOptions()
    ) -> [StoredElement] {
        guard AXIsProcessTrusted(), let pid = window?.ownerPID else {
            return []
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, options.timeoutSeconds)
        // Enable Chromium / Electron / WebKit accessibility trees (Antigravity, Chrome, VS Code, etc.).
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let rootWindow = resolveTargetAXWindow(appElement: appElement, window: window)
        guard let rootWindow else {
            return []
        }

        var visited = 0
        var results: [StoredElement] = []
        var stack: [(element: AXUIElement, depth: Int, parentLabel: String?, parentFrame: ScreenRect?, clip: ScreenRect)] = []

        if options.includePopups {
            let expandedClip = ScreenRect(
                x: bounds.x - 1000.0,
                y: bounds.y - 1000.0,
                width: bounds.width + 2000.0,
                height: bounds.height + 2000.0
            )
            var extraRoots: [AXUIElement] = []
            extraRoots.append(contentsOf: copyAXElementArray(rootWindow, attribute: "AXSheets" as CFString))

            let appWindows = copyAXElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
            for w in appWindows {
                if CFEqual(w, rootWindow) { continue }
                let subrole = copyString(w, attribute: kAXSubroleAttribute as CFString) ?? ""
                if ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(subrole) {
                    extraRoots.append(w)
                }
            }

            for menuNode in findOpenMenuNodes(appElement: appElement, rootWindow: rootWindow) {
                extraRoots.append(menuNode)
            }

            // Push primary window first so extra popups/sheets/menus pop on top first, or vice versa
            for extra in extraRoots.reversed() {
                stack.append((extra, 0, nil, nil, expandedClip))
            }
        }

        stack.append((rootWindow, 0, nil, nil, bounds))

        let interactiveParentRoles: Set<String> = ["button", "link", "tab", "menuitem"]

        while !stack.isEmpty && visited < options.maxNodes && results.count < options.maxOutputElements {
            let (node, depth, parentLabel, parentFrame, clipBounds) = stack.removeLast()
            visited += 1

            var nextParentLabel = parentLabel
            var nextParentFrame = parentFrame

            if let stored = extractElement(
                node,
                ownerPID: pid,
                windowID: window?.windowID,
                clipBounds: clipBounds
            ) {
                let isRedundantChildText = stored.ui.role == "text"
                    && !stored.ui.isInteractive
                    && parentLabel != nil
                    && parentFrame != nil
                    && stored.ui.label == parentLabel
                    && parentFrame!.padded(by: 4.0).contains(stored.ui.frame.center)

                if !isRedundantChildText {
                    results.append(stored)
                }

                if interactiveParentRoles.contains(stored.ui.role),
                   !stored.ui.label.isEmpty,
                   stored.ui.label != stored.ui.role
                {
                    nextParentLabel = stored.ui.label
                    nextParentFrame = stored.ui.frame
                }
            }

            if depth < options.maxDepth {
                let children = copyAXElementArray(node, attribute: kAXChildrenAttribute as CFString)
                // Push in reverse so stack pops children in natural top-to-bottom order.
                for child in children.reversed() {
                    stack.append((child, depth + 1, nextParentLabel, nextParentFrame, clipBounds))
                }
            }
        }

        return results
    }

    static func pressForClick(_ ref: AXElementRef) throws -> Bool {
        let status = AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
        switch status {
        case .success: return true
        case .actionUnsupported, .notImplemented: return false
        default: throw MacOSUseError.inputFailed("AXPress returned status \(status.rawValue). Observe the target before another click.")
        }
    }

    public static func performPress(_ ref: AXElementRef) -> Bool {
        let err = AXUIElementPerformAction(ref.element, kAXPressAction as CFString)
        return err == .success
    }

    @discardableResult
    public static func focusElement(_ ref: AXElementRef) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(ref.element, kAXFocusedAttribute as CFString, &settable) == .success,
              settable.boolValue
        else {
            return false
        }
        return AXUIElementSetAttributeValue(ref.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult
    public static func unminimizeWindowsIfNeeded(pid: Int32) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.5)
        let windows = copyAXElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
        var changed = false
        for win in windows {
            if copyBool(win, attribute: kAXMinimizedAttribute as CFString) == true {
                if AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success {
                    changed = true
                }
            }
        }
        return changed
    }

    public static func raiseContainingWindow(
        element: AXElementRef?,
        pid: Int32,
        windowFrame: ScreenRect?
    ) {
        guard AXIsProcessTrusted() else { return }

        if let raw = element?.element {
            var current: AXUIElement? = raw
            for _ in 0..<50 {
                guard let node = current else { break }
                if copyString(node, attribute: kAXRoleAttribute as CFString) == kAXWindowRole {
                    _ = AXUIElementPerformAction(node, kAXRaiseAction as CFString)
                    _ = AXUIElementSetAttributeValue(node, kAXMainAttribute as CFString, kCFBooleanTrue)
                    return
                }
                current = copyAXElement(node, attribute: kAXParentAttribute as CFString)
            }
        }

        if let frame = windowFrame {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 1.5)
            let windows = copyAXElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
            if let closest = windows.min(by: { lhs, rhs in
                let lf = copyFrame(lhs) ?? .zero
                let rf = copyFrame(rhs) ?? .zero
                let ld = hypot(lf.origin.x - frame.x, lf.origin.y - frame.y)
                    + hypot(lf.size.width - frame.width, lf.size.height - frame.height)
                let rd = hypot(rf.origin.x - frame.x, rf.origin.y - frame.y)
                    + hypot(rf.size.width - frame.width, rf.size.height - frame.height)
                return ld < rd
            }) {
                _ = AXUIElementPerformAction(closest, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(closest, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    public static func setValue(_ ref: AXElementRef, value: String) -> Bool {
        _ = focusElement(ref)
        var valueSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(ref.element, kAXValueAttribute as CFString, &valueSettable) == .success,
           !valueSettable.boolValue
        {
            return false
        }
        let err = AXUIElementSetAttributeValue(ref.element, kAXValueAttribute as CFString, value as CFString)
        return err == .success
    }

    public static func readValueString(_ ref: AXElementRef) -> String? {
        resolveValueString(ref.element)
    }

    public static func elementStateSignature(_ ref: AXElementRef) -> String? {
        guard let role = copyString(ref.element, attribute: kAXRoleAttribute as CFString) else {
            return nil
        }
        let title = copyString(ref.element, attribute: kAXTitleAttribute as CFString) ?? ""
        let val = resolveValueString(ref.element) ?? ""
        let enabled = copyBool(ref.element, attribute: kAXEnabledAttribute as CFString) ?? true
        let focused = copyBool(ref.element, attribute: kAXFocusedAttribute as CFString) ?? false
        let selected = copyBool(ref.element, attribute: kAXSelectedAttribute as CFString) ?? false
        let f = copyFrame(ref.element) ?? .zero
        return "\(role)|\(title)|\(val)|\(enabled)|\(focused)|\(selected)|\(Int(f.origin.x.rounded())),\(Int(f.origin.y.rounded())),\(Int(f.size.width.rounded())),\(Int(f.size.height.rounded()))"
    }

    public static func focusedElementSignature(pid: Int32) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.8)
        guard let focused = copyAXElement(appEl, attribute: kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }
        return elementStateSignature(AXElementRef(focused))
    }

    public static func readNumericValue(_ ref: AXElementRef) -> Double? {
        var valRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref.element, kAXValueAttribute as CFString, &valRef) == .success,
              let num = valRef as? NSNumber
        else {
            return nil
        }
        return num.doubleValue
    }

    public static func readMinMaxValues(_ ref: AXElementRef) -> (min: Double, max: Double) {
        var minRef: CFTypeRef?
        var maxRef: CFTypeRef?
        let minVal = (AXUIElementCopyAttributeValue(ref.element, kAXMinValueAttribute as CFString, &minRef) == .success)
            ? (minRef as? NSNumber)?.doubleValue : nil
        let maxVal = (AXUIElementCopyAttributeValue(ref.element, kAXMaxValueAttribute as CFString, &maxRef) == .success)
            ? (maxRef as? NSNumber)?.doubleValue : nil
        return (minVal ?? 0.0, maxVal ?? 100.0)
    }

    public static func setNumericValue(_ ref: AXElementRef, value: Double) -> Bool {
        _ = focusElement(ref)
        let num = NSNumber(value: value)
        return AXUIElementSetAttributeValue(ref.element, kAXValueAttribute as CFString, num) == .success
    }

    public static func setSelectedTextRange(_ ref: AXElementRef, start: Int, length: Int) -> String? {
        _ = focusElement(ref)
        var range = CFRange(location: max(0, start), length: max(0, length))
        guard let axRange = AXValueCreate(.cfRange, &range) else {
            return nil
        }
        let err = AXUIElementSetAttributeValue(ref.element, kAXSelectedTextRangeAttribute as CFString, axRange)
        guard err == .success else { return nil }
        return copyString(ref.element, attribute: kAXSelectedTextAttribute as CFString)
    }

    @discardableResult
    public static func scrollToHiddenElement(
        pid: Int32,
        window: WindowInfo?,
        query: String,
        role: String?
    ) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        guard let rootWindow = resolveTargetAXWindow(appElement: appEl, window: window) else {
            return false
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let r = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var stack: [(AXUIElement, Int)] = [(rootWindow, 0)]
        var visited = 0

        while !stack.isEmpty && visited < 4000 {
            let (node, depth) = stack.removeLast()
            visited += 1

            let rawRole = copyString(node, attribute: kAXRoleAttribute as CFString) ?? ""
            let subrole = copyString(node, attribute: kAXSubroleAttribute as CFString)
            let normRole = normalizeRole(rawRole: rawRole, subrole: subrole)
            let roleMatches = r.isEmpty || normRole.contains(r) || rawRole.lowercased().contains(r)

            if roleMatches {
                let label = resolveLabel(node).lowercased()
                let val = (resolveValueString(node) ?? "").lowercased()
                if (!label.isEmpty && label.contains(q)) || (!val.isEmpty && val.contains(q)) {
                    if AXUIElementPerformAction(node, "AXScrollToVisible" as CFString) == .success {
                        return true
                    }
                    // Also try parent row/cell in NSTableView/NSOutlineView
                    if let parent = copyAXElement(node, attribute: kAXParentAttribute as CFString),
                       AXUIElementPerformAction(parent, "AXScrollToVisible" as CFString) == .success
                    {
                        return true
                    }
                }
            }

            if depth < 40 {
                let children = copyAXElementArray(node, attribute: kAXChildrenAttribute as CFString)
                for child in children.reversed() {
                    stack.append((child, depth + 1))
                }
            }
        }
        return false
    }

    public static func moveWindowPosition(pid: Int32, windowFrame: ScreenRect?, to origin: CGPoint) -> ScreenRect? {
        guard AXIsProcessTrusted() else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        let windows = copyAXElementArray(appEl, attribute: kAXWindowsAttribute as CFString)
        guard !windows.isEmpty else { return nil }

        let targetWin: AXUIElement?
        if let frame = windowFrame {
            targetWin = windows.min(by: { lhs, rhs in
                let lf = copyFrame(lhs) ?? .zero
                let rf = copyFrame(rhs) ?? .zero
                let ld = hypot(lf.origin.x - frame.x, lf.origin.y - frame.y)
                let rd = hypot(rf.origin.x - frame.x, rf.origin.y - frame.y)
                return ld < rd
            })
        } else {
            targetWin = copyAXElement(appEl, attribute: kAXFocusedWindowAttribute as CFString) ?? windows.first
        }

        guard let win = targetWin else { return nil }
        var pt = origin
        guard let axPoint = AXValueCreate(.cgPoint, &pt) else { return nil }
        guard AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPoint) == .success else {
            return nil
        }
        return copyFrame(win).map(ScreenRect.init(cgRect:))
    }

    // MARK: - Menu Bar Discovery & Execution

    public static func listMenuBar(pid: Int32) throws -> [MenuItemInfo] {
        guard AXIsProcessTrusted() else {
            throw MacOSUseError.accessibilityUnavailable(
                "Accessibility permission is required to read macOS menu bars (AXIsProcessTrusted=false). Run `macos-use doctor --prompt-ax` and enable Accessibility."
            )
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.5)

        guard let menuBar = copyAXElement(appElement, attribute: kAXMenuBarAttribute as CFString) else {
            throw MacOSUseError.targetNotFound("Menu bar not found for PID \(pid).")
        }

        var items: [MenuItemInfo] = []
        let topMenus = copyAXElementArray(menuBar, attribute: kAXChildrenAttribute as CFString)
        for topItem in topMenus {
            let topTitle = copyString(topItem, attribute: kAXTitleAttribute as CFString) ?? ""
            if topTitle.isEmpty { continue }
            let enabled = copyBool(topItem, attribute: kAXEnabledAttribute as CFString) ?? true
            items.append(MenuItemInfo(path: [topTitle], title: topTitle, shortcut: nil, enabled: enabled))

            let subMenus = copyAXElementArray(topItem, attribute: kAXChildrenAttribute as CFString)
            for subMenu in subMenus {
                let menuEntries = copyAXElementArray(subMenu, attribute: kAXChildrenAttribute as CFString)
                for entry in menuEntries {
                    let title = copyString(entry, attribute: kAXTitleAttribute as CFString) ?? ""
                    if title.isEmpty { continue }
                    let entryEnabled = copyBool(entry, attribute: kAXEnabledAttribute as CFString) ?? true
                    let shortcut = formatShortcut(entry)
                    items.append(
                        MenuItemInfo(
                            path: [topTitle, title],
                            title: title,
                            shortcut: shortcut,
                            enabled: entryEnabled
                        )
                    )
                }
            }
        }
        return items
    }

    public static func triggerMenuItem(pid: Int32, path: [String]) throws -> String {
        guard AXIsProcessTrusted() else {
            throw MacOSUseError.accessibilityUnavailable(
                "Accessibility permission is required for menu_action (AXIsProcessTrusted=false). Run `macos-use doctor --prompt-ax` and enable Accessibility."
            )
        }
        guard !path.isEmpty else {
            throw MacOSUseError.invalidArgument("Menu path must contain at least one menu title.")
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.5)
        guard let menuBar = copyAXElement(appElement, attribute: kAXMenuBarAttribute as CFString) else {
            throw MacOSUseError.targetNotFound("Menu bar not found for PID \(pid).")
        }

        var currentContainer = menuBar
        var matchedTarget: AXUIElement?

        for (depth, rawSegment) in path.enumerated() {
            let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            let children = copyAXElementArray(currentContainer, attribute: kAXChildrenAttribute as CFString)
            let found = children.first { el in
                let title = copyString(el, attribute: kAXTitleAttribute as CFString) ?? ""
                return title.caseInsensitiveCompare(segment) == .orderedSame
            } ?? children.first { el in
                let title = copyString(el, attribute: kAXTitleAttribute as CFString) ?? ""
                return title.localizedCaseInsensitiveContains(segment)
            }

            guard let match = found else {
                throw MacOSUseError.targetNotFound("Menu item '\(segment)' not found at depth \(depth).")
            }
            if depth == path.count - 1 {
                matchedTarget = match
            } else {
                let subChildren = copyAXElementArray(match, attribute: kAXChildrenAttribute as CFString)
                guard let subMenu = subChildren.first else {
                    throw MacOSUseError.targetNotFound("Menu item '\(segment)' has no submenu.")
                }
                currentContainer = subMenu
            }
        }

        guard let target = matchedTarget else {
            throw MacOSUseError.targetNotFound("Menu item path not resolved.")
        }
        let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard err == .success else {
            throw MacOSUseError.appOperationFailed("AXPress on menu item failed with code \(err.rawValue).")
        }
        return copyString(target, attribute: kAXTitleAttribute as CFString) ?? path.joined(separator: " > ")
    }

    public static func inspectOpenMenus(pid: Int32) -> [MenuItemInfo] {
        guard AXIsProcessTrusted() else { return [] }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        let focusedWin = copyAXElement(appEl, attribute: kAXFocusedWindowAttribute as CFString)
        let menus = findOpenMenuNodes(appElement: appEl, rootWindow: focusedWin)
        var items: [MenuItemInfo] = []
        for menu in menus {
            let entries = copyAXElementArray(menu, attribute: kAXChildrenAttribute as CFString)
            for entry in entries {
                let rawRole = copyString(entry, attribute: kAXRoleAttribute as CFString) ?? ""
                guard rawRole == kAXMenuItemRole || rawRole == kAXMenuBarItemRole else { continue }
                let title = copyString(entry, attribute: kAXTitleAttribute as CFString)
                    ?? copyString(entry, attribute: kAXDescriptionAttribute as CFString)
                    ?? ""
                if title.isEmpty { continue }
                let enabled = copyBool(entry, attribute: kAXEnabledAttribute as CFString) ?? true
                items.append(
                    MenuItemInfo(
                        path: [title],
                        title: title,
                        shortcut: formatShortcut(entry),
                        enabled: enabled
                    )
                )
            }
        }
        return items
    }

    public static func triggerOpenMenuEntry(pid: Int32, menuPath: [String]) throws -> String {
        guard AXIsProcessTrusted() else {
            throw MacOSUseError.accessibilityUnavailable("Accessibility permission required.")
        }
        guard !menuPath.isEmpty else {
            throw MacOSUseError.invalidArgument("menu_path cannot be empty.")
        }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        let focusedWin = copyAXElement(appEl, attribute: kAXFocusedWindowAttribute as CFString)
        let menus = findOpenMenuNodes(appElement: appEl, rootWindow: focusedWin)

        for menu in menus {
            var container = menu
            var matched: AXUIElement?
            var ok = true
            for (idx, rawSeg) in menuPath.enumerated() {
                let seg = rawSeg.trimmingCharacters(in: .whitespacesAndNewlines)
                let children = copyAXElementArray(container, attribute: kAXChildrenAttribute as CFString)
                let found = children.first {
                    (copyString($0, attribute: kAXTitleAttribute as CFString) ?? "").caseInsensitiveCompare(seg) == .orderedSame
                } ?? children.first {
                    (copyString($0, attribute: kAXTitleAttribute as CFString) ?? "").localizedCaseInsensitiveContains(seg)
                }
                guard let hit = found else {
                    ok = false
                    break
                }
                if idx == menuPath.count - 1 {
                    matched = hit
                } else if let sub = copyAXElementArray(hit, attribute: kAXChildrenAttribute as CFString).first {
                    container = sub
                } else {
                    ok = false
                    break
                }
            }
            if ok, let target = matched {
                if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success {
                    return copyString(target, attribute: kAXTitleAttribute as CFString) ?? menuPath.joined(separator: " > ")
                }
            }
        }
        throw MacOSUseError.targetNotFound("Open menu item '\(menuPath.joined(separator: " > "))' not found.")
    }

    public static func performShowMenu(_ ref: AXElementRef) -> Bool {
        AXUIElementPerformAction(ref.element, kAXShowMenuAction as CFString) == .success
    }

    private static func findOpenMenuNodes(appElement: AXUIElement, rootWindow: AXUIElement?) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var candidates: [AXUIElement] = copyAXElementArray(appElement, attribute: kAXChildrenAttribute as CFString)
        if let rootWindow {
            candidates.append(contentsOf: copyAXElementArray(rootWindow, attribute: kAXChildrenAttribute as CFString))
        }
        var queue: [(AXUIElement, Int)] = candidates.map { ($0, 0) }
        var steps = 0

        while !queue.isEmpty && steps < 180 {
            let (node, depth) = queue.removeFirst()
            steps += 1
            let role = copyString(node, attribute: kAXRoleAttribute as CFString) ?? ""
            if role == kAXMenuBarRole { continue }
            if role == kAXMenuRole {
                if let frame = copyFrame(node), frame.width >= 10, frame.height >= 10 {
                    found.append(node)
                }
                continue
            }
            if depth < 2 {
                for child in copyAXElementArray(node, attribute: kAXChildrenAttribute as CFString) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return found
    }

    /// Only follow the focused control's ancestry, so an unrelated window or sheet
    /// cannot supply the file picker, location field, or submit button.
    static func focusedFilePanel(pid: Int32) -> (panel: AXElementRef, location: AXElementRef?, submit: AXElementRef?)? {
        let app = AXUIElementCreateApplication(pid)
        let focused = copyAXElement(app, attribute: kAXFocusedUIElementAttribute as CFString)
        let attached = copyAXElement(app, attribute: kAXFocusedWindowAttribute as CFString)
            .map { copyAXElementArray($0, attribute: "AXSheets" as CFString) } ?? []
        guard let field = focused ?? (attached.count == 1 ? attached.first : nil) else { return nil }
        let fieldRole = copyString(field, attribute: kAXRoleAttribute as CFString)
        var current: AXUIElement? = field
        var locationSheet = false
        var nestedSheet = false
        for _ in 0..<32 {
            guard let node = current else { break }
            let id = (copyString(node, attribute: kAXIdentifierAttribute as CFString) ?? "")
                .lowercased().filter { $0.isLetter }
            let role = copyString(node, attribute: kAXRoleAttribute as CFString)
            if ["openpanel", "savepanel", "nsopenpanel", "nssavepanel"].contains(id) {
                var button = copyAXElement(node, attribute: kAXDefaultButtonAttribute as CFString)
                if button == nil && !nestedSheet {
                    var level = [node]
                    for _ in 0..<5 {
                        level = level.flatMap { copyAXElementArray($0, attribute: kAXChildrenAttribute as CFString) }
                        button = level.first {
                            copyString($0, attribute: kAXIdentifierAttribute as CFString) == "OKButton"
                                && copyString($0, attribute: kAXRoleAttribute as CFString) == kAXButtonRole
                        }
                        if button != nil { break }
                        level = level.filter {
                            let role = copyString($0, attribute: kAXRoleAttribute as CFString)
                            return role == kAXGroupRole || role == kAXSplitGroupRole
                        }
                    }
                }
                let isLocation = locationSheet && (fieldRole == kAXTextFieldRole || fieldRole == kAXComboBoxRole)
                return (AXElementRef(node), isLocation ? AXElementRef(field) : nil,
                        !nestedSheet ? button.map(AXElementRef.init) : nil)
            }
            if id == "gotowindow" || id.contains("gotofolder") || id.contains("gotolocation") { locationSheet = true }
            if role == kAXSheetRole {
                nestedSheet = true
                let title = (copyString(node, attribute: kAXTitleAttribute as CFString) ?? "").lowercased()
                if ["go to folder", "go to the folder", "前往文件夹"].contains(title) { locationSheet = true }
            }
            current = copyAXElement(node, attribute: kAXParentAttribute as CFString)
        }
        return nil
    }

    public static func inspectAXDialogs(pid: Int32, appName: String) -> [DialogInfo] {
        guard AXIsProcessTrusted() else { return [] }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        let windows = copyAXElementArray(appEl, attribute: kAXWindowsAttribute as CFString)

        var containers: [(element: AXUIElement, defaultType: String)] = []
        for win in windows {
            let subrole = copyString(win, attribute: kAXSubroleAttribute as CFString) ?? ""
            if ["AXDialog", "AXSystemDialog"].contains(subrole) {
                containers.append((win, subrole == "AXSystemDialog" ? "system_dialog" : "alert"))
            } else {
                // Check attached sheets on standard window
                for sheet in copyAXElementArray(win, attribute: "AXSheets" as CFString) {
                    containers.append((sheet, "sheet"))
                }
            }
            // Check explicit open/save panels inside windows too
            let role = copyString(win, attribute: kAXRoleAttribute as CFString) ?? ""
            if role == kAXWindowRole && containers.allSatisfy({ !CFEqual($0.element, win) }) {
                let idAttr = (copyString(win, attribute: kAXIdentifierAttribute as CFString) ?? "").lowercased()
                if idAttr.contains("openpanel") || idAttr.contains("savepanel") || idAttr.contains("nsopenpanel") || idAttr.contains("nssavepanel") {
                    containers.append((win, idAttr.contains("save") ? "file_save" : "file_open"))
                }
            }
        }

        return containers.map { entry in
            let title = copyString(entry.element, attribute: kAXTitleAttribute as CFString) ?? ""
            let defaultBtn = copyAXElement(entry.element, attribute: kAXDefaultButtonAttribute as CFString)
                .flatMap { copyString($0, attribute: kAXTitleAttribute as CFString) }
            let cancelBtn = copyAXElement(entry.element, attribute: kAXCancelButtonAttribute as CFString)
                .flatMap { copyString($0, attribute: kAXTitleAttribute as CFString) }

            var buttons: [String] = []
            var staticTexts: [String] = []
            var textFields: [String] = []
            var hasBrowserOrOutline = false

            var stack: [(AXUIElement, Int)] = [(entry.element, 0)]
            var visited = 0
            while !stack.isEmpty && visited < 400 {
                let (node, depth) = stack.removeLast()
                visited += 1
                let role = copyString(node, attribute: kAXRoleAttribute as CFString) ?? ""
                if role == kAXButtonRole {
                    let bLabel = resolveLabel(node)
                    if !bLabel.isEmpty && !buttons.contains(bLabel) {
                        buttons.append(bLabel)
                    }
                } else if role == kAXStaticTextRole {
                    if let txt = resolveValueString(node) ?? copyString(node, attribute: kAXTitleAttribute as CFString),
                       !txt.isEmpty, !staticTexts.contains(txt)
                    {
                        staticTexts.append(txt)
                    }
                } else if role == kAXTextFieldRole || role == "AXSearchField" {
                    let tfLabel = resolveLabel(node)
                    let tfVal = resolveValueString(node) ?? ""
                    let desc = tfLabel.isEmpty ? tfVal : (tfVal.isEmpty ? tfLabel : "\(tfLabel)=\(tfVal)")
                    if !desc.isEmpty { textFields.append(desc) }
                } else if role == kAXBrowserRole || role == kAXOutlineRole {
                    hasBrowserOrOutline = true
                }
                if depth < 12 {
                    for child in copyAXElementArray(node, attribute: kAXChildrenAttribute as CFString).reversed() {
                        stack.append((child, depth + 1))
                    }
                }
            }

            var dType = entry.defaultType
            let defLower = (defaultBtn ?? "").lowercased()
            if hasBrowserOrOutline || dType == "sheet" {
                if defLower == "save" || defLower == "存储" || defLower == "export" || defLower == "导出" {
                    dType = "file_save"
                } else if defLower == "open" || defLower == "打开" || defLower == "choose" || defLower == "选择" || hasBrowserOrOutline {
                    dType = "file_open"
                }
            }

            let message = staticTexts.prefix(5).joined(separator: " | ")
            return DialogInfo(
                dialogType: dType,
                ownerPID: pid,
                appName: appName,
                windowID: nil,
                title: title.isEmpty ? appName : title,
                message: message.isEmpty ? nil : message,
                buttons: buttons,
                defaultButton: defaultBtn,
                cancelButton: cancelBtn,
                textFields: textFields
            )
        }
    }

    public static func pressDialogButton(pid: Int32, button: String) -> (ok: Bool, frame: ScreenRect?) {
        guard AXIsProcessTrusted() else { return (false, nil) }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        let windows = copyAXElementArray(appEl, attribute: kAXWindowsAttribute as CFString)

        var containers: [AXUIElement] = []
        for win in windows {
            containers.append(contentsOf: copyAXElementArray(win, attribute: "AXSheets" as CFString))
            let subrole = copyString(win, attribute: kAXSubroleAttribute as CFString) ?? ""
            if ["AXDialog", "AXSystemDialog"].contains(subrole) {
                containers.append(win)
            }
        }
        if containers.isEmpty, let focused = copyAXElement(appEl, attribute: kAXFocusedWindowAttribute as CFString) {
            containers.append(focused)
        }

        let targetLower = button.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for container in containers {
            if targetLower == "default",
               let defBtn = copyAXElement(container, attribute: kAXDefaultButtonAttribute as CFString)
            {
                let f = copyFrame(defBtn).map(ScreenRect.init(cgRect:))
                let ok = AXUIElementPerformAction(defBtn, kAXPressAction as CFString) == .success
                return (ok, f)
            }
            if targetLower == "cancel",
               let cancelBtn = copyAXElement(container, attribute: kAXCancelButtonAttribute as CFString)
            {
                let f = copyFrame(cancelBtn).map(ScreenRect.init(cgRect:))
                let ok = AXUIElementPerformAction(cancelBtn, kAXPressAction as CFString) == .success
                return (ok, f)
            }

            var stack: [(AXUIElement, Int)] = [(container, 0)]
            var visited = 0
            while !stack.isEmpty && visited < 400 {
                let (node, depth) = stack.removeLast()
                visited += 1
                let role = copyString(node, attribute: kAXRoleAttribute as CFString) ?? ""
                if role == kAXButtonRole {
                    let lbl = resolveLabel(node).lowercased()
                    if lbl == targetLower || lbl.contains(targetLower) {
                        let f = copyFrame(node).map(ScreenRect.init(cgRect:))
                        let ok = AXUIElementPerformAction(node, kAXPressAction as CFString) == .success
                        return (ok, f)
                    }
                }
                if depth < 12 {
                    for child in copyAXElementArray(node, attribute: kAXChildrenAttribute as CFString).reversed() {
                        stack.append((child, depth + 1))
                    }
                }
            }
        }
        return (false, nil)
    }

    // MARK: - Element Extraction

    private static func resolveTargetAXWindow(appElement: AXUIElement, window: WindowInfo?) -> AXUIElement? {
        let windows = copyAXElementArray(appElement, attribute: kAXWindowsAttribute as CFString)
        if let window, !windows.isEmpty {
            if let byFrame = windows.min(by: { lhs, rhs in
                let lf = copyFrame(lhs) ?? .zero
                let rf = copyFrame(rhs) ?? .zero
                let ld = hypot(lf.origin.x - window.frame.x, lf.origin.y - window.frame.y)
                    + hypot(lf.size.width - window.frame.width, lf.size.height - window.frame.height)
                let rd = hypot(rf.origin.x - window.frame.x, rf.origin.y - window.frame.y)
                    + hypot(rf.size.width - window.frame.width, rf.size.height - window.frame.height)
                return ld < rd
            }), let matchedFrame = copyFrame(byFrame) {
                let dist = hypot(matchedFrame.origin.x - window.frame.x, matchedFrame.origin.y - window.frame.y)
                if dist < 40.0 {
                    return byFrame
                }
            }
            if !window.title.isEmpty,
               let byTitle = windows.first(where: { copyString($0, attribute: kAXTitleAttribute as CFString) == window.title })
            {
                return byTitle
            }
        }
        if let focused = copyAXElement(appElement, attribute: kAXFocusedWindowAttribute as CFString) {
            return focused
        }
        return windows.first
    }

    private static func extractElement(
        _ node: AXUIElement,
        ownerPID: Int32,
        windowID: UInt32?,
        clipBounds: ScreenRect
    ) -> StoredElement? {
        guard let rawRole = copyString(node, attribute: kAXRoleAttribute as CFString) else {
            return nil
        }

        let subrole = copyString(node, attribute: kAXSubroleAttribute as CFString)
        let actions = copyActionNames(node)
        let normalizedRole = normalizeRole(rawRole: rawRole, subrole: subrole)
        let interactive = isInteractiveRole(rawRole: rawRole, normalizedRole: normalizedRole, actions: actions)

        guard let cgRect = copyFrame(node) else { return nil }
        let frame = ScreenRect(cgRect: cgRect)
        guard frame.width >= 4, frame.height >= 4 else { return nil }
        guard frame.width <= clipBounds.width * 0.98 || frame.height <= clipBounds.height * 0.98 else {
            return nil
        }
        guard clipBounds.contains(frame.center) || clipBounds.intersection(with: frame) != nil else {
            return nil
        }

        let label = resolveLabel(node)
        let valueStr = resolveValueString(node)

        // Skip generic containers without interactivity or text
        if !interactive && label.isEmpty && (valueStr?.isEmpty ?? true) {
            return nil
        }
        if normalizedRole == "group" && !interactive {
            return nil
        }

        let enabled = copyBool(node, attribute: kAXEnabledAttribute as CFString) ?? true
        let focused = copyBool(node, attribute: kAXFocusedAttribute as CFString) ?? false
        let selected = copyBool(node, attribute: kAXSelectedAttribute as CFString) ?? false

        let ui = UIElement(
            id: "ax",
            index: 0,
            role: normalizedRole,
            rawRole: subrole.map { "\(rawRole)/\($0)" } ?? rawRole,
            label: label.isEmpty ? (valueStr ?? normalizedRole) : label,
            value: valueStr,
            enabled: enabled,
            focused: focused,
            selected: selected,
            isInteractive: interactive,
            actions: actions,
            source: .ax,
            confidence: 1.0,
            frame: frame,
            ownerPID: ownerPID,
            windowID: windowID
        )
        return StoredElement(ui: ui, axRef: AXElementRef(node))
    }

    private static func normalizeRole(rawRole: String, subrole: String?) -> String {
        switch rawRole {
        case kAXButtonRole:
            if subrole == kAXCloseButtonSubrole { return "close_button" }
            if subrole == kAXMinimizeButtonSubrole { return "minimize_button" }
            if subrole == kAXZoomButtonSubrole { return "zoom_button" }
            return "button"
        case kAXTextFieldRole, kAXTextAreaRole, "AXSearchField":
            return "textfield"
        case kAXCheckBoxRole:
            return subrole == "AXSwitch" ? "switch" : "checkbox"
        case kAXRadioButtonRole:
            return "radiobutton"
        case kAXPopUpButtonRole, kAXComboBoxRole, kAXMenuButtonRole:
            return "dropdown"
        case "AXTab", kAXTabGroupRole:
            return rawRole == "AXTab" ? "tab" : "tabgroup"
        case kAXMenuItemRole, kAXMenuBarItemRole:
            return "menuitem"
        case "AXLink":
            return "link"
        case kAXSliderRole:
            return "slider"
        case kAXRowRole:
            return "row"
        case kAXCellRole:
            return "cell"
        case kAXStaticTextRole:
            return "text"
        case kAXImageRole:
            return "image"
        case kAXGroupRole:
            return "group"
        default:
            return rawRole.replacingOccurrences(of: "AX", with: "").lowercased()
        }
    }

    private static func isInteractiveRole(rawRole: String, normalizedRole: String, actions: [String]) -> Bool {
        if actions.contains(kAXPressAction) || actions.contains("AXConfirm") {
            return true
        }
        let interactiveRoles: Set<String> = [
            "button", "close_button", "minimize_button", "zoom_button",
            "textfield", "checkbox", "switch", "radiobutton", "dropdown",
            "tab", "menuitem", "link", "slider"
        ]
        if interactiveRoles.contains(normalizedRole) {
            return true
        }
        return rawRole == kAXButtonRole || rawRole == kAXTextFieldRole
    }

    private static func resolveLabel(_ node: AXUIElement) -> String {
        let primaryAttrs: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXPlaceholderValueAttribute as CFString,
            kAXHelpAttribute as CFString
        ]
        for attr in primaryAttrs {
            if let str = copyString(node, attribute: attr), !str.isEmpty {
                return str
            }
        }

        // Bounded descendant scan for nested Electron/Web static text or image descriptions
        var texts: [String] = []
        var visited = 0
        let maxDescendants = 20

        func collectDescendantLabels(_ current: AXUIElement, depth: Int) {
            guard depth <= 3, visited < maxDescendants else { return }
            let children = copyAXElementArray(current, attribute: kAXChildrenAttribute as CFString)
            for child in children {
                guard visited < maxDescendants else { break }
                visited += 1
                let role = copyString(child, attribute: kAXRoleAttribute as CFString)
                if role == kAXStaticTextRole {
                    if let val = copyString(child, attribute: kAXValueAttribute as CFString)
                        ?? copyString(child, attribute: kAXTitleAttribute as CFString),
                       !val.isEmpty
                    {
                        texts.append(val)
                        continue
                    }
                } else if role == kAXImageRole {
                    if let desc = copyString(child, attribute: kAXDescriptionAttribute as CFString)
                        ?? copyString(child, attribute: kAXTitleAttribute as CFString),
                       !desc.isEmpty
                    {
                        texts.append(desc)
                        continue
                    }
                }
                collectDescendantLabels(child, depth: depth + 1)
            }
        }

        collectDescendantLabels(node, depth: 1)
        let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            return joined
        }

        if let rawId = copyString(node, attribute: kAXIdentifierAttribute as CFString) {
            return humanizeIdentifier(rawId) ?? ""
        }
        return ""
    }

    private static func humanizeIdentifier(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("_NS:") || trimmed.hasPrefix("NS:") || trimmed.hasPrefix("_NS") {
            return nil
        }
        if trimmed.count > 40 && trimmed.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            return nil
        }
        var cleaned = trimmed
        for suffix in ["Button", "Btn", "Control", "Field", "Action"] {
            if cleaned.hasSuffix(suffix) && cleaned.count > suffix.count + 1 {
                cleaned = String(cleaned.dropLast(suffix.count))
                break
            }
        }
        return cleaned.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveValueString(_ node: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &ref) == .success,
              let val = ref
        else {
            return nil
        }
        if let str = val as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(160))
        }
        if let num = val as? NSNumber {
            return num.stringValue
        }
        return nil
    }

    private static func formatShortcut(_ item: AXUIElement) -> String? {
        guard let cmdChar = copyString(item, attribute: kAXMenuItemCmdCharAttribute as CFString), !cmdChar.isEmpty else {
            return nil
        }
        var mods: [String] = []
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &ref) == .success,
           let flags = (ref as? NSNumber)?.intValue
        {
            if (flags & 4) != 0 { mods.append("Ctrl") }
            if (flags & 2) != 0 { mods.append("Opt") }
            if (flags & 1) != 0 { mods.append("Shift") }
            if (flags & 8) == 0 { mods.append("Cmd") }
        } else {
            mods.append("Cmd")
        }
        mods.append(cmdChar)
        return mods.joined(separator: "+")
    }

    // MARK: - AX Attribute Helpers

    private static func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let str = ref as? String
        else {
            return nil
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func copyBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let num = ref as? NSNumber
        else {
            return nil
        }
        return num.boolValue
    }

    private static func copyAXElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let cfRef = ref,
              CFGetTypeID(cfRef) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(cfRef, to: AXUIElement.self)
    }

    private static func copyAXElementArray(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let arr = ref as? [AXUIElement]
        else {
            return []
        }
        return arr
    }

    private static func copyActionNames(_ element: AXUIElement) -> [String] {
        var ref: CFArray?
        guard AXUIElementCopyActionNames(element, &ref) == .success,
              let arr = ref as? [String]
        else {
            return []
        }
        return arr
    }

    private static func copyFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pVal = posRef,
              let sVal = sizeRef,
              CFGetTypeID(pVal) == AXValueGetTypeID(),
              CFGetTypeID(sVal) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        let axPos = unsafeDowncast(pVal, to: AXValue.self)
        let axSize = unsafeDowncast(sVal, to: AXValue.self)
        guard AXValueGetValue(axPos, .cgPoint, &point),
              AXValueGetValue(axSize, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }
}
