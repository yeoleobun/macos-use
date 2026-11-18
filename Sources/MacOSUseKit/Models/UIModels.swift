@preconcurrency import ApplicationServices
import Foundation

/// Sendable wrapper around an `AXUIElement` handle cached inside a snapshot.
public struct AXElementRef: @unchecked Sendable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }
}

/// Origin of a discovered UI element.
public enum UIElementSource: String, Codable, Sendable {
    case ax
    case visionButton = "vision_button"
    case visionText = "vision_text"
    case visionControl = "vision_control"
    case windowChrome = "window_chrome"
    case axVision = "ax_vision"
    case axIconML = "ax_icon_ml"
    case visionIconML = "vision_icon_ml"
}

/// Normalized, model-friendly representation of a macOS UI element in Global Quartz Logical Points.
public struct UIElement: Codable, Sendable, Equatable {
    public var id: String
    public var index: Int
    public var role: String
    public var rawRole: String
    public var label: String
    public var value: String?
    public var enabled: Bool
    public var focused: Bool
    public var selected: Bool
    public var isInteractive: Bool
    public var actions: [String]
    public var source: UIElementSource
    public var confidence: Double
    public var frame: ScreenRect
    public var centerX: Double
    public var centerY: Double
    public var ownerPID: Int32?
    public var windowID: UInt32?

    public init(
        id: String,
        index: Int,
        role: String,
        rawRole: String,
        label: String,
        value: String? = nil,
        enabled: Bool = true,
        focused: Bool = false,
        selected: Bool = false,
        isInteractive: Bool = true,
        actions: [String] = [],
        source: UIElementSource,
        confidence: Double = 1.0,
        frame: ScreenRect,
        ownerPID: Int32? = nil,
        windowID: UInt32? = nil
    ) {
        self.id = id
        self.index = index
        self.role = role
        self.rawRole = rawRole
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.isInteractive = isInteractive
        self.actions = actions
        self.source = source
        self.confidence = confidence
        self.frame = frame
        self.centerX = (frame.centerX * 10.0).rounded() / 10.0
        self.centerY = (frame.centerY * 10.0).rounded() / 10.0
        self.ownerPID = ownerPID
        self.windowID = windowID
    }
}

/// Cached UI element pairing serializable metadata with an optional live `AXUIElement`.
public struct StoredElement: Sendable {
    public var ui: UIElement
    public var axRef: AXElementRef?

    public init(ui: UIElement, axRef: AXElementRef? = nil) {
        self.ui = ui
        self.axRef = axRef
    }
}

/// Snapshot of a perceived screen/window state stored in `SnapshotStore`.
public struct UISnapshot: Sendable {
    public let snapshotID: String
    public let createdAt: Date
    public let scopeDescription: String
    public let ownerPID: Int32?
    public let windowID: UInt32?
    public let transform: CaptureTransform
    public let axTrusted: Bool
    public let elements: [StoredElement]

    public init(
        snapshotID: String,
        createdAt: Date = Date(),
        scopeDescription: String,
        ownerPID: Int32?,
        windowID: UInt32?,
        transform: CaptureTransform,
        axTrusted: Bool,
        elements: [StoredElement]
    ) {
        self.snapshotID = snapshotID
        self.createdAt = createdAt
        self.scopeDescription = scopeDescription
        self.ownerPID = ownerPID
        self.windowID = windowID
        self.transform = transform
        self.axTrusted = axTrusted
        self.elements = elements
    }
}

public struct DisplayInfo: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var isMain: Bool
    public var frame: ScreenRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scaleFactor: Double

    public init(
        displayID: UInt32,
        isMain: Bool,
        frame: ScreenRect,
        pixelWidth: Int,
        pixelHeight: Int,
        scaleFactor: Double
    ) {
        self.displayID = displayID
        self.isMain = isMain
        self.frame = frame
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scaleFactor = scaleFactor
    }
}

public struct AppInfo: Codable, Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var isActive: Bool
    public var isHidden: Bool
    public var activationPolicy: String

    public init(
        pid: Int32,
        name: String,
        bundleID: String?,
        isActive: Bool,
        isHidden: Bool,
        activationPolicy: String
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.isActive = isActive
        self.isHidden = isHidden
        self.activationPolicy = activationPolicy
    }
}

public struct WindowInfo: Codable, Sendable, Equatable {
    public var windowID: UInt32
    public var ownerPID: Int32
    public var appName: String
    public var bundleID: String?
    public var title: String
    public var frame: ScreenRect
    public var layer: Int
    public var isOnScreen: Bool
    public var isFrontmostApp: Bool
    public var zOrder: Int

    public init(
        windowID: UInt32,
        ownerPID: Int32,
        appName: String,
        bundleID: String?,
        title: String,
        frame: ScreenRect,
        layer: Int,
        isOnScreen: Bool,
        isFrontmostApp: Bool,
        zOrder: Int
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.isFrontmostApp = isFrontmostApp
        self.zOrder = zOrder
    }
}

public struct PermissionStatus: Codable, Sendable, Equatable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public var postEvent: Bool
    public var listenEvent: Bool
    public var notes: [String]

    public init(
        screenRecording: Bool,
        accessibility: Bool,
        postEvent: Bool,
        listenEvent: Bool,
        notes: [String] = []
    ) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.postEvent = postEvent
        self.listenEvent = listenEvent
        self.notes = notes
    }
}

