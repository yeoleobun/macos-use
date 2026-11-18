import AppKit
import CoreGraphics
import CoreText
import Foundation
import MacOSUseKit
import Vision

// Initialize CoreGraphics WindowServer before running any ScreenCaptureKit-aware tests.
_ = CGMainDisplayID()

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw TestFailure(description: message)
    }
}

func approx(_ a: Double, _ b: Double, tol: Double = 0.01) -> Bool {
    abs(a - b) <= tol
}

@MainActor
func testTemporaryPaste() async throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let first = NSPasteboardItem()
    first.setString("formatted", forType: .string)
    first.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("org.macosuse.test.rich"))
    let second = NSPasteboardItem()
    second.setData(Data([4, 5, 6]), forType: NSPasteboard.PasteboardType("org.macosuse.test.image"))
    board.writeObjects([first, second])
    do {
        try await ClipboardManager.withTemporaryText("temporary", pasteboard: board) {
            try check(board.string(forType: .string) == "temporary", "Temporary paste missing")
            throw CancellationError()
        }
    } catch is CancellationError {}
    let restored = board.pasteboardItems ?? []
    try check(restored.count == 2 && restored[0].data(forType: NSPasteboard.PasteboardType("org.macosuse.test.rich")) == Data([1, 2, 3])
              && restored[1].data(forType: NSPasteboard.PasteboardType("org.macosuse.test.image")) == Data([4, 5, 6]), "Clipboard representations lost on error")
    try await ClipboardManager.withTemporaryText("temporary", pasteboard: board) {
        board.clearContents()
        board.setString("new copy", forType: .string)
    }
    try check(board.string(forType: .string) == "new copy", "Concurrent clipboard update was overwritten")
    print("[PASS] Multi-item clipboard restoration, cancellation, and concurrent copy")
}

