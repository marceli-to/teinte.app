import SwiftUI
import TeinteCore
import UniformTypeIdentifiers

/// LIBRARY · SAVED LOOKS · FOLDERS. The selection drives the scope or restores a look.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    /// The look being dragged, and the order shown while it moves (nil when no drag is in progress).
    @State private var draggedLook: UUID?
    @State private var dragOrder: [LookInfo]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                section("Library") {
                    row(.all, title: "All images", count: model.stats.total)
                    row(.recent, title: "Recently added", count: model.stats.recent)
                }
                if !model.looks.isEmpty {
                    section("Saved looks") {
                        VStack(alignment: .leading, spacing: Self.lookSpacing) {
                            ForEach(dragOrder ?? model.looks) { look in lookRow(look) }
                        }
                        .onDrop(of: [.text], delegate: LookDropDelegate(
                            dragged: $draggedLook, order: $dragOrder,
                            rowPitch: Self.lookRowHeight + Self.lookSpacing,
                            commit: { ids in
                                // Keep the shown order until the model has the saved one, so the rows don't jump.
                                Task { await model.reorderLooks(ids); dragOrder = nil }
                            }))
                    }
                }
                section("Folders") {
                    ForEach(model.folders) { folder in folderRow(folder) }
                    Button { model.chooseFolder() } label: {
                        Label("Add folder…", systemImage: "plus")
                            .labelStyle(AddLabelStyle())
                    }
                    .buttonStyle(SidebarRowStyle(selected: false))
                    .help("Add a folder of images (⌘O)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
        .accessibilityLabel("Sidebar")
    }

    // MARK: Sections

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .sectionLabel()
                .padding(.leading, 12)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row(_ item: SidebarItem, title: LocalizedStringKey, count: Int) -> some View {
        Button { model.select(item) } label: {
            HStack {
                Text(title).font(.sidebarItem).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(count.grouped).font(.mono(11)).foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(SidebarRowStyle(selected: model.selection == item))
        .accessibilityLabel("\(title), \(count) images")
        .accessibilityAddTraits(model.selection == item ? .isSelected : [])
    }

    private func lookRow(_ look: LookInfo) -> some View {
        let selected = model.selection == .look(look.id)
        let index = model.looks.firstIndex(of: look) ?? 0
        return Group {
            if renaming == look.id {
                HStack(spacing: 11) {
                    lookDot(selected: selected)
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.sidebarItem)
                        .focused($renameFocused)
                        .onSubmit { commitRename(look.id) }
                        .onKeyPress(.escape) { renaming = nil; return .handled }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 1.5))
                .onAppear { renameFocused = true }
                .onChange(of: renameFocused) { if !renameFocused { commitRename(look.id) } }
            } else {
                Button { model.select(.look(look.id)) } label: {
                    HStack(spacing: 11) {
                        lookDot(selected: selected)
                        Text(look.name).font(.sidebarItem).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(SidebarRowStyle(selected: selected || draggedLook == look.id))
                .onDrag {
                    draggedLook = look.id
                    dragOrder = model.looks
                    return NSItemProvider(object: look.id.uuidString as NSString)
                }
                .accessibilityLabel("Saved look: \(look.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu {
                    Button("Rename…") { renameText = look.name; renaming = look.id }
                    Button("Move Up") { Task { await model.moveLook(look.id, by: -1) } }
                        .disabled(index == 0)
                    Button("Move Down") { Task { await model.moveLook(look.id, by: 1) } }
                        .disabled(index == model.looks.count - 1)
                    Divider()
                    Button("Delete Look", role: .destructive) { Task { await model.deleteLook(look.id) } }
                }
            }
        }
    }

    private static let lookRowHeight: CGFloat = 32
    private static let lookSpacing: CGFloat = 2

    private func lookDot(selected: Bool) -> some View {
        Circle()
            .fill(selected ? Theme.accent : .clear)
            .overlay { if !selected { Circle().strokeBorder(Theme.muted, lineWidth: 1.2) } }
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }

    private func folderRow(_ folder: AppModel.FolderRow) -> some View {
        let item = SidebarItem.folder(folder.id)
        return Button { model.select(item) } label: {
            HStack {
                Text(folder.info.displayName)
                    .font(.sidebarItem)
                    .foregroundStyle(folder.available ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !folder.available {
                    Text("unavailable").font(.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            .opacity(folder.available ? 1 : 0.6)
        }
        .buttonStyle(SidebarRowStyle(selected: model.selection == item))
        .help(folder.info.path)
        .accessibilityLabel(folder.available ? "Folder: \(folder.info.displayName)"
                                             : "Folder: \(folder.info.displayName), unavailable")
        .accessibilityAddTraits(model.selection == item ? .isSelected : [])
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.info.path)])
            }
            .disabled(!folder.available)
            Divider()
            Button("Remove from Teinte", role: .destructive) { Task { await model.removeFolder(folder.id) } }
        }
    }

    private func commitRename(_ id: UUID) {
        guard renaming == id else { return }
        renaming = nil
        let name = renameText
        Task { await model.renameLook(id, to: name) }
    }
}

/// Drag-to-reorder for saved looks. One delegate covers the whole list and picks the slot from the
/// pointer's height, so the gaps between rows count too. The rows move live; leaving the list puts
/// them back, and only a drop inside it saves the new order.
private struct LookDropDelegate: DropDelegate {
    @Binding var dragged: UUID?
    @Binding var order: [LookInfo]?
    let rowPitch: CGFloat
    let commit: ([UUID]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) { move(to: info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard dragged != nil else { return nil }
        move(to: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Dropped elsewhere or cancelled: no drop arrives here, so put the rows back now.
        withAnimation(.easeOut(duration: 0.15)) { order = nil }
        dragged = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard dragged != nil, let order else { return false }
        commit(order.map(\.id))
        dragged = nil
        return true
    }

    private func move(to location: CGPoint) {
        guard let dragged, var rows = order, let from = rows.firstIndex(where: { $0.id == dragged }) else { return }
        let to = min(max(Int(location.y / rowPitch), 0), rows.count - 1)
        guard to != from else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            rows.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            order = rows
        }
    }
}

/// A sidebar row: white rounded background when selected, a lighter one on hover, focus ring for the keyboard.
struct SidebarRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, selected: selected)
    }

    private struct Styled: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .padding(.horizontal, 12)
                .frame(height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.selection.opacity(selected ? 1 : configuration.isPressed ? 0.8 : hovering ? 0.5 : 0))
                }
                .modifier(FocusRing(shape: RoundedRectangle(cornerRadius: 8), focused: focused))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

private struct AddLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title.font(.sidebarItem)
        }
        .foregroundStyle(Theme.muted)
    }
}
