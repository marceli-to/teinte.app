#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders the main window to PNGs for design reviews, without screen-recording permission.
///
///     TEINTE_SNAPSHOT=1 TEINTE_QUERY="blue images with people" open Teinte.app
///
/// Writes grid/list (light and dark) PNGs to the app container's tmp folder and logs the paths.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard env["TEINTE_SNAPSHOT"] != nil else { return }
        NSLog("SNAPSHOT start")
        Task {
            try? await Task.sleep(for: .seconds(4))
            if let q = env["TEINTE_QUERY"] { model.queryText = q }
            try? await Task.sleep(for: .seconds(3))
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
            if env["TEINTE_SNAPSHOT_SCENE"] == "details" {
                await details(model: model, out: out)
                return
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                for mode in [ViewMode.grid, .list] {
                    model.viewMode = mode
                    model.sidebarVisible = mode == .grid
                    try? await Task.sleep(for: .seconds(1.5))
                    let name = "teinte-\(mode.rawValue)-\(appearance == .aqua ? "light" : "dark").png"
                    write(to: out.appendingPathComponent(name))
                    scrollResults(by: 260)
                    try? await Task.sleep(for: .seconds(0.8))
                    write(to: out.appendingPathComponent(name.replacingOccurrences(of: ".png", with: "-scrolled.png")))
                    scrollResults(by: -260)
                }
                model.forceImportScreen = true
                try? await Task.sleep(for: .seconds(1.5))
                write(to: out.appendingPathComponent("teinte-import-\(appearance == .aqua ? "light" : "dark").png"))
                model.forceImportScreen = false
            }
            NSApp.appearance = nil
            model.sidebarVisible = true
            model.viewMode = .grid
            NSLog("SNAPSHOT-DONE \(out.path)")
        }
    }

    /// Selection and the details panel: one image (light, dark), several images, and the list.
    private static func details(model: AppModel, out: URL) async {
        let index = Int(ProcessInfo.processInfo.environment["TEINTE_SNAPSHOT_PICK"] ?? "0") ?? 0
        guard model.hits.indices.contains(index) else { NSLog("SNAPSHOT-DONE no hits"); return }
        model.click(model.hits[index].id, kind: .plain)
        model.inspectorVisible = true
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(2.5))
            write(to: out.appendingPathComponent("teinte-details-\(appearance == .aqua ? "light" : "dark").png"))
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        for hit in model.hits.prefix(index + 6).dropFirst(index + 1) { model.click(hit.id, kind: .toggle) }
        try? await Task.sleep(for: .seconds(1.5))
        write(to: out.appendingPathComponent("teinte-details-multi.png"))
        model.viewMode = .list
        try? await Task.sleep(for: .seconds(1.5))
        write(to: out.appendingPathComponent("teinte-details-list.png"))
        NSApp.appearance = nil
        model.viewMode = .grid
        NSLog("SNAPSHOT-DONE \(out.path)")
    }

    /// Scrolls the largest scroll view (the results) by `dy` points.
    private static func scrollResults(by dy: CGFloat) {
        guard let root = NSApp.windows.first(where: \.isVisible)?.contentView else { return }
        var views: [NSScrollView] = []
        func collect(_ v: NSView) {
            if let s = v as? NSScrollView { views.append(s) }
            v.subviews.forEach(collect)
        }
        collect(root)
        guard let scroll = views.max(by: { $0.frame.width < $1.frame.width }) else { return }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(clip.bounds.origin.y + dy, -scroll.contentInsets.top)))
        scroll.reflectScrolledClipView(clip)
    }

    private static func write(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSLog("SNAPSHOT no rep"); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("SNAPSHOT \(url.path)")
    }
}
#endif
