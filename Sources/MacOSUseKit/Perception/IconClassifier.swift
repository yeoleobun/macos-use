import AppKit
import CoreGraphics
import Foundation
import Vision

/// Semantic UI icon classifier powered by Apple Vision `GenerateImageFeaturePrintRequest`
/// on the Neural Engine with zero external model files or dependencies.
public actor IconClassifier {
    public static let shared = IconClassifier()

    private struct PrototypeEntry: @unchecked Sendable {
        let label: String
        let symbol: String
        let featurePrint: FeaturePrintObservation
    }

    private static let canonicalSymbols: [(label: String, symbol: String)] = [
        ("End Call / Hangup", "phone.down.fill"),
        ("End Call / Hangup", "phone.down"),
        ("Answer / Call", "phone.fill"),
        ("Answer / Call", "phone"),
        ("Mute Microphone", "mic.slash.fill"),
        ("Microphone", "mic.fill"),
        ("Mute Speaker", "speaker.slash.fill"),
        ("Speaker / Audio", "speaker.wave.2.fill"),
        ("Speaker / Audio", "speaker.fill"),
        ("Video Off", "video.slash.fill"),
        ("Video Camera", "video.fill"),
        ("Pause / Hold", "pause.fill"),
        ("Play / Resume", "play.fill"),
        ("Record", "record.circle"),
        ("Settings", "gearshape.fill"),
        ("Settings", "gear"),
        ("Search", "magnifyingglass"),
        ("Close", "xmark"),
        ("Close", "xmark.circle.fill"),
        ("Add / New", "plus"),
        ("Delete / Trash", "trash.fill"),
        ("Send", "paperplane.fill"),
        ("Chat / Message", "bubble.left.fill"),
        ("More Options", "ellipsis"),
        ("Menu", "line.3.horizontal"),
        ("Refresh / Reload", "arrow.clockwise"),
        ("Share", "square.and.arrow.up"),
        ("Lock", "lock.fill"),
        ("Back", "chevron.left"),
        ("Back", "arrow.left"),
        ("Forward", "chevron.right"),
        ("Keypad", "circle.grid.3x3.fill")
    ]

    private var prototypes: [PrototypeEntry]?

    public init() {}

    /// Classifies unlabeled or OCR-garbled compact UI icon elements (`14..68` pt) using FeaturePrint similarity.
    public func classifyIcons(
        elements: [StoredElement],
        image: CGImage,
        transform: CaptureTransform,
        maxCandidates: Int = 16
    ) async -> [StoredElement] {
        guard !elements.isEmpty else { return elements }

        let candidateIndices = selectCandidateIndices(in: elements, maxCandidates: maxCandidates)
        guard !candidateIndices.isEmpty else { return elements }

        await ensurePrototypesBuilt()
        guard let prototypes, !prototypes.isEmpty else { return elements }

        struct CropJob: @unchecked Sendable {
            let index: Int
            let silhouette: CGImage
            let hue: String
            let hadAXRef: Bool
        }

        var jobs: [CropJob] = []
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        for idx in candidateIndices {
            let stored = elements[idx]
            let pxRect = transform.globalToImageTopLeft(stored.ui.frame).integral.intersection(imageBounds)
            guard pxRect.width >= 10, pxRect.height >= 10,
                  let crop = image.cropping(to: pxRect),
                  let normalized = Self.normalizeIconCrop(crop)
            else {
                continue
            }
            jobs.append(CropJob(
                index: idx,
                silhouette: normalized.silhouette,
                hue: normalized.bgHue,
                hadAXRef: stored.axRef != nil
            ))
        }

        guard !jobs.isEmpty else { return elements }

        var updated = elements
        let bank = prototypes

        await withTaskGroup(of: (Int, String, Double, UIElementSource)?.self) { group in
            for job in jobs {
                group.addTask {
                    let req = GenerateImageFeaturePrintRequest()
                    guard let fp = try? await req.perform(on: job.silhouette) else {
                        return nil
                    }

                    var bestLabel = ""
                    var bestAdjusted = Double.greatestFiniteMagnitude
                    var bestRaw = Double.greatestFiniteMagnitude

                    for proto in bank {
                        guard let distFloat = try? fp.distance(to: proto.featurePrint) else { continue }
                        let rawDist = Double(distFloat)
                        var adjusted = rawDist
                        if job.hue == "red" && proto.label == "End Call / Hangup" {
                            adjusted -= 0.11
                        } else if job.hue == "green" && proto.label == "Answer / Call" {
                            adjusted -= 0.09
                        }
                        if adjusted < bestAdjusted {
                            bestAdjusted = adjusted
                            bestRaw = rawDist
                            bestLabel = proto.label
                        }
                    }

                    let newSource: UIElementSource = job.hadAXRef ? .axIconML : .visionIconML
                    if bestAdjusted <= 0.38 && !bestLabel.isEmpty {
                        let conf = max(0.55, min(0.98, 1.0 - bestRaw * 1.15))
                        return (job.index, bestLabel, (conf * 100.0).rounded() / 100.0, newSource)
                    } else if job.hue == "red" {
                        return (job.index, "Red Action / End Button", 0.72, newSource)
                    } else if job.hue == "green" {
                        return (job.index, "Green Action / Confirm Button", 0.70, newSource)
                    }
                    return nil
                }
            }

            for await match in group {
                guard let (idx, label, conf, source) = match else { continue }
                updated[idx].ui.label = label
                updated[idx].ui.source = source
                updated[idx].ui.confidence = conf
            }
        }

        return updated
    }

    private func selectCandidateIndices(in elements: [StoredElement], maxCandidates: Int) -> [Int] {
        var indices: [Int] = []
        for (idx, item) in elements.enumerated() {
            let ui = item.ui
            guard ui.isInteractive else { continue }
            guard ui.frame.width >= 14, ui.frame.width <= 70,
                  ui.frame.height >= 14, ui.frame.height <= 70
            else { continue }
            let aspect = ui.frame.width / max(1.0, ui.frame.height)
            guard aspect >= 0.55 && aspect <= 1.85 else { continue }
            if ["close_button", "minimize_button", "zoom_button"].contains(ui.role) {
                continue
            }

            let trimmed = ui.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let isGeneric = trimmed.isEmpty
                || trimmed.caseInsensitiveCompare(ui.role) == .orderedSame
                || trimmed == "Icon Button"
                || trimmed == "button"
                || trimmed == "icon_button"
                || trimmed == "image"
                || UIFusionEngine.isGarbledIconOCR(trimmed)

            if isGeneric {
                indices.append(idx)
                if indices.count >= maxCandidates { break }
            }
        }
        return indices
    }

    private func ensurePrototypesBuilt() async {
        if prototypes != nil { return }

        let rendered: [(label: String, symbol: String, image: CGImage)] = await MainActor.run {
            Self.canonicalSymbols.compactMap { entry in
                guard let img = Self.renderSymbolPrototype(symbol: entry.symbol) else { return nil }
                return (entry.label, entry.symbol, img)
            }
        }

        var entries: [PrototypeEntry] = []
        entries.reserveCapacity(rendered.count)
        let req = GenerateImageFeaturePrintRequest()
        for item in rendered {
            if let fp = try? await req.perform(on: item.image) {
                entries.append(PrototypeEntry(label: item.label, symbol: item.symbol, featurePrint: fp))
            }
        }
        prototypes = entries
    }

    @MainActor
    private static func renderSymbolPrototype(symbol: String) -> CGImage? {
        let side = 64
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()

        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
                .applying(.init(paletteColors: [.black]))
            if let colored = base.withSymbolConfiguration(cfg) {
                let targetBox = NSRect(x: 15, y: 15, width: 34, height: 34)
                let repSize = colored.size
                let aspect = repSize.width / max(1.0, repSize.height)
                var drawRect = targetBox
                if aspect > 1.0 {
                    let h = targetBox.width / aspect
                    drawRect = NSRect(x: targetBox.minX, y: targetBox.midY - h / 2.0, width: targetBox.width, height: h)
                } else {
                    let w = targetBox.height * aspect
                    drawRect = NSRect(x: targetBox.midX - w / 2.0, y: targetBox.minY, width: w, height: targetBox.height)
                }
                colored.draw(in: drawRect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let raw = ctx.makeImage() else { return nil }
        return normalizeIconCrop(raw)?.silhouette ?? raw
    }

    /// Normalizes any cropped icon button (dark-on-light, light-on-dark, white-on-red, etc.)
    /// into a canonical dark-glyph-on-white 64x64 silhouette + extracts chromatic hue tag.
    public nonisolated static func normalizeIconCrop(_ img: CGImage) -> (silhouette: CGImage, bgHue: String, contrast: Double)? {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Sample the mid-outer ring (radius 19..25 from center) to identify button fill background
        var ringPixels: [(lum: Double, r: Double, g: Double, b: Double)] = []
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) - 31.5
                let dy = Double(y) - 31.5
                let dist = hypot(dx, dy)
                if dist >= 19.0 && dist <= 25.0 {
                    let i = (y * side + x) * 4
                    let r = Double(pixels[i])
                    let g = Double(pixels[i + 1])
                    let b = Double(pixels[i + 2])
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    ringPixels.append((lum, r, g, b))
                }
            }
        }
        guard !ringPixels.isEmpty else { return nil }
        ringPixels.sort { $0.lum < $1.lum }

        // Median quartile average ignores occasional overlapping border strokes or glyph tips
        let lo = ringPixels.count / 4
        let hi = max(lo + 1, (ringPixels.count * 3) / 4)
        var rSum = 0.0
        var gSum = 0.0
        var bSum = 0.0
        for k in lo..<hi {
            rSum += ringPixels[k].r
            gSum += ringPixels[k].g
            bSum += ringPixels[k].b
        }
        let sampleCount = Double(hi - lo)
        let bgR = rSum / sampleCount
        let bgG = gSum / sampleCount
        let bgB = bSum / sampleCount

        let hue: String
        if bgR > 155.0 && bgR > bgG * 1.55 && bgR > bgB * 1.55 {
            hue = "red"
        } else if bgG > 135.0 && bgG > bgR * 1.32 && bgG > bgB * 1.32 {
            hue = "green"
        } else if bgB > 145.0 && bgB > bgR * 1.35 {
            hue = "blue"
        } else {
            hue = "neutral"
        }

        var out = [UInt8](repeating: 255, count: side * side * 4)
        var maxDiff = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                let dx = Double(x) - 31.5
                let dy = Double(y) - 31.5
                if hypot(dx, dy) <= 23.0 {
                    let dr = Double(pixels[i]) - bgR
                    let dg = Double(pixels[i + 1]) - bgG
                    let db = Double(pixels[i + 2]) - bgB
                    let diff = sqrt(dr * dr + dg * dg + db * db)
                    if diff > maxDiff { maxDiff = diff }
                    let v = UInt8(max(0.0, min(255.0, 255.0 - diff * 1.6)))
                    out[i] = v
                    out[i + 1] = v
                    out[i + 2] = v
                    out[i + 3] = 255
                } else {
                    out[i] = 255
                    out[i + 1] = 255
                    out[i + 2] = 255
                    out[i + 3] = 255
                }
            }
        }

        // Ignore nearly blank/flat patches with no inner glyph contrast
        guard maxDiff >= 24.0 else { return nil }

        guard let outCtx = CGContext(
            data: &out,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let resultImg = outCtx.makeImage() else {
            return nil
        }

        return (resultImg, hue, maxDiff)
    }
}
