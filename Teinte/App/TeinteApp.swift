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
                Toggle("Show Analysis Details", isOn: $model.showDebug)
                    .keyboardShortcut("d", modifiers: [.option, .command])
                Divider()
            }
        }
    }
}
