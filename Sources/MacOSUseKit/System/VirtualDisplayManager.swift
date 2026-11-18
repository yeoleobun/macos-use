import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

/// Manages off-screen macOS virtual displays (`CGVirtualDisplay`) via the native CoreGraphics Objective-C runtime bridge.
@MainActor
public final class VirtualDisplayManager {
    public static let shared = VirtualDisplayManager()

    private struct ActiveDisplay {
        let info: VirtualDisplayInfo
        let object: AnyObject
    }

    private var activeDisplays: [UInt32: ActiveDisplay] = [:]

    private init() {}

    public func isSupported() -> Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
    }

    /// Tests descriptor/mode/settings allocation and ARC deallocation without attaching a live display to WindowServer.
    public func testDescriptorAllocation() -> Bool {
        guard isSupported() else { return false }
        weak var weakDesc: AnyObject?
        weak var weakMode: AnyObject?

        autoreleasepool {
            guard let built = buildDescriptorAndSettings(
                name: "macos-use VerificationProbe",
                width: 1920,
                height: 1080,
                hiDPI: true,
                serialNum: 99
            ) else {
                return
            }
            weakDesc = built.descriptor
            weakMode = built.mode
        }
        return weakDesc == nil && weakMode == nil
    }

    public func createDisplay(
        name: String = "macos-use Sandbox",
        width: Int = 1920,
        height: Int = 1080,
        hiDPI: Bool = true
    ) async throws -> VirtualDisplayInfo {
        guard isSupported() else {
            throw MacOSUseError.appOperationFailed("CGVirtualDisplay is unavailable on this macOS host.")
        }
        guard let displayCls = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else {
            throw MacOSUseError.appOperationFailed("Failed to resolve CGVirtualDisplay class.")
        }

        let clampedW = max(800, min(width, 3840))
        let clampedH = max(600, min(height, 2160))
        let serial = UInt32(activeDisplays.count + 1)

        var createdObj: AnyObject?
        var createdID: UInt32 = 0

        autoreleasepool {
            guard let built = buildDescriptorAndSettings(
                name: name,
                width: clampedW,
                height: clampedH,
                hiDPI: hiDPI,
                serialNum: serial
            ) else {
                return
            }

            let allocSel = NSSelectorFromString("alloc")
            let initSel = NSSelectorFromString("initWithDescriptor:")
            guard let initMethod = class_getInstanceMethod(displayCls, initSel),
                  let allocRes = displayCls.perform(allocSel)
            else {
                return
            }
            typealias InitDisplayFn = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> Unmanaged<AnyObject>?
            let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitDisplayFn.self)
            guard let display = initFn(allocRes.toOpaque(), initSel, built.descriptor)?.takeRetainedValue() else {
                return
            }

            let applySel = NSSelectorFromString("applySettings:")
            if let applyMethod = class_getInstanceMethod(displayCls, applySel) {
                typealias ApplySettingsFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
                let applyFn = unsafeBitCast(method_getImplementation(applyMethod), to: ApplySettingsFn.self)
                _ = applyFn(display, applySel, built.settings)
            }

            if let idNum = (display as? NSObject)?.value(forKey: "displayID") as? NSNumber {
                createdID = idNum.uint32Value
            } else {
                let idSel = NSSelectorFromString("displayID")
                if let idMethod = class_getInstanceMethod(displayCls, idSel) {
                    typealias GetIDFn = @convention(c) (AnyObject, Selector) -> UInt32
                    let idFn = unsafeBitCast(method_getImplementation(idMethod), to: GetIDFn.self)
                    createdID = idFn(display, idSel)
                }
            }
            createdObj = display
        }

        guard let displayObj = createdObj, createdID != 0 else {
            throw MacOSUseError.appOperationFailed("Failed to initialize CGVirtualDisplay.")
        }

        try? await Task.sleep(for: .milliseconds(350))
        let cgBounds = CGDisplayBounds(createdID)
        let frame = cgBounds.width > 0 ? ScreenRect(cgRect: cgBounds) : nil
        let info = VirtualDisplayInfo(
            displayID: createdID,
            name: name,
            width: clampedW,
            height: clampedH,
            hiDPI: hiDPI,
            frame: frame
        )
        activeDisplays[createdID] = ActiveDisplay(info: info, object: displayObj)
        return info
    }

    public func listVirtualDisplays() -> [VirtualDisplayInfo] {
        var list: [VirtualDisplayInfo] = []
        for (did, entry) in activeDisplays {
            let bounds = CGDisplayBounds(did)
            var updated = entry.info
            if bounds.width > 0 {
                updated.frame = ScreenRect(cgRect: bounds)
            }
            list.append(updated)
        }
        return list.sorted { $0.displayID < $1.displayID }
    }

    public func moveWindowToDisplay(
        windowID: UInt32?,
        pid: Int32?,
        appName: String?,
        bundleID: String?,
        displayID: UInt32?
    ) async throws -> ScreenRect {
        let displays = try await WindowManager.listDisplays()
        let targetDisplay: DisplayInfo?
        if let displayID {
            targetDisplay = displays.first(where: { $0.displayID == displayID })
        } else if let firstVirtual = activeDisplays.keys.sorted().first {
            targetDisplay = displays.first(where: { $0.displayID == firstVirtual })
        } else {
            targetDisplay = nil
        }

        guard let dest = targetDisplay else {
            throw MacOSUseError.targetNotFound(
                "Target display not found. Create a virtual display first or pass a valid display_id."
            )
        }

        var resolvedWin: WindowInfo?
        let allWindows = try await WindowManager.listWindows(includeSystemLayers: false, onScreenOnly: false)
        if let windowID {
            resolvedWin = allWindows.first(where: { $0.windowID == windowID })
        } else if let pid {
            resolvedWin = allWindows.first(where: { $0.ownerPID == pid })
        } else if appName != nil || bundleID != nil {
            let running = WindowManager.findRunningApp(pid: pid, appName: appName, bundleID: bundleID)
            if let rpid = running?.processIdentifier {
                resolvedWin = allWindows.first(where: { $0.ownerPID == rpid })
            }
        } else {
            resolvedWin = allWindows.first(where: { $0.isFrontmostApp })
        }

        guard let targetPID = pid ?? resolvedWin?.ownerPID else {
            throw MacOSUseError.targetNotFound("No target window/app found to move to display \(dest.displayID).")
        }

        let targetOrigin = CGPoint(x: dest.frame.x + 40.0, y: dest.frame.y + 40.0)
        guard let movedRect = AXInspector.moveWindowPosition(
            pid: targetPID,
            windowFrame: resolvedWin?.frame,
            to: targetOrigin
        ) else {
            throw MacOSUseError.appOperationFailed(
                "Failed to reposition window for PID \(targetPID) onto display \(dest.displayID)."
            )
        }
        return movedRect
    }

    @discardableResult
    public func destroyDisplay(displayID: UInt32? = nil) -> Int {
        var removed = 0
        autoreleasepool {
            if let displayID {
                if activeDisplays.removeValue(forKey: displayID) != nil {
                    removed = 1
                }
            } else {
                removed = activeDisplays.count
                activeDisplays.removeAll()
            }
        }
        return removed
    }

    // MARK: - Private Runtime Bridge

    private func buildDescriptorAndSettings(
        name: String,
        width: Int,
        height: Int,
        hiDPI: Bool,
        serialNum: UInt32
    ) -> (descriptor: AnyObject, mode: AnyObject, settings: AnyObject)? {
        guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let modeCls = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settingsCls = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
        else {
            return nil
        }

        let pixelW = hiDPI ? width * 2 : width
        let pixelH = hiDPI ? height * 2 : height

        let desc = descCls.init()
        desc.setValue(name, forKey: "name")
        desc.setValue(NSNumber(value: pixelW), forKey: "maxPixelsWide")
        desc.setValue(NSNumber(value: pixelH), forKey: "maxPixelsHigh")
        desc.setValue(NSNumber(value: 0x6D75), forKey: "vendorID")
        desc.setValue(NSNumber(value: 0x2000), forKey: "productID")
        desc.setValue(NSNumber(value: serialNum), forKey: "serialNum")
        desc.setValue(NSValue(size: NSSize(width: 530, height: 300)), forKey: "sizeInMillimeters")
        desc.setValue(DispatchQueue.main, forKey: "dispatchQueue")

        let allocSel = NSSelectorFromString("alloc")
        let initModeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let modeMethod = class_getInstanceMethod(modeCls, initModeSel),
              let rawMode = modeCls.perform(allocSel)
        else {
            return nil
        }
        typealias InitModeFn = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let initMode = unsafeBitCast(method_getImplementation(modeMethod), to: InitModeFn.self)
        guard let modeObj = initMode(rawMode.toOpaque(), initModeSel, UInt32(width), UInt32(height), 60.0)?.takeRetainedValue() else {
            return nil
        }

        let settings = settingsCls.init()
        settings.setValue(NSNumber(value: hiDPI ? 1 : 0), forKey: "hiDPI")
        settings.setValue([modeObj], forKey: "modes")

        return (desc, modeObj, settings)
    }
}
