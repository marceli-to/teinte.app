import AppKit
import SwiftUI

@main
struct TeinteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Teinte") {
            MainView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                #if DEBUG
                .onAppear { DebugSnapshot.runIfRequested(model: model) }
                #endif
        }
        .defaultSize(width: 1280, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save as Look…") { model.saveLookRequest += 1 }
                    .keyboardShortcut("s")
                    .disabled(!model.canSaveLook || model.showsImportScreen)
            }
            // Copy and Select All act on images unless a text field has focus.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button("Copy") {
                    if Self.textHasFocus || model.selectedIDs.isEmpty {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else {
                        model.copySelection()
                    }
                }
                .keyboardShortcut("c")
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button("Select All") {
                    if Self.textHasFocus {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    } else {
                        model.selectAll()
                    }
                }
                .keyboardShortcut("a")
                Button("Deselect All") { model.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.shift, .command])
                    .disabled(model.selectedIDs.isEmpty)
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { model.focusSearchToken += 1 }
                    .keyboardShortcut("k")
            }
            CommandGroup(before: .sidebar) {
                Button("as Grid") { model.viewMode = .grid }
                    .keyboardShortcut("1")
                Button("as List") { model.viewMode = .list }
                    .keyboardShortcut("2")
                Divider()
                Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                Button(model.inspectorVisible ? "Hide Details" : "Show Details") { model.toggleInspector() }
                    .keyboardShortcut("i")
                Toggle("Show Analysis Details", isOn: $model.showDebug)
                    .keyboardShortcut("d", modifiers: [.option, .command])
                Divider()
            }
        }
    }

    /// A text field or text view is being edited (the search bar, a rename field).
    @MainActor static var textHasFocus: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}
