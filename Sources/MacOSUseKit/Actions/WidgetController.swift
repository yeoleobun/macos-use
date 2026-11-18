import CoreGraphics
import Foundation

/// High-level interactions for virtualized scroll lists, sliders, checkboxes/switches, dropdowns, tabs, and text ranges.
public enum WidgetController {
    public struct ScrollSearchResult: Sendable {
        public let snapshot: UISnapshot
        public let element: StoredElement
        public let steps: Int
        public let method: String
    }

    public static func scrollUntilVisible(
        query: String,
        role: String? = nil,
        target: CaptureTargetScope,
        direction: String = "down",
        maxScrolls: Int = 12
    ) async throws -> ScrollSearchResult {
        let initial = try await PerceptionEngine.observe(
            target: target,
            includeImage: false,
            annotate: false,
            classifyIcons: false
        )
        let (_, immediateMatches) = await SnapshotStore.shared.findElements(
            query: query,
            role: role,
            interactiveOnly: false,
            snapshotID: initial.snapshot.snapshotID,
            limit: 3
        )
        if let hit = immediateMatches.first {
            return ScrollSearchResult(snapshot: initial.snapshot, element: hit, steps: 0, method: "already_visible")
        }

        // Fast AX off-viewport scroll path (NSTableView / NSOutlineView / WebKit / Electron)
        if let pid = initial.snapshot.ownerPID {
            let winInfo: WindowInfo? = if let wid = initial.snapshot.windowID {
                (try? await WindowManager.listWindows(includeSystemLayers: true, onScreenOnly: false))?
                    .first(where: { $0.windowID == wid })
            } else {
                nil
            }
            if AXInspector.scrollToHiddenElement(pid: pid, window: winInfo, query: query, role: role) {
                try? await Task.sleep(for: .milliseconds(140))
                let afterAX = try await PerceptionEngine.observe(
                    target: target,
                    includeImage: false,
                    annotate: false,
                    classifyIcons: false
                )
                let (_, axMatches) = await SnapshotStore.shared.findElements(
                    query: query,
                    role: role,
                    interactiveOnly: false,
                    snapshotID: afterAX.snapshot.snapshotID,
                    limit: 3
                )
                if let hit = axMatches.first {
                    return ScrollSearchResult(snapshot: afterAX.snapshot, element: hit, steps: 1, method: "ax_scroll_to_visible")
                }
            }
        }

        // Iterative wheel scroll loop
        let anchor = chooseScrollAnchor(in: initial.snapshot)
        let (dx, dy) = scrollDelta(direction: direction, bounds: initial.snapshot.transform.logicalBounds)
        let limit = max(1, min(maxScrolls, 30))

        if let pid = initial.snapshot.ownerPID {
            await WindowManager.ensureAppActive(pid: pid)
        }

        var prevSignature = layoutSignature(of: initial.snapshot)
        var unchangedCount = 0

        for step in 1...limit {
            try await InputController.scroll(at: anchor, deltaX: dx, deltaY: dy, unit: "pixel")
            _ = await UIEventObserver.waitForSettle(
                pid: initial.snapshot.ownerPID,
                windowID: initial.snapshot.windowID,
                maxWaitMs: 220,
                quietWindowMs: 70,
                checkVisual: false
            )
            let obs = try await PerceptionEngine.observe(
                target: target,
                includeImage: false,
                annotate: false,
                classifyIcons: false
            )
            let (_, matches) = await SnapshotStore.shared.findElements(
                query: query,
                role: role,
                interactiveOnly: false,
                snapshotID: obs.snapshot.snapshotID,
                limit: 3
            )
            if let hit = matches.first {
                return ScrollSearchResult(snapshot: obs.snapshot, element: hit, steps: step, method: "wheel_scroll")
            }

            let curSig = layoutSignature(of: obs.snapshot)
            if curSig == prevSignature {
                unchangedCount += 1
                if unchangedCount >= 2 {
                    break
                }
            } else {
                unchangedCount = 0
                prevSignature = curSig
            }
        }

        throw MacOSUseError.targetNotFound(
            "Element '\(query)' did not become visible after scrolling \(direction)."
        )
    }