public struct SystemStatusInfo: Codable, Sendable, Equatable {
    public var osVersion: String
    public var architecture: String
    public var hostName: String
    public var permissions: PermissionStatus
    public var displays: [DisplayInfo]
    public var frontmostApp: AppInfo?
    public var serverVersion: String

    public init(
        osVersion: String,
        architecture: String,
        hostName: String,
        permissions: PermissionStatus,
        displays: [DisplayInfo],
        frontmostApp: AppInfo?,
        serverVersion: String
    ) {
        self.osVersion = osVersion
        self.architecture = architecture
        self.hostName = hostName
        self.permissions = permissions
        self.displays = displays
        self.frontmostApp = frontmostApp
        self.serverVersion = serverVersion
    }
}

public struct MenuItemInfo: Codable, Sendable, Equatable {
    public var path: [String]
    public var title: String
    public var shortcut: String?
    public var enabled: Bool

    public init(path: [String], title: String, shortcut: String? = nil, enabled: Bool = true) {
        self.path = path
        self.title = title
        self.shortcut = shortcut
        self.enabled = enabled
    }
}

public struct SettleResult: Codable, Sendable, Equatable {
    public var settled: Bool
    public var elapsedMs: Int
    public var axNotifications: [String]
    public var visualDeltaScore: Double

    public init(settled: Bool, elapsedMs: Int, axNotifications: [String] = [], visualDeltaScore: Double = 0.0) {
        self.settled = settled
        self.elapsedMs = elapsedMs
        self.axNotifications = axNotifications
        self.visualDeltaScore = visualDeltaScore
    }
}

public struct ActionVerification: Codable, Sendable, Equatable {
    public var verified: Bool
    public var uiChanged: Bool
    public var escalated: Bool
    public var attempts: [String]
    public var signals: [String]
    public var visualDelta: Double
    public var elapsedMs: Int

    public init(
        verified: Bool,
        uiChanged: Bool,
        escalated: Bool,
        attempts: [String],
        signals: [String],
        visualDelta: Double,
        elapsedMs: Int
    ) {
        self.verified = verified
        self.uiChanged = uiChanged
        self.escalated = escalated
        self.attempts = attempts
        self.signals = signals
        self.visualDelta = visualDelta
        self.elapsedMs = elapsedMs
    }
}

public struct DialogInfo: Codable, Sendable, Equatable {
    public var dialogType: String
    public var ownerPID: Int32
    public var appName: String
    public var windowID: UInt32?
    public var title: String
    public var message: String?
    public var buttons: [String]
    public var defaultButton: String?
    public var cancelButton: String?
    public var textFields: [String]

    public init(
        dialogType: String,
        ownerPID: Int32,
        appName: String,
        windowID: UInt32? = nil,
        title: String,
        message: String? = nil,
        buttons: [String] = [],
        defaultButton: String? = nil,
        cancelButton: String? = nil,
        textFields: [String] = []
    ) {
        self.dialogType = dialogType
        self.ownerPID = ownerPID
        self.appName = appName
        self.windowID = windowID
        self.title = title
        self.message = message
        self.buttons = buttons
        self.defaultButton = defaultButton
        self.cancelButton = cancelButton
        self.textFields = textFields
    }
}

public struct VirtualDisplayInfo: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var name: String
    public var width: Int
    public var height: Int
    public var hiDPI: Bool
    public var frame: ScreenRect?

    public init(
        displayID: UInt32,
        name: String,
        width: Int,
        height: Int,
        hiDPI: Bool,
        frame: ScreenRect? = nil
    ) {
        self.displayID = displayID
        self.name = name
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
        self.frame = frame
    }
}

public struct SafetyPolicyConfig: Codable, Sendable, Equatable {
    public var mode: String
    public var maxActionsPerMinute: Int
    public var destructivePatternsCount: Int

    public init(mode: String, maxActionsPerMinute: Int, destructivePatternsCount: Int) {
        self.mode = mode
        self.maxActionsPerMinute = maxActionsPerMinute
        self.destructivePatternsCount = destructivePatternsCount
    }
}

public struct TrajectoryEvent: Codable, Sendable, Equatable {
    public var seq: Int
    public var timestamp: String
    public var tool: String
    public var targetSummary: String
    public var methodUsed: String?
    public var uiChanged: Bool?
    public var escalated: Bool?
    public var elapsedMs: Int
    public var snapshotID: String?
    public var framePath: String?
    public var error: String?

    public init(
        seq: Int,
        timestamp: String,
        tool: String,
        targetSummary: String,
        methodUsed: String? = nil,
        uiChanged: Bool? = nil,
        escalated: Bool? = nil,
        elapsedMs: Int,
        snapshotID: String? = nil,
        framePath: String? = nil,
        error: String? = nil
    ) {
        self.seq = seq
        self.timestamp = timestamp
        self.tool = tool
        self.targetSummary = targetSummary
        self.methodUsed = methodUsed
        self.uiChanged = uiChanged
        self.escalated = escalated
        self.elapsedMs = elapsedMs
        self.snapshotID = snapshotID
        self.framePath = framePath
        self.error = error
    }
}
