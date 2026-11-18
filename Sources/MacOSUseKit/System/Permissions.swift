import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

/// Inspects and optionally prompts macOS TCC permissions required for native computer use.
public enum PermissionsManager {
    public static func currentStatus(promptAccessibility: Bool = false) -> PermissionStatus {
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility: Bool
        if promptAccessibility {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            accessibility = AXIsProcessTrustedWithOptions(options)
        } else {
            accessibility = AXIsProcessTrusted()
        }
        let postEvent = CGPreflightPostEventAccess()
        let listenEvent = CGPreflightListenEventAccess()

        var notes: [String] = []
        if !screenRecording {
            notes.append("Screen Recording is disabled; run macos-use or grant Screen Recording in System Settings > Privacy & Security.")
        }
        if !accessibility {
            notes.append("Accessibility TCC is currently disabled (AXIsProcessTrusted=false); using Apple Silicon Vision + ScreenCaptureKit + Window Topology grounding. Run `macos-use doctor --prompt-ax` and grant Accessibility for full AXUIElement semantic trees and menu bar inspection.")
        }
        if !postEvent {
            notes.append("CGPreflightPostEventAccess is false; synthetic mouse/keyboard events may be blocked.")
        }

        return PermissionStatus(
            screenRecording: screenRecording,
            accessibility: accessibility,
            postEvent: postEvent,
            listenEvent: listenEvent,
            notes: notes
        )
    }

    @discardableResult
    public static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    public static func openSystemSettingsPrivacy(pane: String) -> Bool {
        let urlString: String
        switch pane.lowercased() {
        case "accessibility", "ax":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case "screen", "screenrecording", "screen_recording":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        default:
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }
        guard let url = URL(string: urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
