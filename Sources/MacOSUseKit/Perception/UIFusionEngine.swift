import Foundation

/// Merges Accessibility (`AXInspector`) and Vision (`VisionInspector`) UI elements into a unified, sorted catalog (`e1..eN`).
public enum UIFusionEngine {
    public static func isGarbledIconOCR(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4 else { return false }
        let allowedSymbols: Set<String> = ["+", "-", "*", "/", "?", "=", "×", "÷", "%", "<", ">", "."]
        if allowedSymbols.contains(trimmed) { return false }

        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            if (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                return false
            }
            if (0x4E00...0x9FFF).contains(v) {
                return false
            }
        }
        return true
    }

    public static func fuse(
        axElements: [StoredElement],
        visionElements: [StoredElement],
        maxElements: Int = 180
    ) -> [StoredElement] {
        var fusedAX = axElements

        // 1. Enrich unlabeled AX controls (not huge container groups) with Vision text centered inside them
        let visionTexts = visionElements.filter { $0.ui.source == .visionText || $0.ui.source == .visionButton }
        for i in fusedAX.indices {
            let axUI = fusedAX[i].ui
            let needsLabel = axUI.label.isEmpty || axUI.label == axUI.role
            let eligibleControl = axUI.role != "group" && axUI.role != "scrollarea" && axUI.frame.area <= 36000
            if needsLabel && eligibleControl {
                let inside = visionTexts.filter { vt in
                    axUI.frame.padded(by: 4.0).contains(vt.ui.frame.center)
                }.sorted { $0.ui.frame.x < $1.ui.frame.x }
                if !inside.isEmpty && inside.count <= 4 {
                    let combinedText = inside.map(\.ui.label).joined(separator: " ")
                    let isCompactIcon = axUI.frame.width <= 68 && axUI.frame.height <= 68
                    if !(isCompactIcon && isGarbledIconOCR(combinedText)) {
                        var updated = axUI
                        updated.label = combinedText
                        updated.source = .axVision
                        fusedAX[i].ui = updated
                    }
                }
            }
        }

        // 2. Keep Vision elements that do not duplicate an existing AX element
        var combined: [StoredElement] = fusedAX
        for vElem in visionElements {
            let vFrame = vElem.ui.frame
            if vElem.ui.source == .visionText && isGarbledIconOCR(vElem.ui.label) {
                let insideCompactAX = fusedAX.contains { axElem in
                    axElem.ui.frame.width <= 68 && axElem.ui.frame.height <= 68
                        && axElem.ui.frame.padded(by: 6.0).contains(vFrame.center)
                }
                if insideCompactAX { continue }
            }
            let overlapsAX = fusedAX.contains { axElem in
                let aFrame = axElem.ui.frame
                if aFrame.iou(with: vFrame) > 0.40 { return true }
                // Text or unlabeled icon contour inside an already-labeled AX control
                if (vElem.ui.source == .visionText || vElem.ui.source == .visionControl)
                    && aFrame.padded(by: 2.0).contains(vFrame.center)
                    && aFrame.area <= max(vFrame.area * 8.0, 24000.0)
                {
                    return true
                }
                // AX control inside a Vision button contour
                if aFrame.contains(vFrame.center) && vFrame.contains(aFrame.center) {
                    let ratio = min(aFrame.area, vFrame.area) / max(1.0, max(aFrame.area, vFrame.area))
                    return ratio > 0.45
                }
                return false
            }
            if !overlapsAX {
                combined.append(vElem)
            }
        }

        // 3. Deduplicate nearly identical remaining elements (e.g. duplicate Vision text/controls)
        var deduped: [StoredElement] = []
        for item in combined {
            let duplicate = deduped.contains { existing in
                let iou = existing.ui.frame.iou(with: item.ui.frame)
                if iou > 0.78 {
                    return true
                }
                if existing.ui.source == item.ui.source && iou > 0.62 && existing.ui.label == item.ui.label {
                    return true
                }
                return false
            }
            if !duplicate {
                deduped.append(item)
            }
        }

        // 4. Sort in visual reading order (14pt vertical bands top-to-bottom, then left-to-right)
        deduped.sort { lhs, rhs in
            let lBand = Int((lhs.ui.frame.y / 14.0).rounded())
            let rBand = Int((rhs.ui.frame.y / 14.0).rounded())
            if lBand != rBand { return lBand < rBand }
            if abs(lhs.ui.frame.x - rhs.ui.frame.x) > 2.0 {
                return lhs.ui.frame.x < rhs.ui.frame.x
            }
            return lhs.ui.frame.area < rhs.ui.frame.area
        }

        // 5. Prioritize interactive elements slightly if exceeding maxElements, preserving reading order
        let capped: [StoredElement]
        if deduped.count > maxElements {
            let interactive = deduped.filter(\.ui.isInteractive)
            if interactive.count >= maxElements {
                capped = Array(interactive.prefix(maxElements))
            } else {
                let remainingBudget = maxElements - interactive.count
                let passive = deduped.filter { !$0.ui.isInteractive }.prefix(remainingBudget)
                capped = (interactive + passive).sorted { lhs, rhs in
                    let lBand = Int((lhs.ui.frame.y / 14.0).rounded())
                    let rBand = Int((rhs.ui.frame.y / 14.0).rounded())
                    if lBand != rBand { return lBand < rBand }
                    return lhs.ui.frame.x < rhs.ui.frame.x
                }
            }
        } else {
            capped = deduped
        }

        // 6. Assign deterministic 1-based IDs e1..eN
        return capped.enumerated().map { idx, item in
            var copy = item
            let oneBased = idx + 1
            copy.ui.index = oneBased
            copy.ui.id = "e\(oneBased)"
            return copy
        }
    }
}
