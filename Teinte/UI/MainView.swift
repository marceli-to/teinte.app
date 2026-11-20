import SwiftUI
import TeinteCore

/// The window: a transparent title bar ("Teinte" + view toggle), then sidebar and results,
/// or the import screen while the library is empty or a large import runs.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            if model.showsImportScreen {
                ImportScreen()
                    .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    if model.sidebarVisible {
                        Sidebar()
                            .frame(width: 232)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        Rectangle().fill(Theme.line).frame(width: 1)
                    }
                    ResultsView()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showsImportScreen)
        .animation(.easeInOut(duration: 0.2), value: model.sidebarVisible)
        .background(Theme.ground)
        .tint(Theme.accent)
        .containerBackground(Theme.ground, for: .window)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("Teinte")
                    .font(.title)
                    .foregroundStyle(Theme.ink)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
            if !model.showsImportScreen {
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .automatic) {
                    ViewModeToggle(mode: $model.viewMode)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for url in folders { Task { await model.addFolder(url) } }
            return !folders.isEmpty
        }
        .alert("Teinte", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}
