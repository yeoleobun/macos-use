import CoreGraphics
import Foundation
import Vision

/// Apple Silicon neural UI grounding combining `RecognizeTextRequest` and `DetectContoursRequest`.
public enum VisionInspector {
    public struct VisionOptions: Sendable {
        public var detectContours: Bool
        public var includeIconControls: Bool
        public var includeWindowChromeIfNeeded: Bool

        public init(
            detectContours: Bool = true,
            includeIconControls: Bool = true,
            includeWindowChromeIfNeeded: Bool = true
        ) {
            self.detectContours = detectContours
            self.includeIconControls = includeIconControls
            self.includeWindowChromeIfNeeded = includeWindowChromeIfNeeded
        }
    }

    private struct TextBlock {
        let text: String
        let confidence: Double
        let frame: ScreenRect
    }

    public static func inspect(
        image: CGImage,
        transform: CaptureTransform,
        window: WindowInfo?,
        axTrusted: Bool,
        options: VisionOptions = VisionOptions()
    ) async throws -> [StoredElement] {
        var textReq = RecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.automaticallyDetectsLanguage = true
        textReq.usesLanguageCorrection = true
        textReq.minimumTextHeightFraction = 0.008

        async let textObservationsTask = textReq.perform(on: image)

        var contourRects: [ScreenRect] = []
        if options.detectContours {
            var contourReq = DetectContoursRequest()
            contourReq.contrastAdjustment = 1.6
            contourReq.maximumImageDimension = 1280
            contourReq.detectsDarkOnLight = true
            let contourObs = try await contourReq.perform(on: image)
            contourRects = extractContourRects(from: contourObs, transform: transform)
        }

        let textObservations = try await textObservationsTask
        let textBlocks: [TextBlock] = textObservations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let rect = transform.visionNormalizedToGlobal(obs.boundingBox)
            guard rect.width >= 4, rect.height >= 4 else { return nil }
            return TextBlock(text: trimmed, confidence: Double(candidate.confidence), frame: rect)
        }

        // Partition contours into interactive button/input boxes vs compact icon controls
        let buttonContours = deduplicateContours(
            contourRects.filter { r in
                r.width >= 20 && r.width <= 650 && r.height >= 16 && r.height <= 96 && (r.width / max(1, r.height)) <= 24.0
            }
        )

        var contourToTexts: [Int: [TextBlock]] = [:]
        var unmatchedTexts: [TextBlock] = []

        for block in textBlocks {
            let center = block.frame.center
            // Choose the tightest button contour containing this text block's center.
            let containing = buttonContours.enumerated().filter { (_, cRect) in
                guard cRect.padded(by: 3.0).contains(center) else { return false }
                // Avoid matching huge toolbar strips around tiny scattered words unless aspect ratio fits a button/field.
                return cRect.area >= block.frame.area * 0.7 && cRect.height <= max(92.0, block.frame.height * 4.5)
            }
            if let best = containing.min(by: { $0.element.area < $1.element.area }) {
                contourToTexts[best.offset, default: []].append(block)
            } else {
                unmatchedTexts.append(block)
            }
        }

        var results: [StoredElement] = []

        // 1. Emit fused button / textfield contours enclosing recognized text
        for (idx, blocks) in contourToTexts {
            let cRect = buttonContours[idx]
            let sortedBlocks = blocks.sorted { lhs, rhs in
                let ly = Int((lhs.frame.y / 8.0).rounded())
                let ry = Int((rhs.frame.y / 8.0).rounded())
                if ly != ry { return ly < ry }
                return lhs.frame.x < rhs.frame.x
            }
            let combinedLabel = sortedBlocks.map(\.text).joined(separator: " ")
            let avgConf = sortedBlocks.map(\.confidence).reduce(0.0, +) / Double(max(1, sortedBlocks.count))
            let role = inferContourRole(rect: cRect, label: combinedLabel)

            let ui = UIElement(
                id: "vb",
                index: 0,
                role: role,
                rawRole: "VisionContour+Text",
                label: combinedLabel,
                enabled: true,
                isInteractive: true,
                actions: ["click"],
                source: .visionButton,
                confidence: (avgConf * 100.0).rounded() / 100.0,
                frame: cRect,
                ownerPID: window?.ownerPID,
                windowID: window?.windowID
            )
            results.append(StoredElement(ui: ui))
        }

        // 2. Emit standalone OCR text elements (tabs, links, labels, menu strings, sidebar items)
        for block in unmatchedTexts {
            let role = inferTextRole(rect: block.frame, text: block.text)
            let ui = UIElement(
                id: "vt",
                index: 0,
                role: role,
                rawRole: "VisionText",
                label: block.text,
                enabled: true,
                isInteractive: true,
                actions: ["click"],
                source: .visionText,
                confidence: (block.confidence * 100.0).rounded() / 100.0,
                frame: block.frame,
                ownerPID: window?.ownerPID,
                windowID: window?.windowID
            )
            results.append(StoredElement(ui: ui))
        }

