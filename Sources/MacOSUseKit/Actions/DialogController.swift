import AppKit
import Foundation

/// Inspects and operates native macOS sheets, NSOpenPanel/NSSavePanel file pickers, alerts, and system dialogs.
public enum DialogController {
    private static let helperProcessNames: Set<String> = [
        "coreservicesuiagent",
        "securityagent",
        "usernotificationcenter",
        "openandsavepanelservice"
    ]

    public static func inspectDialogs(pid: Int32? = nil) async throws -> [DialogInfo] {
        var targets: [(pid: Int32, name: String)] = []

        if let pid {
            let name = await MainActor.run {
                NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
            }
            targets.append((pid, name))
        } else if let front = await WindowManager.frontmostApp() {
            targets.append((front.pid, front.name))
        }

        let helperApps = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> (Int32, String)? in
                let lname = (app.localizedName ?? "").lowercased()
                let lbundle = (app.bundleIdentifier ?? "").lowercased()
                if helperProcessNames.contains(lname) || lbundle.contains("openandsavepanel") {
                    return (app.processIdentifier, app.localizedName ?? lbundle)
                }
                return nil
            }
        }
        for helper in helperApps where !targets.contains(where: { $0.pid == helper.0 }) {
            targets.append(helper)
        }

        let overlays = (try? await WindowManager.listOverlayWindows(forPID: pid)) ?? []
        var dialogs: [DialogInfo] = []

        for t in targets {
            var found = AXInspector.inspectAXDialogs(pid: t.pid, appName: t.name)
            for idx in found.indices {
                if found[idx].windowID == nil {
                    found[idx].windowID = overlays.first(where: { $0.ownerPID == t.pid })?.windowID
                }
            }
            dialogs.append(contentsOf: found)
        }

        // Also surface any non-empty overlay window not yet represented by an AXDialog
        for ov in overlays {
            let alreadyCovered = dialogs.contains { $0.ownerPID == ov.ownerPID && $0.windowID == ov.windowID }
            if !alreadyCovered && (!ov.title.isEmpty || helperProcessNames.contains(ov.appName.lowercased())) {
                dialogs.append(
                    DialogInfo(
                        dialogType: ov.appName.lowercased().contains("openandsavepanel") ? "file_open" : "system_dialog",
                        ownerPID: ov.ownerPID,
                        appName: ov.appName,
                        windowID: ov.windowID,
                        title: ov.title.isEmpty ? ov.appName : ov.title
                    )
                )
            }
        }

        return dialogs
    }

    public static func selectFile(
        path: String,
        pid: Int32? = nil,
        submit: Bool = true
    ) async throws -> [String: JSONValue] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacOSUseError.invalidArgument("select_file requires non-empty 'file_path'.")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath

        let hostPID: Int32
        if let pid {
            hostPID = pid
        } else if let front = await WindowManager.frontmostApp() {
            hostPID = front.pid
        } else {
            throw MacOSUseError.targetNotFound("No target or frontmost application found for file dialog.")
        }

        try await WindowManager.requireAppActive(pid: hostPID)
        guard let initial = AXInspector.focusedFilePanel(pid: hostPID) else {
            throw MacOSUseError.targetNotFound("No focused native file picker in the requested application.")
        }
        if initial.location == nil {
            try await InputController.pressKey(key: "g", modifiers: ["command", "shift"], focusMode: .foreground)
        }

        let deadline = ContinuousClock.now + .seconds(2)
        var location: AXElementRef?
        repeat {
            if let state = AXInspector.focusedFilePanel(pid: hostPID),
               CFEqual(state.panel.element, initial.panel.element), let field = state.location {
                location = field
                break
            }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < deadline

        guard let location, AXInspector.setValue(location, value: expanded),
              AXInspector.readValueString(location) == expanded else {
            throw MacOSUseError.inputFailed("Could not enter the path in the file picker's Go to Folder field.")
        }
        guard await WindowManager.frontmostApp()?.pid == hostPID,
              let current = AXInspector.focusedFilePanel(pid: hostPID)?.location,
              CFEqual(current.element, location.element) else {
            throw MacOSUseError.targetNotFound("The location field lost focus before confirmation.")
        }
        try await InputController.pressKey(key: "return", focusMode: .foreground)
        let selectionDeadline = ContinuousClock.now + .seconds(2)
        var submittedBy = "none"
        while true {
            if let state = AXInspector.focusedFilePanel(pid: hostPID),
               CFEqual(state.panel.element, initial.panel.element), state.location == nil,
               let button = state.submit {
                if submit {
                    guard AXInspector.performPress(button) else {
                        throw MacOSUseError.inputFailed("The file picker's default button could not be pressed.")
                    }
                    submittedBy = "ax_default_button"
                }
                break
            }
            guard ContinuousClock.now < selectionDeadline else {
                throw MacOSUseError.inputFailed("The file picker did not finish selecting the path.")
            }
            try await Task.sleep(for: .milliseconds(40))
        }

        let settle = await UIEventObserver.waitForSettle(
            pid: hostPID,
            maxWaitMs: 360,
            quietWindowMs: 80,
            checkVisual: false
        )

        return [
            "ok": .bool(true),
            "path": .string(expanded),
            "submitted": .bool(submit),
            "submitted_by": .string(submittedBy),
            "settled_ms": .int(settle.elapsedMs)
        ]
    }

    public static func clickDialogButton(
        button: String,
        pid: Int32? = nil
    ) async throws -> [String: JSONValue] {
        guard !button.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacOSUseError.invalidArgument("click_button requires non-empty 'button'.")
        }

        var candidatePIDs: [Int32] = []
        if let pid {
            candidatePIDs.append(pid)
        } else if let front = await WindowManager.frontmostApp() {
            candidatePIDs.append(front.pid)
        }

        let helperPIDs = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
                let lname = (app.localizedName ?? "").lowercased()
                let lbundle = (app.bundleIdentifier ?? "").lowercased()
                if helperProcessNames.contains(lname) || lbundle.contains("openandsavepanel") {
                    return app.processIdentifier
                }
                return nil
            }
        }
        for hp in helperPIDs where !candidatePIDs.contains(hp) {
            candidatePIDs.append(hp)
        }

        for candidate in candidatePIDs {
            let (ok, frame) = AXInspector.pressDialogButton(pid: candidate, button: button)
            if ok {
                let settle = await UIEventObserver.waitForSettle(pid: candidate, maxWaitMs: 250, quietWindowMs: 70, checkVisual: false)
                return [
                    "ok": .bool(true),
                    "button": .string(button),
                    "pid": .int(Int(candidate)),
                    "method": .string("ax_press"),
                    "settled_ms": .int(settle.elapsedMs)
                ]
            }
            if let frame {
                _ = try await InputController.click(
                    point: frame.center.cgPoint,
                    element: nil,
                    ownerPID: candidate,
                    method: "cgevent",
                    focusMode: .foreground,
                    verify: true
                )
                return [
                    "ok": .bool(true),
                    "button": .string(button),
                    "pid": .int(Int(candidate)),
                    "method": .string("cgevent_fallback")
                ]
            }
        }

        // Visual/hybrid fallback on frontmost or specified app
        if let firstPID = candidatePIDs.first {
            let obs = try await PerceptionEngine.observe(
                target: .app(name: nil, bundleID: nil, pid: firstPID),
                includeImage: false,
                includePopups: true
            )
            let (_, matches) = await SnapshotStore.shared.findElements(
                query: button,
                role: nil,
                interactiveOnly: true,
                snapshotID: obs.snapshot.snapshotID,
                limit: 3
            )
            if let hit = matches.first {
                let outcome = try await InputController.click(
                    point: nil,
                    element: hit,
                    ownerPID: hit.ui.ownerPID ?? firstPID,
                    windowID: hit.ui.windowID,
                    method: "auto",
                    focusMode: .foreground,
                    verify: true
                )
                return [
                    "ok": .bool(true),
                    "button": .string(hit.ui.label),
                    "pid": .int(Int(firstPID)),
                    "method": .string(outcome.methodUsed)
                ]
            }
        }

        throw MacOSUseError.targetNotFound("Dialog button '\(button)' not found.")
    }
}