func runAllTests() async throws {
    // 1. Multi-monitor negative-origin & Retina CaptureTransform test
    do {
        let transform = CaptureTransform(
            originX: -1470,
            originY: 119,
            logicalWidth: 1470,
            logicalHeight: 956,
            imageWidth: 2940,
            imageHeight: 1912
        )
        let globalPt = transform.imagePixelToGlobal(x: 1470, y: 956)
        try check(approx(globalPt.x, -735.0), "Expected x=-735.0, got \(globalPt.x)")
        try check(approx(globalPt.y, 597.0), "Expected y=597.0, got \(globalPt.y)")

        let imgBox = transform.globalToImageTopLeft(ScreenRect(x: -1370, y: 219, width: 100, height: 50))
        try check(approx(imgBox.origin.x, 200.0), "Expected imgBox x=200, got \(imgBox.origin.x)")
        try check(approx(imgBox.origin.y, 200.0), "Expected imgBox y=200, got \(imgBox.origin.y)")
        try check(approx(imgBox.size.width, 200.0), "Expected imgBox w=200, got \(imgBox.size.width)")
        try check(approx(imgBox.size.height, 100.0), "Expected imgBox h=100, got \(imgBox.size.height)")
        print("[PASS] Multi-display negative-origin & Retina CaptureTransform")
    }

    // 2. Vision NormalizedRect upperLeft mapping test
    do {
        let transform = CaptureTransform(
            originX: 100,
            originY: 200,
            logicalWidth: 1000,
            logicalHeight: 500,
            imageWidth: 2000,
            imageHeight: 1000
        )
        let norm = NormalizedRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1)
        let rect = transform.visionNormalizedToGlobal(norm)
        try check(approx(rect.x, 200.0), "Expected x=200, got \(rect.x)")
        try check(approx(rect.y, 250.0), "Expected y=250, got \(rect.y)")
        try check(approx(rect.width, 200.0), "Expected w=200, got \(rect.width)")
        try check(approx(rect.height, 50.0), "Expected h=50, got \(rect.height)")
        print("[PASS] Vision NormalizedRect upper-left global coordinate conversion")
    }

    // 3. UIFusionEngine label enrichment, deduplication, and reading-order indexing
    do {
        let axBtn = StoredElement(
            ui: UIElement(
                id: "ax1",
                index: 0,
                role: "button",
                rawRole: "AXButton",
                label: "button",
                source: .ax,
                frame: ScreenRect(x: 50, y: 40, width: 80, height: 32)
            )
        )
        let visDup = StoredElement(
            ui: UIElement(
                id: "v1",
                index: 0,
                role: "button",
                rawRole: "VisionContour+Text",
                label: "Save",
                source: .visionButton,
                frame: ScreenRect(x: 52, y: 41, width: 76, height: 30)
            )
        )
        let visSeparate = StoredElement(
            ui: UIElement(
                id: "v2",
                index: 0,
                role: "button",
                rawRole: "VisionContour+Text",
                label: "Cancel",
                source: .visionButton,
                frame: ScreenRect(x: 150, y: 40, width: 80, height: 32)
            )
        )
        let fused = UIFusionEngine.fuse(axElements: [axBtn], visionElements: [visDup, visSeparate])
        try check(fused.count == 2, "Expected 2 fused elements after dedupe, got \(fused.count)")
        try check(fused[0].ui.id == "e1" && fused[0].ui.label == "Save", "Expected AX button enriched to 'Save'")
        try check(fused[0].ui.source == .axVision, "Expected source ax_vision")
        try check(fused[1].ui.id == "e2" && fused[1].ui.label == "Cancel", "Expected second button 'Cancel'")
        print("[PASS] UIFusionEngine enrichment, IoU deduplication, and e1..eN indexing")
    }

    // 4. SoMAnnotator synthetic button rendering & JPEG encoding
    do {
        let ctx = CGContext(
            data: nil,
            width: 400,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        ctx.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.90, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 120, width: 120, height: 40)) // top-left y = 40
        let img = ctx.makeImage()!

        let transform = CaptureTransform(originX: 0, originY: 0, logicalWidth: 400, logicalHeight: 200, imageWidth: 400, imageHeight: 200)
        let elem = UIElement(
            id: "e1",
            index: 1,
            role: "button",
            rawRole: "VisionContour+Text",
            label: "Submit",
            source: .visionButton,
            frame: ScreenRect(x: 40, y: 40, width: 120, height: 40)
        )
        let annotated = SoMAnnotator.annotate(image: img, transform: transform, elements: [elem])
        let jpeg = try ScreenCapturer.encodeImage(annotated, format: .jpeg, jpegQuality: 0.85)
        try check(annotated.width == 400 && annotated.height == 200, "Annotated dimensions mismatch")
        try check(jpeg.count > 500, "Encoded JPEG unexpectedly small: \(jpeg.count)")
        print("[PASS] SoMAnnotator rendering & ImageIO JPEG encoding (\(jpeg.count) bytes)")
    }

    // 5. KeyCodes lookup & modifier mapping
    do {
        let kA = try KeyCodes.lookup("a")
        let kPlus = try KeyCodes.lookup("+")
        let kRet = try KeyCodes.lookup("return")
        let flags = try KeyCodes.modifierFlags(["cmd", "shift"])
        try check(!kA.implicitShift, "'a' should not have implicitShift")
        try check(kPlus.implicitShift, "'+' should have implicitShift")
        try check(kRet.keyCode == 36, "Expected return keyCode 36, got \(kRet.keyCode)")
        try check(flags.contains(.maskCommand) && flags.contains(.maskShift), "Expected cmd+shift flags")
        print("[PASS] KeyCodes & modifier flag mappings")
    }

    // 6. MCP Server protocol initialize, tools/list, and live system_status/list_apps_and_windows
    do {
        let server = MacOSUseMCPServer()
        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"test","version":"1.0"}}}"#.data(using: .utf8)!
        let initResp = await server.handleRequestData(initReq)
        try check(initResp?.result?["protocolVersion"]?.stringValue == "2025-03-26", "Unexpected protocolVersion")
        try check(initResp?.result?["serverInfo"]?["name"]?.stringValue == "macos-use", "Unexpected serverInfo.name")

        let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.data(using: .utf8)!
        let listResp = await server.handleRequestData(listReq)
        let toolsList = listResp?.result?["tools"]?.arrayValue ?? []
        try check(toolsList.count == 21, "Expected 21 MCP tools, got \(toolsList.count)")
        for toolName in ["click", "type_text", "press_key", "manage_app"] {
            let tool = toolsList.first { $0["name"]?.stringValue == toolName }
            let hasBg = tool?["inputSchema"]?["properties"]?["background"] != nil
            try check(hasBg, "Expected 'background' parameter on tool '\(toolName)'")
        }
        for newTool in ["scroll_to_element", "widget_action", "handle_dialog", "virtual_display", "session_trace"] {
            let found = toolsList.contains { $0["name"]?.stringValue == newTool }
            try check(found, "Expected v2 MCP tool '\(newTool)' in tools/list")
        }
        let clickTool = toolsList.first { $0["name"]?.stringValue == "click" }
        try check(clickTool?["inputSchema"]?["properties"]?["verify"] != nil, "Expected 'verify' on click")
        let obsTool = toolsList.first { $0["name"]?.stringValue == "observe_screen" }
        try check(obsTool?["inputSchema"]?["properties"]?["classify_icons"] != nil, "Expected 'classify_icons' on observe_screen")
        try check(obsTool?["inputSchema"]?["properties"]?["include_popups"] != nil, "Expected 'include_popups' on observe_screen")

        let statusReq = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"system_status","arguments":{}}}"#.data(using: .utf8)!
        let statusResp = await server.handleRequestData(statusReq)
        try check(statusResp?.result?["isError"]?.boolValue == false, "system_status returned isError=true")

        let winReq = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_apps_and_windows","arguments":{}}}"#.data(using: .utf8)!
        let winResp = await server.handleRequestData(winReq)
        try check(winResp?.result?["isError"]?.boolValue == false, "list_apps_and_windows returned isError=true")
        print("[PASS] In-process MacOSUseMCPServer JSON-RPC 2.0 roundtrips (21 tools + v2 schemas)")
    }

    do {
        let server = MacOSUseMCPServer()
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"future"}}"#.utf8)
        let response = await server.handleRequestData(request)
        try check(response?.result?["protocolVersion"] == .string("2025-03-26"), "Unsupported MCP version was echoed")
        for badNumber in [JSONValue.double(1e100), .double(1.5), .int(Int.max)] {
            let invalid = await server.executeTool(name: "session_trace", args: ["action": .string("recent_events"), "limit": badNumber])
            try check(invalid.isError, "Invalid integer accepted")
        }
        for background in [true, false] {
            let result = await server.executeTool(name: "press_key", args: [
                "bundle_id": .string("invalid.macos-use.missing-app"), "key": .string("shift"),
                "background": .bool(background)
            ])
            try check(result.isError && result.content.first?.text?.contains("not running") == true, "Unresolved target must fail before input")
        }
        print("[PASS] Protocol negotiation, integer validation, and missing-target rejection")
    }

    try await testTemporaryPaste()
    // 7. UIFusionEngine ignores large AXGroup container enrichment
    do {
        let bigGroup = StoredElement(
            ui: UIElement(
                id: "axg",
                index: 0,
                role: "group",
                rawRole: "AXGroup",
                label: "group",
                isInteractive: true,
                source: .ax,
                frame: ScreenRect(x: 0, y: 0, width: 500, height: 400)
            )
        )
        let innerText = StoredElement(
            ui: UIElement(
                id: "vt1",
                index: 0,
                role: "text",
                rawRole: "VisionText",
                label: "Inside Text",
                source: .visionText,
                frame: ScreenRect(x: 20, y: 20, width: 100, height: 20)
            )
        )
        let fused = UIFusionEngine.fuse(axElements: [bigGroup], visionElements: [innerText])
        let groupElem = fused.first { $0.ui.role == "group" }
        try check(groupElem?.ui.source == .ax && groupElem?.ui.label == "group", "Large group should not absorb Vision text")
        print("[PASS] UIFusionEngine large AXGroup container isolation")
    }

    // 8. Live VisionInspector synthetic UI button + CJK/English OCR detection test
    do {
        let ctx = CGContext(
            data: nil,
            width: 500,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 500, height: 200))
        // Draw two crisp button boxes
        ctx.setFillColor(CGColor(red: 0.90, green: 0.93, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 30, y: 110, width: 160, height: 48))
        ctx.setStrokeColor(CGColor(red: 0.2, green: 0.4, blue: 0.85, alpha: 1))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 30, y: 110, width: 160, height: 48))

        // Draw "Confirm" inside button via CoreText
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 20, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1)
        ]
        if let attr = CFAttributedStringCreate(kCFAllocatorDefault, "Confirm" as CFString, attrs as CFDictionary) {
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 68, y: 127)
            CTLineDraw(line, ctx)
        }
        let img = ctx.makeImage()!
        let transform = CaptureTransform(originX: 0, originY: 0, logicalWidth: 500, logicalHeight: 200, imageWidth: 500, imageHeight: 200)
        let detected = try await VisionInspector.inspect(image: img, transform: transform, window: nil, axTrusted: false)
        let hasConfirm = detected.contains { $0.ui.label.localizedCaseInsensitiveContains("Confirm") }
        try check(hasConfirm, "VisionInspector failed to recognize 'Confirm' button in synthetic image")
        print("[PASS] VisionInspector OCR + button contour fusion (\(detected.count) elements detected)")
    }

    // 9. IconClassifier Neural Engine semantic labeling of unlabeled vector buttons
    do {
        let iconImg: CGImage = await MainActor.run {
            let w = 300, h = 100
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()

            let drawIconBtn: (CGFloat, String, NSColor, NSColor) -> Void = { topLeftX, sym, bg, fg in
                let rect = NSRect(x: topLeftX, y: 28, width: 44, height: 44) // top-left y = 100 - 28 - 44 = 28
                bg.setFill()
                NSBezierPath(ovalIn: rect).fill()
                if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 20, weight: .semibold).applying(.init(paletteColors: [fg])))
                {
                    let inner = NSRect(x: rect.minX + 10, y: rect.minY + 10, width: 24, height: 24)
                    let aspect = img.size.width / max(1.0, img.size.height)
                    var d = inner
                    if aspect > 1.0 {
                        let bh = inner.width / aspect
                        d = NSRect(x: inner.minX, y: inner.midY - bh / 2.0, width: inner.width, height: bh)
                    } else {
                        let bw = inner.height * aspect
                        d = NSRect(x: inner.midX - bw / 2.0, y: inner.minY, width: bw, height: inner.height)
                    }
                    img.draw(in: d)
                }
            }
            drawIconBtn(20, "phone.down.fill", .systemRed, .white)
            drawIconBtn(90, "mic.fill", .darkGray, .white)
            drawIconBtn(160, "gearshape.fill", NSColor(white: 0.92, alpha: 1), .black)
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()!
        }

        let transform = CaptureTransform(originX: 0, originY: 0, logicalWidth: 300, logicalHeight: 100, imageWidth: 300, imageHeight: 100)
        let placeholders = [
            StoredElement(ui: UIElement(id: "e1", index: 1, role: "button", rawRole: "AXButton", label: "button", source: .ax, frame: ScreenRect(x: 20, y: 28, width: 44, height: 44))),
            StoredElement(ui: UIElement(id: "e2", index: 2, role: "button", rawRole: "AXButton", label: "button", source: .ax, frame: ScreenRect(x: 90, y: 28, width: 44, height: 44))),
            StoredElement(ui: UIElement(id: "e3", index: 3, role: "button", rawRole: "AXButton", label: "button", source: .ax, frame: ScreenRect(x: 160, y: 28, width: 44, height: 44)))
        ]
        let classified = await IconClassifier.shared.classifyIcons(elements: placeholders, image: iconImg, transform: transform)
        try check(classified[0].ui.label.contains("Hangup") || classified[0].ui.label.contains("End Call"), "Expected Hangup icon label, got '\(classified[0].ui.label)'")
        try check(classified[1].ui.label == "Microphone", "Expected Microphone icon label, got '\(classified[1].ui.label)'")
        try check(classified[2].ui.label == "Settings", "Expected Settings icon label, got '\(classified[2].ui.label)'")
        print("[PASS] IconClassifier Neural Engine semantic icon classification")
    }

    // 10. Garbled icon OCR filtering in UIFusionEngine
    do {
        try check(UIFusionEngine.isGarbledIconOCR("←）"), "Expected '←）' to be detected as garbled icon OCR")
        try check(UIFusionEngine.isGarbledIconOCR("•●•"), "Expected '•●•' to be detected as garbled icon OCR")
        try check(!UIFusionEngine.isGarbledIconOCR("Save"), "Did not expect 'Save' to be flagged")
        try check(!UIFusionEngine.isGarbledIconOCR("+"), "Did not expect '+' to be flagged")
        try check(!UIFusionEngine.isGarbledIconOCR("7"), "Did not expect '7' to be flagged")
        try check(!UIFusionEngine.isGarbledIconOCR("通话"), "Did not expect '通话' to be flagged")

        let compactAX = StoredElement(
            ui: UIElement(id: "ax1", index: 0, role: "button", rawRole: "AXButton", label: "button", source: .ax, frame: ScreenRect(x: 100, y: 100, width: 40, height: 40))
        )
        let garbledVis = StoredElement(
            ui: UIElement(id: "vt1", index: 0, role: "text_button", rawRole: "VisionText", label: "←）", source: .visionText, frame: ScreenRect(x: 108, y: 112, width: 24, height: 16))
        )
        let fused = UIFusionEngine.fuse(axElements: [compactAX], visionElements: [garbledVis])
        try check(fused.count == 1 && fused[0].ui.label == "button", "Expected compact AX button not to absorb garbled OCR '←）'")
        print("[PASS] UIFusionEngine garbled icon OCR rejection & clean passthrough")
    }

    // 11. UIEventObserver grayscale frame delta & settle observer
    do {
        let makeSquare: (Bool) -> CGImage = { withDarkBox in
            let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            if withDarkBox {
                ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
                ctx.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
            }
            return ctx.makeImage()!
        }
        let s1 = UIEventObserver.computeGrayscaleSignature(image: makeSquare(false), gridSize: 32)
        let s2 = UIEventObserver.computeGrayscaleSignature(image: makeSquare(true), gridSize: 32)
        try check(UIEventObserver.pixelDelta(s1, s1) == 0.0, "Identical frame delta should be 0")
        try check(UIEventObserver.pixelDelta(s1, s2) > 0.10, "Changed frame delta should exceed 0.10")

        let settled = await UIEventObserver.waitForSettle(
            pid: ProcessInfo.processInfo.processIdentifier,
            maxWaitMs: 120,
            quietWindowMs: 40,
            checkVisual: false
        )
        try check(settled.settled && settled.elapsedMs < 500, "Expected bounded settle completion")
        print("[PASS] UIEventObserver grayscale delta & bounded AXObserver settle")
    }

    // 12. ActionVerifier pre/post snapshot & multi-attempt metadata
    do {
        let pre = await ActionVerifier.capturePreState(
            pid: nil,
            point: CGPoint(x: 100, y: 100),
            element: nil,
            captureVisual: false
        )
        let post = await ActionVerifier.verifyPostState(
            before: pre,
            element: nil,
            attempts: ["ax_press", "cgevent_left_x1"],
            settleMs: 80
        )
        try check(!post.verified && post.escalated && post.attempts.count == 2, "Expected unverified result when no change was observed")
        print("[PASS] ActionVerifier pre/post verification & escalation tracking")
    }

    // 13. SafetyPolicyManager destructive action gates & safe whitelist
    do {
        _ = try await SafetyPolicyManager.shared.configure(mode: "standard", maxActionsPerMinute: 300)
        var blockedTrash = false
        do {
            try await SafetyPolicyManager.shared.checkAction(tool: "click", targetLabel: "Empty Trash", confirmDestructive: false)
        } catch MacOSUseError.safetyBlocked {
            blockedTrash = true
        }
        try check(blockedTrash, "Expected Empty Trash to be blocked without confirm_destructive")
        try await SafetyPolicyManager.shared.checkAction(tool: "click", targetLabel: "Empty Trash", confirmDestructive: true)
        try await SafetyPolicyManager.shared.checkAction(tool: "click", targetLabel: "End Call / Hangup", confirmDestructive: false)

        _ = try await SafetyPolicyManager.shared.configure(mode: "strict", maxActionsPerMinute: 300)
        var blockedStrictDelete = false
        do {
            try await SafetyPolicyManager.shared.checkAction(tool: "click", targetLabel: "Delete Contact", confirmDestructive: false)
        } catch MacOSUseError.safetyBlocked {
            blockedStrictDelete = true
        }
        try check(blockedStrictDelete, "Expected strict mode to block Delete action")
        _ = try await SafetyPolicyManager.shared.configure(mode: "standard", maxActionsPerMinute: 180)
        print("[PASS] SafetyPolicyManager standard/strict destructive confirmation gates")
    }

    // 14. TrajectoryRecorder temp JSONL flight recorder
    do {
        let traceDir = "/tmp/macos-use-test-trace-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: traceDir) }

        let dir = try await TrajectoryRecorder.shared.startTrace(directory: traceDir, saveImages: false)
        let server = MacOSUseMCPServer()
        _ = await server.executeTool(name: "system_status", args: [:])
        _ = await server.executeTool(name: "clipboard", args: ["action": .string("read")])
        let stopped = await TrajectoryRecorder.shared.stopTrace()
        try check(!stopped.active && stopped.directory == dir && stopped.eventsWritten >= 2, "Expected >= 2 events written to trace")

        let jsonl = try String(contentsOfFile: "\(dir)/events.jsonl", encoding: .utf8)
        let lines = jsonl.split(whereSeparator: \.isNewline)
        try check(lines.count >= 2 && jsonl.contains("system_status") && jsonl.contains("clipboard"), "Expected valid events.jsonl contents")
        print("[PASS] TrajectoryRecorder JSONL trace write & stop lifecycle")
    }

    // 15. VirtualDisplayManager runtime bridge & ARC deallocation probe
    do {
        let (supported, allocClean) = await MainActor.run {
            (VirtualDisplayManager.shared.isSupported(), VirtualDisplayManager.shared.testDescriptorAllocation())
        }
        try check(supported, "Expected CGVirtualDisplay Objective-C classes on macOS 27")
        try check(allocClean, "Expected CGVirtualDisplayDescriptor & Mode ARC cleanup with zero leaks")
        print("[PASS] VirtualDisplayManager ObjC runtime bridge & zero-leak ARC probe")
    }
}

_ = Task {
    do {
        try await runAllTests()
        print("\nALL TESTS PASSED")
        exit(0)
    } catch {
        fputs("TEST FAILED: \(error)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