        // 3. Emit compact unlabeled icon contours (toolbars, traffic lights, sidebar toggles)
        if options.includeIconControls {
            let iconContours = deduplicateContours(
                contourRects.filter { r in
                    let aspect = r.width / max(1, r.height)
                    return r.width >= 16 && r.width <= 54 && r.height >= 16 && r.height <= 54
                        && aspect >= 0.55 && aspect <= 1.85
                }
            )

            var addedIcons = 0
            for cRect in iconContours {
                if addedIcons >= 35 { break }
                let overlapsExisting = results.contains { existing in
                    existing.ui.frame.iou(with: cRect) > 0.20
                        || existing.ui.frame.contains(cRect.center)
                        || cRect.contains(existing.ui.frame.center)
                }
                if overlapsExisting { continue }

                // Prefer toolbar/header/sidebar edge controls over noisy interior graphics
                let localY = cRect.y - transform.originY
                let localX = cRect.x - transform.originX
                let nearToolbarOrEdge = localY <= 110
                    || localX <= 80
                    || localX >= (transform.logicalWidth - 110)
                    || localY >= (transform.logicalHeight - 90)
                if !nearToolbarOrEdge { continue }

                addedIcons += 1
                let ui = UIElement(
                    id: "vc",
                    index: 0,
                    role: "icon_button",
                    rawRole: "VisionIconContour",
                    label: "Icon Button",
                    enabled: true,
                    isInteractive: true,
                    actions: ["click"],
                    source: .visionControl,
                    confidence: 0.72,
                    frame: cRect,
                    ownerPID: window?.ownerPID,
                    windowID: window?.windowID
                )
                results.append(StoredElement(ui: ui))
            }
        }

        // 4. Add standard macOS window traffic lights when AX is unavailable on standard layer-0 windows
        if options.includeWindowChromeIfNeeded && !axTrusted,
           let win = window, win.layer == 0, win.frame.width >= 160, win.frame.height >= 90
        {
            let trafficLights: [(role: String, label: String, offsetX: Double)] = [
                ("close_button", "Close Window", 18.0),
                ("minimize_button", "Minimize Window", 38.0),
                ("zoom_button", "Zoom Window", 58.0)
            ]
            for tl in trafficLights {
                let rect = ScreenRect(
                    x: win.frame.x + tl.offsetX - 6.0,
                    y: win.frame.y + 12.0,
                    width: 12.0,
                    height: 12.0
                )
                let alreadyCovered = results.contains { $0.ui.frame.contains(rect.center) }
                if !alreadyCovered {
                    let ui = UIElement(
                        id: "wc",
                        index: 0,
                        role: tl.role,
                        rawRole: "WindowChromeTrafficLight",
                        label: tl.label,
                        enabled: true,
                        isInteractive: true,
                        actions: ["click"],
                        source: .windowChrome,
                        confidence: 0.85,
                        frame: rect,
                        ownerPID: win.ownerPID,
                        windowID: win.windowID
                    )
                    results.append(StoredElement(ui: ui))
                }
            }
        }

        return results
    }

    private static func extractContourRects(
        from observation: ContoursObservation,
        transform: CaptureTransform
    ) -> [ScreenRect] {
        var collected: [ScreenRect] = []
        let maxContours = 1500

        func visit(_ contour: ContoursObservation.Contour, depth: Int) {
            if collected.count >= maxContours || depth > 4 { return }
            let rawBox = contour.normalizedPath.boundingBox
            if rawBox.width > 0.002, rawBox.height > 0.002 {
                let norm = NormalizedRect(normalizedRect: rawBox)
                let rect = transform.visionNormalizedToGlobal(norm)
                let coversNearlyWholeFrame = rect.width > transform.logicalWidth * 0.88
                    && rect.height > transform.logicalHeight * 0.88
                if !coversNearlyWholeFrame && rect.width >= 12 && rect.height >= 12 {
                    collected.append(rect)
                }
            }
            for child in contour.childContours {
                visit(child, depth: depth + 1)
            }
        }

        for top in observation.topLevelContours {
            visit(top, depth: 0)
        }
        return collected
    }

    private static func deduplicateContours(_ rects: [ScreenRect]) -> [ScreenRect] {
        let sorted = rects.sorted { $0.area < $1.area }
        var kept: [ScreenRect] = []
        for candidate in sorted {
            let duplicate = kept.contains { existing in
                existing.iou(with: candidate) > 0.72
            }
            if !duplicate {
                kept.append(candidate)
            }
        }
        return kept
    }

    private static func inferContourRole(rect: ScreenRect, label: String) -> String {
        let lower = label.lowercased()
        let searchHints = ["search", "filter", "type ", "enter ", "ask ", "url", "address", "搜索", "查找", "输入"]
        if rect.width >= 140 && rect.height >= 22 && rect.height <= 54
            && searchHints.contains(where: { lower.contains($0) })
        {
            return "textfield"
        }
        return "button"
    }

    private static func inferTextRole(rect: ScreenRect, text: String) -> String {
        if text.count <= 28 && rect.height <= 30 {
            return "text_button"
        }
        return "text"
    }
}