    public static func setSlider(
        element: StoredElement,
        value: Double,
        focusMode: FocusMode
    ) async throws -> (appliedValue: Double, method: String) {
        if let axRef = element.axRef {
            let (minV, maxV) = AXInspector.readMinMaxValues(axRef)
            let clamped = min(max(value, minV), maxV)
            if AXInspector.setNumericValue(axRef, value: clamped) {
                try? await Task.sleep(for: .milliseconds(50))
                if let readBack = AXInspector.readNumericValue(axRef) {
                    let tol = max(0.05, abs(maxV - minV) * 0.03)
                    if abs(readBack - clamped) <= tol {
                        return (readBack, "ax_set_value")
                    }
                } else {
                    return (clamped, "ax_set_value")
                }
            }
            let frac = (clamped - minV) / max(0.0001, maxV - minV)
            let targetX = element.ui.frame.x + 8.0 + frac * max(1.0, element.ui.frame.width - 16.0)
            let pt = CGPoint(x: targetX, y: element.ui.frame.centerY)
            _ = try await InputController.click(
                point: pt,
                element: nil,
                ownerPID: element.ui.ownerPID,
                windowID: element.ui.windowID,
                method: "cgevent",
                focusMode: focusMode,
                verify: true
            )
            let finalVal = AXInspector.readNumericValue(axRef) ?? clamped
            return (finalVal, "cgevent_slider_click")
        }

        // Visual-only slider: treat 0..100 or 0..1 proportionally
        let frac = value <= 1.0 && value >= 0.0 ? value : min(max(value / 100.0, 0.0), 1.0)
        let targetX = element.ui.frame.x + 8.0 + frac * max(1.0, element.ui.frame.width - 16.0)
        let pt = CGPoint(x: targetX, y: element.ui.frame.centerY)
        _ = try await InputController.click(
            point: pt,
            element: nil,
            ownerPID: element.ui.ownerPID,
            windowID: element.ui.windowID,
            method: "cgevent",
            focusMode: focusMode,
            verify: true
        )
        return (value, "cgevent_slider_click")
    }

    public static func setCheckbox(
        element: StoredElement,
        desiredChecked: Bool?,
        focusMode: FocusMode
    ) async throws -> (newState: Bool?, changed: Bool, method: String) {
        let initial: Bool?
        if let axRef = element.axRef {
            if let num = AXInspector.readNumericValue(axRef) {
                initial = (num != 0)
            } else if let str = AXInspector.readValueString(axRef) {
                initial = (str == "1" || str.lowercased() == "true")
            } else {
                initial = element.ui.selected
            }
        } else {
            initial = element.ui.selected
        }

        if let desired = desiredChecked, let initial, initial == desired {
            return (initial, false, "already_desired_state")
        }

        let outcome = try await InputController.click(
            point: nil,
            element: element,
            ownerPID: element.ui.ownerPID,
            windowID: element.ui.windowID,
            method: "auto",
            focusMode: focusMode,
            verify: true
        )

        let finalState: Bool?
        if let axRef = element.axRef {
            if let num = AXInspector.readNumericValue(axRef) {
                finalState = (num != 0)
            } else if let str = AXInspector.readValueString(axRef) {
                finalState = (str == "1" || str.lowercased() == "true")
            } else {
                finalState = initial.map { !$0 }
            }
        } else {
            finalState = desiredChecked ?? initial.map { !$0 }
        }

        return (finalState, true, outcome.methodUsed)
    }

