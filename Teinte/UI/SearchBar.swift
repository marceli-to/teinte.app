import SwiftUI
import TeinteCore

/// The hero search field: soft field tone, 12 pt radius, a quiet ink hairline (stronger on hover/focus), 46 pt tall. ⌘K focuses it, Esc clears it.
struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
            // Own placeholder: the field's prompt can't be smaller than the typed text.
            TextField("Search", text: $model.queryText, prompt: Text(""))
                .background(alignment: .leading) {
                    if model.queryText.isEmpty {
                        Text("Describe what you’re looking for")
                            .font(.sans(14, .regular))
                            .foregroundStyle(Theme.muted.opacity(0.75))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .textFieldStyle(.plain)
                .font(.sans(16, .medium))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onKeyPress(.escape) {
                    guard model.hasSearch else { return .ignored }
                    model.clearSearch()
                    return .handled
                }
                .accessibilityLabel("Search images")
                .accessibilityHint("Describe the images, for example blue images with people")
            if model.hasSearch {
                Button { model.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted.opacity(0.7))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(IconButtonStyle(cornerRadius: 12))
                .help("Clear (Esc)")
                .accessibilityLabel("Clear search")
            }
            KeyHint(text: "⌘K")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.ink.opacity(focused ? 0.38 : hovering ? 0.26 : 0.16), lineWidth: focused ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { focused = true }
        .onHover { hovering = $0 }
        .onAppear { focused = true }
        .onChange(of: model.focusSearchToken) { focused = true }
    }
}

struct KeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.mono(11, .regular))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// "understood as  [mostly blue ×] [with people ×]          (Save as look)"
struct ChipsRow: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            FlowLayout(spacing: 10, lineSpacing: 8) {
                Text("understood as")
                    .font(.mono(13))
                    .foregroundStyle(Theme.muted)
                    .padding(.trailing, 6)
                    .frame(height: 32)
                ForEach(model.active.chips) { chip in
                    ChipButton(chip: chip) { model.remove(chip) }
                }
                if model.active.chips.isEmpty {
                    Text("nothing yet")
                        .font(.mono(13))
                        .foregroundStyle(Theme.muted.opacity(0.7))
                        .frame(height: 32)
                }
                if model.suggestsTranslationDownload {
                    Button { model.downloadTranslation() } label: {
                        Label("Download German translation", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(LinkStyle(size: 12, colour: Theme.accent))
                    .frame(height: 32)
                    .help("Words Teinte doesn’t know yet stay in German. Apple’s translation fixes that; it runs on this Mac.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Save as look") {
                name = model.suggestedLookName
                naming = true
            }
            .buttonStyle(AccentOutlineButtonStyle())
            .fixedSize()
            .disabled(!model.canSaveLook)
            .help("Keep this search in the sidebar (⌘S)")
            .popover(isPresented: $naming, arrowEdge: .bottom) { saveForm }
            .onChange(of: model.saveLookRequest) {
                guard model.canSaveLook else { return }
                name = model.suggestedLookName
                naming = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Understood as")
    }

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as look").font(.title).foregroundStyle(Theme.ink)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .frame(width: 260)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { naming = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }

    private func save() {
        naming = false
        let n = name
        Task { await model.saveLook(named: n) }
    }
}
