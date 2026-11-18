import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Discovers displays, running GUI apps, front-to-back windows, and manages app lifecycle and clipboard.
public enum WindowManager {
    public static let serverVersion = "2.0.0"

    // MARK: - System Status & Displays

    public static func listDisplays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()

        return content.displays.map { scDisplay in
            let id = scDisplay.displayID
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelW = mode?.pixelWidth ?? Int(bounds.width)
            let pixelH = mode?.pixelHeight ?? Int(bounds.height)
            let logicalW = Double(mode?.width ?? Int(bounds.width))
            let scale = logicalW > 0 ? Double(pixelW) / logicalW : 1.0
            return DisplayInfo(
                displayID: id,
                isMain: id == mainID,
                frame: ScreenRect(cgRect: bounds),
                pixelWidth: pixelW,
                pixelHeight: pixelH,
                scaleFactor: (scale * 100.0).rounded() / 100.0
            )
        }
        .sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.displayID < rhs.displayID
        }
    }

    @MainActor
    public static func listApps(includeBackground: Bool = false) -> [AppInfo] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                if includeBackground { return true }
                return app.activationPolicy == .regular
            }
            .map { app in
                AppInfo(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)",
                    bundleID: app.bundleIdentifier,
                    isActive: app.processIdentifier == frontPID || app.isActive,
                    isHidden: app.isHidden,
                    activationPolicy: policyString(app.activationPolicy)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    @MainActor
    public static func frontmostApp() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppInfo(
            pid: app.processIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "PID \(app.processIdentifier)",
            bundleID: app.bundleIdentifier,
            isActive: true,
            isHidden: app.isHidden,
            activationPolicy: policyString(app.activationPolicy)
        )
    }

    public static func listWindows(
        appFilter: String? = nil,
        includeSystemLayers: Bool = false,
        onScreenOnly: Bool = true
    ) async throws -> [WindowInfo] {
        let frontPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        let appBundles = await MainActor.run {
            Dictionary(
                uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier) }
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly)
        var scByID: [UInt32: (title: String, bundleID: String?, appName: String?, frame: CGRect, onScreen: Bool, layer: Int)] = [:]
        for w in content.windows {
            scByID[w.windowID] = (
                title: w.title ?? "",
                bundleID: w.owningApplication?.bundleIdentifier,
                appName: w.owningApplication?.applicationName,
                frame: w.frame,
                onScreen: w.isOnScreen,
                layer: w.windowLayer
            )
        }

        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.excludeDesktopElements]
        let rawList = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []

        var result: [WindowInfo] = []
        var seenIDs = Set<UInt32>()

        for (zIdx, dict) in rawList.enumerated() {
            guard let num = dict[kCGWindowNumber as String] as? NSNumber,
                  let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber
            else { continue }

            let wid = num.uint32Value
            let pid = pidNum.int32Value
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let cgOnScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary
            let cgRect = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero

            let scMeta = scByID[wid]
            let frame = ScreenRect(cgRect: scMeta?.frame ?? cgRect)
            if !includeSystemLayers {
                if layer != 0 { continue }
                if frame.width < 40 || frame.height < 40 { continue }
            } else {
                if layer < 0 || layer > 2000 { continue }
                let minW: Double = (layer == 0) ? 40.0 : 24.0
                let minH: Double = (layer == 0) ? 40.0 : 20.0
                if frame.width < minW || frame.height < minH { continue }
            }

            let ownerName = (dict[kCGWindowOwnerName as String] as? String)
                ?? scMeta?.appName
                ?? "PID \(pid)"
            let bundleID = scMeta?.bundleID ?? (appBundles[pid] ?? nil)
            let cgTitle = dict[kCGWindowName as String] as? String ?? ""
            let title = !(scMeta?.title.isEmpty ?? true) ? (scMeta?.title ?? "") : cgTitle

            if !includeSystemLayers {
                let loweredOwner = ownerName.lowercased()
                if loweredOwner == "window server" || loweredOwner == "dock" || loweredOwner == "control center" {
                    continue
                }
            }

            if let filter = appFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
                let f = filter.lowercased()
                let matchesName = ownerName.lowercased().contains(f)
                let matchesBundle = (bundleID?.lowercased().contains(f) ?? false)
                let matchesTitle = title.lowercased().contains(f)
                if !matchesName && !matchesBundle && !matchesTitle { continue }
            }

            seenIDs.insert(wid)
            result.append(
                WindowInfo(
                    windowID: wid,
                    ownerPID: pid,
                    appName: ownerName,
                    bundleID: bundleID,
                    title: title,
                    frame: frame,
                    layer: layer,
                    isOnScreen: scMeta?.onScreen ?? cgOnScreen,
                    isFrontmostApp: pid == frontPID,
                    zOrder: zIdx
                )
            )
        }

        // Include any SCWindow missing from CGWindowList (e.g. offscreen when onScreenOnly == false)
        if !onScreenOnly {
            for w in content.windows where !seenIDs.contains(w.windowID) {
                let pid = w.owningApplication?.processID ?? 0
                let layer = w.windowLayer
                if !includeSystemLayers && layer != 0 { continue }
                let frame = ScreenRect(cgRect: w.frame)
                if frame.width < 40 || frame.height < 40 { continue }
                let ownerName = w.owningApplication?.applicationName ?? "PID \(pid)"
                let bundleID = w.owningApplication?.bundleIdentifier ?? (appBundles[pid] ?? nil)
                let title = w.title ?? ""
                if let filter = appFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
                    let f = filter.lowercased()
                    if !ownerName.lowercased().contains(f)
                        && !(bundleID?.lowercased().contains(f) ?? false)
                        && !title.lowercased().contains(f)
                    {
                        continue
                    }
                }
                result.append(
                    WindowInfo(
                        windowID: w.windowID,
                        ownerPID: pid,
                        appName: ownerName,
                        bundleID: bundleID,
                        title: title,
                        frame: frame,
                        layer: layer,
                        isOnScreen: w.isOnScreen,
                        isFrontmostApp: pid == frontPID,
                        zOrder: result.count + 1000
                    )
                )
            }
        }

        return result
    }

    public static func listOverlayWindows(forPID pid: Int32?) async throws -> [WindowInfo] {
        let systemProcessNames: Set<String> = [
            "coreservicesuiagent",
            "securityagent",
            "usernotificationcenter",
            "openandsavepanelservice"
        ]
        let frontPID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        let appBundles = await MainActor.run {
            Dictionary(
                uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier) }
            )
        }
        let rawList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var overlays: [WindowInfo] = []

        for (zIdx, dict) in rawList.enumerated() {
            guard let num = dict[kCGWindowNumber as String] as? NSNumber,
                  let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber
            else { continue }
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer > 0 && layer <= 2000 else { continue }

            let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary
            let cgRect = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            let frame = ScreenRect(cgRect: cgRect)
            guard frame.width >= 24 && frame.height >= 20 else { continue }

            let ownerPID = pidNum.int32Value
            let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? "PID \(ownerPID)"
            let bundleID = appBundles[ownerPID] ?? nil
            let title = dict[kCGWindowName as String] as? String ?? ""
            let isOnScreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true

            let loweredApp = ownerName.lowercased()
            let loweredBundle = (bundleID ?? "").lowercased()
            let isSystemDialogHelper = systemProcessNames.contains(loweredApp)
                || loweredBundle.contains("openandsavepanel")
                || loweredBundle.contains("coreservicesuiagent")
                || loweredBundle.contains("securityagent")
                || loweredBundle.contains("usernotificationcenter")

            if !isSystemDialogHelper, let pid, ownerPID != pid {
                continue
            }

            overlays.append(
                WindowInfo(
                    windowID: num.uint32Value,
                    ownerPID: ownerPID,
                    appName: ownerName,
                    bundleID: bundleID,
                    title: title,
                    frame: frame,
                    layer: layer,
                    isOnScreen: isOnScreen,
                    isFrontmostApp: ownerPID == frontPID,
                    zOrder: zIdx
                )
            )
        }
        return overlays
    }

    public static func systemStatus(promptAccessibility: Bool = false) async throws -> SystemStatusInfo {
        let perms = PermissionsManager.currentStatus(promptAccessibility: promptAccessibility)
        let displays = try await listDisplays()
        let front = await frontmostApp()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let host = ProcessInfo.processInfo.hostName

        return SystemStatusInfo(
            osVersion: "macOS \(os)",
            architecture: "arm64",
            hostName: host,
            permissions: perms,
            displays: displays,
            frontmostApp: front,
            serverVersion: serverVersion
        )
    }

    // MARK: - App Lifecycle

    @MainActor
    public static func findRunningApp(
        pid: Int32? = nil,
        appName: String? = nil,
        bundleID: String? = nil
    ) -> NSRunningApplication? {
        if let pid {
            return NSRunningApplication(processIdentifier: pid)
        }
        let apps = NSWorkspace.shared.runningApplications
        if let bundleID, !bundleID.isEmpty {
            if let exact = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                return exact
            }
        }
        if let appName, !appName.isEmpty {
            let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = apps.first(where: { ($0.localizedName ?? "").caseInsensitiveCompare(trimmed) == .orderedSame }) {
                return exact
            }
            if let partial = apps.first(where: {
                ($0.localizedName ?? "").localizedCaseInsensitiveContains(trimmed)
                    || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(trimmed)
            }) {
                return partial
            }
        }
        return nil
    }

    @MainActor
    public static func ensureAppActive(pid: Int32) async {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !app.isHidden {
            return
        }
        app.unhide()
        _ = app.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(150))
    }

    @MainActor
    public static func unhideAppIfHidden(pid: Int32) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), app.isHidden else {
            return false
        }
        _ = app.unhide()
        try? await Task.sleep(for: .milliseconds(120))
        return true
    }

    @MainActor
    public static func requireAppActive(pid: Int32) async throws {
        await ensureAppActive(pid: pid)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw MacOSUseError.targetNotFound("Target application is no longer active.")
        }
    }

    public static func hasStandardWindow(pid: Int32) -> Bool {
        let rawList = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return rawList.contains { dict in
            guard let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber,
                  pidNum.int32Value == pid
            else { return false }
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { return false }
            let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary
            let cgRect = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return cgRect.width >= 40 && cgRect.height >= 40
        }
    }

    @MainActor
    public static func launchApp(
        appName: String?,
        bundleID: String?,
        background: Bool = false,
        arguments: [String] = [],
        waitReadyMs: Int = 4000
    ) async throws -> AppInfo {
        if let running = findRunningApp(appName: appName, bundleID: bundleID) {
            if running.isHidden {
                _ = running.unhide()
            }
            if !background {
                _ = running.activate(options: [.activateAllWindows])
                try? await Task.sleep(for: .milliseconds(160))
            } else if running.isHidden {
                try? await Task.sleep(for: .milliseconds(120))
            }
            if !arguments.isEmpty, let bundleURL = running.bundleURL {
                if let execURL = Bundle(url: bundleURL)?.executableURL {
                    let proc = Process()
                    proc.executableURL = execURL
                    proc.arguments = arguments
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    if (try? proc.run()) != nil {
                        for _ in 0..<130 {
                            if !proc.isRunning { break }
                            try? await Task.sleep(for: .milliseconds(15))
                        }
                    }
                } else {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = !background
                    cfg.arguments = arguments
                    _ = try? await NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg)
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            return AppInfo(
                pid: running.processIdentifier,
                name: running.localizedName ?? appName ?? "App",
                bundleID: running.bundleIdentifier,
                isActive: running.isActive,
                isHidden: running.isHidden,
                activationPolicy: policyString(running.activationPolicy)
            )
        }

        let appURL = resolveApplicationURL(appName: appName, bundleID: bundleID)
        guard let url = appURL else {
            let desc = bundleID ?? appName ?? "<unspecified>"
            throw MacOSUseError.targetNotFound("Could not find macOS application '\(desc)'")
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = !background
        if !arguments.isEmpty {
            config.arguments = arguments
        }
        let launched = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        let maxWait = min(max(waitReadyMs, 200), 15000)
        let deadline = ContinuousClock.now + .milliseconds(maxWait)
        while ContinuousClock.now < deadline {
            if launched.isFinishedLaunching && hasStandardWindow(pid: launched.processIdentifier) {
                break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        return AppInfo(
            pid: launched.processIdentifier,
            name: launched.localizedName ?? appName ?? url.deletingPathExtension().lastPathComponent,
            bundleID: launched.bundleIdentifier,
            isActive: launched.isActive,
            isHidden: launched.isHidden,
            activationPolicy: policyString(launched.activationPolicy)
        )
    }

    @MainActor
    public static func activateApp(pid: Int32?, appName: String?, bundleID: String?) async throws -> AppInfo {
        guard let app = findRunningApp(pid: pid, appName: appName, bundleID: bundleID) else {
            return try await launchApp(appName: appName, bundleID: bundleID)
        }
        app.unhide()
        let ok = app.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(160))
        return AppInfo(
            pid: app.processIdentifier,
            name: app.localizedName ?? appName ?? "App",
            bundleID: app.bundleIdentifier,
            isActive: ok || app.isActive,
            isHidden: app.isHidden,
            activationPolicy: policyString(app.activationPolicy)
        )
    }

    @MainActor
    public static func hideApp(pid: Int32?, appName: String?, bundleID: String?) throws -> AppInfo {
        guard let app = findRunningApp(pid: pid, appName: appName, bundleID: bundleID) else {
            throw MacOSUseError.targetNotFound("Running app not found to hide")
        }
        _ = app.hide()
        return AppInfo(
            pid: app.processIdentifier,
            name: app.localizedName ?? "App",
            bundleID: app.bundleIdentifier,
            isActive: app.isActive,
            isHidden: true,
            activationPolicy: policyString(app.activationPolicy)
        )
    }

    @MainActor
    public static func quitApp(pid: Int32?, appName: String?, bundleID: String?, force: Bool = false) async throws -> Bool {
        guard let app = findRunningApp(pid: pid, appName: appName, bundleID: bundleID) else {
            return false
        }
        let ok = force ? app.forceTerminate() : app.terminate()
        if ok {
            for _ in 0..<20 {
                if app.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        return ok
    }

    @MainActor
    public static func openURL(_ urlString: String) throws -> Bool {
        guard let url = URL(string: urlString) else {
            throw MacOSUseError.invalidArgument("Invalid URL: \(urlString)")
        }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private static func resolveApplicationURL(appName: String?, bundleID: String?) -> URL? {
        if let bundleID, !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            return url
        }
        guard let rawName = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            return nil
        }

        if rawName.hasPrefix("/") && FileManager.default.fileExists(atPath: rawName) {
            return URL(fileURLWithPath: rawName)
        }

        let appFileName = rawName.hasSuffix(".app") ? rawName : "\(rawName).app"
        let searchRoots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        for root in searchRoots {
            let candidate = "\(root)/\(appFileName)"
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        // Case-insensitive directory scan across standard app folders
        let lowerTarget = appFileName.lowercased()
        let bareLower = rawName.lowercased()
        for root in searchRoots {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            if let match = items.first(where: { item in
                let lower = item.lowercased()
                return lower == lowerTarget || lower.hasPrefix(bareLower)
            }) {
                return URL(fileURLWithPath: "\(root)/\(match)")
            }
        }

        // Fallback common bundle IDs for built-in or popular macOS apps
        let commonAliases: [String: String] = [
            "calculator": "com.apple.calculator",
            "stocks": "com.apple.stocks",
            "notes": "com.apple.Notes",
            "safari": "com.apple.Safari",
            "finder": "com.apple.finder",
            "terminal": "com.apple.Terminal",
            "textedit": "com.apple.TextEdit",
            "system settings": "com.apple.systempreferences",
            "settings": "com.apple.systempreferences",
            "activity monitor": "com.apple.ActivityMonitor",
            "linphone": "com.belledonnecommunications.linphone"
        ]
        if let mappedID = commonAliases[bareLower],
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mappedID)
        {
            return url
        }

        // Spotlight fallback for apps installed outside standard /Applications roots
        let cleanTarget = appFileName.replacingOccurrences(of: "'", with: "")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = ["kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == '\(cleanTarget)'c"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        if (try? proc.run()) != nil {
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8) {
                for line in out.split(whereSeparator: \.isNewline) {
                    let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                        return URL(fileURLWithPath: path)
                    }
                }
            }
        }

        return nil
    }

    private static func policyString(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }
}

/// Thread-safe general pasteboard access.
public enum ClipboardManager {
    @MainActor
    public static func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    @MainActor
    public static func writeText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @MainActor
    public static func withTemporaryText(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        perform: @MainActor () async throws -> Void
    ) async throws {
        let initialCount = pasteboard.changeCount
        let items = try (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else {
                    throw MacOSUseError.inputFailed("Unable to preserve clipboard representation \(type.rawValue).")
                }
            }
            return copy
        }
        guard pasteboard.changeCount == initialCount else {
            throw MacOSUseError.inputFailed("The clipboard changed while preparing the paste.")
        }
        let ownedCount = pasteboard.clearContents()
        defer {
            if pasteboard.changeCount == ownedCount {
                pasteboard.clearContents()
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }
        }
        guard pasteboard.setString(text, forType: .string) else {
            throw MacOSUseError.inputFailed("Unable to write temporary clipboard text.")
        }
        try await perform()
    }

    @MainActor
    public static func clear() {
        NSPasteboard.general.clearContents()
    }
}
