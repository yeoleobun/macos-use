import Foundation

/// Thread-safe LRU ring buffer storing recent UI perception snapshots (`e1..eN`) and image transforms.
public actor SnapshotStore {
    public static let shared = SnapshotStore()

    private let maxSnapshots: Int
    private var order: [String] = []
    private var snapshots: [String: UISnapshot] = [:]
    private var latestSnapshotID: String?
    private var latestTransform: CaptureTransform?
    private var sequence: Int = 0

    public init(maxSnapshots: Int = 16) {
        self.maxSnapshots = max(1, maxSnapshots)
    }

    @discardableResult
    public func save(
        scopeDescription: String,
        ownerPID: Int32?,
        windowID: UInt32?,
        transform: CaptureTransform,
        axTrusted: Bool,
        elements: [StoredElement]
    ) -> UISnapshot {
        sequence += 1
        let snapID = "snap_\(sequence)"
        let snapshot = UISnapshot(
            snapshotID: snapID,
            scopeDescription: scopeDescription,
            ownerPID: ownerPID,
            windowID: windowID,
            transform: transform,
            axTrusted: axTrusted,
            elements: elements
        )
        snapshots[snapID] = snapshot
        order.append(snapID)
        latestSnapshotID = snapID
        latestTransform = transform

        while order.count > maxSnapshots {
            let evicted = order.removeFirst()
            snapshots.removeValue(forKey: evicted)
        }
        return snapshot
    }

    public func updateTransformOnly(_ transform: CaptureTransform) {
        latestTransform = transform
    }

    public func currentTransform() -> CaptureTransform? {
        latestTransform
    }

    public func snapshot(id: String? = nil) -> UISnapshot? {
        if let id, !id.isEmpty {
            return snapshots[id]
        }
        guard let latestSnapshotID else { return nil }
        return snapshots[latestSnapshotID]
    }

    public func resolveElement(id elementID: String, snapshotID: String? = nil) throws -> (UISnapshot, StoredElement) {
        guard let snap = snapshot(id: snapshotID) else {
            throw MacOSUseError.targetNotFound(
                "No UI snapshot cached yet. Call observe_screen or inspect_ui first."
            )
        }

        let normalized = normalizeElementID(elementID)
        if let found = snap.elements.first(where: {
            $0.ui.id.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return (snap, found)
        }

        if let indexInt = Int(normalized.dropFirst()),
           let byIndex = snap.elements.first(where: { $0.ui.index == indexInt })
        {
            return (snap, byIndex)
        }

        throw MacOSUseError.targetNotFound(
            "Element '\(elementID)' not found in snapshot \(snap.snapshotID) (available: e1..e\(snap.elements.count))."
        )
    }

    public func findElements(
        query: String? = nil,
        role: String? = nil,
        interactiveOnly: Bool = false,
        snapshotID: String? = nil,
        limit: Int = 25
    ) -> (UISnapshot?, [StoredElement]) {
        guard let snap = snapshot(id: snapshotID) else {
            return (nil, [])
        }
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let r = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        let scored: [(score: Int, elem: StoredElement)] = snap.elements.compactMap { item in
            let ui = item.ui
            if interactiveOnly && !ui.isInteractive { return nil }
            if !r.isEmpty && !ui.role.lowercased().contains(r) && !ui.rawRole.lowercased().contains(r) {
                return nil
            }
            if q.isEmpty {
                return (1, item)
            }

            let labelLower = ui.label.lowercased()
            let valLower = (ui.value ?? "").lowercased()
            if labelLower == q || valLower == q {
                return (100, item)
            } else if labelLower.hasPrefix(q) {
                return (70, item)
            } else if labelLower.contains(q) || valLower.contains(q) {
                return (40, item)
            }
            return nil
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.elem.ui.isInteractive != rhs.elem.ui.isInteractive {
                return lhs.elem.ui.isInteractive
            }
            return lhs.elem.ui.index < rhs.elem.ui.index
        }
        return (snap, Array(sorted.prefix(max(1, limit)).map(\.elem)))
    }

    private func normalizeElementID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        if let idx = Int(s) {
            return "e\(idx)"
        }
        return s
    }
}
