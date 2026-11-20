import SwiftUI

@main
struct TeinteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Teinte") {
            PrototypeView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
        }
    }
}
