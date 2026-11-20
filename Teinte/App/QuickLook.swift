import AppKit
@preconcurrency import Quartz

/// Quick Look for the results. Space (or ⌘Y) opens the panel on the focused image; with several
/// selected, it shows those. The arrow keys keep working while the panel is up: they move through
/// the results (or through the selection), and the panel follows.
///
/// The panel finds its controller through the responder chain, which ends at the app delegate.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var model: AppModel?
    private var items: [UUID] = []

    static var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle() {
        guard let model else { return }
        if Self.isOpen {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        if model.focusedID == nil, let first = model.hits.first { model.click(first.id, kind: .plain) }
        guard model.focusedID != nil else { return }
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    /// The selection changed while the panel is open: show the new image.
    func selectionChanged() {
        guard Self.isOpen else { return }
        reload()
    }

    // MARK: Panel control (called through the app delegate)

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        reload()
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        items = []
    }

    private func reload() {
        guard let model else { return }
        let selected = model.selectedHits.map(\.id)
        items = selected.count > 1 ? selected : [model.focusedID ?? selected.first].compactMap { $0 }
        let panel = QLPreviewPanel.shared()!
        panel.reloadData()
        if let focused = model.focusedID, let i = items.firstIndex(of: focused) {
            panel.currentPreviewItemIndex = i
        }
    }

    // MARK: Data source

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated {
            guard items.indices.contains(index) else { return nil }
            return model?.resultURLs[items[index]]
        }
        return url.map { $0 as NSURL }
    }

    // MARK: Delegate

    /// Arrow keys step through the results; Space closes the panel, as in Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let keyCode = event.keyCode
        let shift = event.modifierFlags.contains(.shift)
        return MainActor.assumeIsolated { handleKey(keyCode, shift: shift) }
    }

    private func handleKey(_ keyCode: UInt16, shift: Bool) -> Bool {
        guard let model else { return false }
        let row = model.viewMode == .grid ? model.gridColumns : 1
        let offset: Int
        switch keyCode {
        case 123: offset = model.viewMode == .grid ? -1 : 0   // ←
        case 124: offset = model.viewMode == .grid ? 1 : 0    // →
        case 126: offset = -row                               // ↑
        case 125: offset = row                                // ↓
        case 49:                                              // Space
            QLPreviewPanel.shared().orderOut(nil)
            return true
        default: return false
        }
        guard offset != 0 else { return true }
        if items.count > 1 && !shift {
            // Several selected: step through the selection only, as Finder does.
            guard let current = model.focusedID.flatMap({ items.firstIndex(of: $0) }) else { return true }
            let next = (current + (offset > 0 ? 1 : -1) + items.count) % items.count
            model.focusedID = items[next]
        } else {
            model.moveFocus(by: offset, extend: shift)
        }
        return true
    }

    /// Zoom from and to the thumbnail would need its screen frame; a plain fade is fine.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        .zero
    }
}

/// Owns the Quick Look controller and answers the panel's responder-chain questions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let quickLook = QuickLookController()

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.begin(panel) }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.end(panel) }
}
