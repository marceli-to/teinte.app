import SwiftUI
import TeinteCore

/// Teinte › Settings…: the search language.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Search language", selection: $model.searchLanguage) {
                Text("English").tag(SearchLanguage.english)
                Text("German").tag(SearchLanguage.german)
            }
            Text("Type searches in this language. German searches are turned into English on this Mac before Teinte reads them. Text in quotes is searched as written.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.searchLanguage == .german {
                LabeledContent("Translation") {
                    switch model.translationStatus {
                    case .installed:
                        Text("Apple Translation, installed")
                    case .needsDownload:
                        HStack {
                            Text("Built-in word list")
                            Button("Download…") { model.downloadTranslation() }
                        }
                    case .unsupported, .unknown:
                        Text("Built-in word list")
                    }
                }
                if model.translationStatus == .needsDownload {
                    Text("Teinte knows the words for colours, people, looks and common subjects. Apple’s German–English translation handles everything else. It’s a one-time download and runs on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.refreshTranslation() }
    }
}
