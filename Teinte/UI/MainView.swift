import SwiftUI
import Translation
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
                    if model.inspectorVisible {
                        Rectangle().fill(Theme.line).frame(width: 1)
                        DetailsPanel()
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.showsImportScreen)
        .animation(.easeInOut(duration: 0.2), value: model.sidebarVisible)
        .animation(.easeInOut(duration: 0.22), value: model.inspectorVisible)
        .background(Theme.ground)
        .tint(Theme.accent)
        .containerBackground(Theme.ground, for: .window)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(verbatim: "Teinte")
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
                ToolbarItem(placement: .automatic) {
                    InspectorToggle(isOn: $model.inspectorVisible)
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
        // The German → English download, when asked for in Settings or under the search bar.
        .translationTask(model.translationDownload) { session in
            // The session lives only for this closure; nothing else touches it.
            nonisolated(unsafe) let session = session
            try? await session.prepareTranslation()
            await model.translationDownloadFinished()
        }
        .alert("Teinte", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}

/// The toolbar button that shows and hides the details panel.
struct InspectorToggle: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isOn ? Theme.accent : Theme.ink)
                .frame(width: 32, height: 28)
                .background(Theme.selection.opacity(hovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .help(isOn ? "Hide details (⌘I)" : "Show details (⌘I)")
        .accessibilityLabel(isOn ? "Hide details" : "Show details")
    }
}