    public static func selectDropdown(
        element: StoredElement,
        option: String,
        focusMode: FocusMode
    ) async throws -> (selected: String, method: String) {
        _ = try await InputController.click(
            point: nil,
            element: element,
            ownerPID: element.ui.ownerPID,
            windowID: element.ui.windowID,
            method: "auto",
            focusMode: focusMode,
            verify: true
        )
        try? await Task.sleep(for: .milliseconds(160))

        if let pid = element.ui.ownerPID,
           let picked = try? AXInspector.triggerOpenMenuEntry(pid: pid, menuPath: [option])
        {
            return (picked, "ax_open_menu_press")
        }

        // Visual / popup fallback
        let scope: CaptureTargetScope
        if let wid = element.ui.windowID {
            scope = .window(id: wid)
        } else if let pid = element.ui.ownerPID {
            scope = .app(name: nil, bundleID: nil, pid: pid)
        } else {
            scope = .frontmostWindow
        }

        let obs = try await PerceptionEngine.observe(
            target: scope,
            includeImage: false,
            annotate: false,
            includePopups: true,
            maxElements: 220
        )
        let (_, matches) = await SnapshotStore.shared.findElements(
            query: option,
            role: nil,
            interactiveOnly: false,
            snapshotID: obs.snapshot.snapshotID,
            limit: 5
        )
        if let hit = matches.first(where: { $0.ui.id != element.ui.id }) ?? matches.first {
            let outcome = try await InputController.click(
                point: nil,
                element: hit,
                ownerPID: hit.ui.ownerPID ?? element.ui.ownerPID,
                windowID: hit.ui.windowID ?? element.ui.windowID,
                method: "auto",
                focusMode: focusMode,
                verify: true
            )
            return (hit.ui.label, outcome.methodUsed)
        }

        throw MacOSUseError.targetNotFound("Dropdown option '\(option)' not found after opening menu.")
    }

    public static func selectTab(
        element: StoredElement?,
        query: String?,
        target: CaptureTargetScope,
        focusMode: FocusMode
    ) async throws -> (label: String, method: String) {
        let chosen: StoredElement
        if let element {
            chosen = element
        } else if let query, !query.isEmpty {
            let obs = try await PerceptionEngine.observe(target: target, includeImage: false, annotate: false)
            let (_, tabMatches) = await SnapshotStore.shared.findElements(
                query: query,
                role: "tab",
                interactiveOnly: false,
                snapshotID: obs.snapshot.snapshotID,
                limit: 3
            )
            if let hit = tabMatches.first {
                chosen = hit
            } else {
                let (_, anyMatches) = await SnapshotStore.shared.findElements(
                    query: query,
                    role: nil,
                    interactiveOnly: true,
                    snapshotID: obs.snapshot.snapshotID,
                    limit: 3
                )
                guard let hit = anyMatches.first else {
                    throw MacOSUseError.targetNotFound("Tab '\(query)' not found.")
                }
                chosen = hit
            }
        } else {
            throw MacOSUseError.invalidArgument("select_tab requires element_id or query.")
        }

        let outcome = try await InputController.click(
            point: nil,
            element: chosen,
            ownerPID: chosen.ui.ownerPID,
            windowID: chosen.ui.windowID,
            method: "auto",
            focusMode: focusMode,
            verify: true
        )
        return (chosen.ui.label, outcome.methodUsed)
    }

    public static func selectTextRange(
        element: StoredElement,
        start: Int,
        length: Int
    ) throws -> String? {
        guard let axRef = element.axRef else {
            throw MacOSUseError.invalidArgument("select_text_range requires an Accessibility element reference.")
        }
        return AXInspector.setSelectedTextRange(axRef, start: start, length: length)
    }

    // MARK: - Helpers

    private static func chooseScrollAnchor(in snapshot: UISnapshot) -> CGPoint {
        let scrollContainers = snapshot.elements.filter {
            ["scrollarea", "table", "list", "outline"].contains($0.ui.role)
        }
        if let biggest = scrollContainers.max(by: { $0.ui.frame.area < $1.ui.frame.area }) {
            return biggest.ui.frame.center.cgPoint
        }
        return snapshot.transform.logicalBounds.center.cgPoint
    }

    private static func scrollDelta(direction: String, bounds: ScreenRect) -> (dx: Int, dy: Int) {
        let stepY = Int(min(420.0, max(180.0, bounds.height * 0.45)).rounded())
        let stepX = Int(min(320.0, max(140.0, bounds.width * 0.35)).rounded())
        switch direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "up":
            return (0, stepY)
        case "left":
            return (stepX, 0)
        case "right":
            return (-stepX, 0)
        default: // "down"
            return (0, -stepY)
        }
    }

    private static func layoutSignature(of snapshot: UISnapshot) -> String {
        snapshot.elements.prefix(28).map { el in
            "\(el.ui.label)@\(Int(el.ui.centerX)),\(Int(el.ui.centerY))"
        }.joined(separator: "|")
    }
}
