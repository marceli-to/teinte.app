import AppKit
import SwiftUI

@main
struct TeinteApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Teinte") {
            MainView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear(perform: connectQuickLook)
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
                Divider()
                Button("Export to Folder…") { model.export(.folder) }
                    .keyboardShortcut("e", modifiers: [.shift, .command])
                    .disabled(!model.canExport)
                Button("Export as Zip…") { model.export(.zip) }
                    .keyboardShortcut("e", modifiers: [.option, .shift, .command])
                    .disabled(!model.canExport)
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
            // Everything the result context menu does, for the keyboard.
            CommandMenu("Image") {
                Button("Quick Look") { model.toggleQuickLook() }
                    .keyboardShortcut("y")
                    .disabled(model.hits.isEmpty || model.showsImportScreen)
                Button("Find Similar") { if let id = model.focusedID { model.findSimilar(id) } }
                    .keyboardShortcut("l")
                    .disabled(model.focusedID == nil)
                Button("Show in Finder") { model.reveal(model.selectedHits.map(\.id)) }
                    .keyboardShortcut("r", modifiers: [.shift, .command])
                    .disabled(model.selectedIDs.isEmpty)
            }
            // The sidebar: step through it, and what its context menus do.
            CommandMenu("Library") {
                Button("Previous Item") { model.selectAdjacentSidebarItem(-1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                    .disabled(model.showsImportScreen)
                Button("Next Item") { model.selectAdjacentSidebarItem(1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                    .disabled(model.showsImportScreen)
                Divider()
                Button("Rename Look…") { model.renamingLook = model.selectedLook?.id }
                    .disabled(model.selectedLook == nil)
                Button("Move Look Up") { if let l = model.selectedLook { Task { await model.moveLook(l.id, by: -1) } } }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .option, .command])
                    .disabled(model.selectedLook == nil || model.selectedLook?.id == model.looks.first?.id)
                Button("Move Look Down") { if let l = model.selectedLook { Task { await model.moveLook(l.id, by: 1) } } }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .option, .command])
                    .disabled(model.selectedLook == nil || model.selectedLook?.id == model.looks.last?.id)
                Divider()
                Button("Show Folder in Finder") {
                    if let f = model.selectedFolder {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.info.path)])
                    }
                }
                .disabled(model.selectedFolder?.available != true)
                Button(model.selectedLook != nil ? "Delete Look…" : "Remove Folder…") {
                    // Typed in a text field, ⌘⌫ deletes to the start of the line; chosen from the menu, it acts.
                    if Self.textHasFocus && NSApp.currentEvent?.type == .keyDown {
                        NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                    } else {
                        model.requestDeleteSidebarItem()
                    }
                }
                .keyboardShortcut(.delete)
                .disabled(!model.canDeleteSidebarItem)
            }
        }

        Settings {
            // The download prompt itself is attached to the main window (MainView).
            SettingsView()
                .environment(model)
        }
    }

    private func connectQuickLook() {
        let quickLook = appDelegate.quickLook
        quickLook.model = model
        model.toggleQuickLook = { quickLook.toggle() }
        model.onSelectionChange = { quickLook.selectionChanged() }
    }

    /// A text field or text view is being edited (the search bar, a rename field).
    @MainActor static var textHasFocus: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}
