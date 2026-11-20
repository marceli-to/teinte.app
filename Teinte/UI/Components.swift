import SwiftUI
import TeinteCore

/// A colour dot. Light swatches get a hairline ring so they stay visible on the light ground;
/// in dark mode every swatch gets one, so dark swatches stay visible on the ink ground.
struct SwatchDot: View {
    let colour: Color
    var isLight: Bool
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(colour)
            .overlay {
                if isLight || scheme == .dark { Circle().strokeBorder(Theme.ring, lineWidth: 1) }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension SwatchDot {
    init(bucket: ColourBucket, size: CGFloat = 12) {
        self.init(colour: Theme.swatch(bucket), isLight: bucket.isLight, size: size)
    }

    init(oklab: OKLab, size: CGFloat = 12) {
        self.init(colour: Theme.swatch(oklab), isLight: oklab.l > 0.86 && oklab.chroma < 0.06, size: size)
    }
}

/// A focus ring drawn around custom controls when they have keyboard focus.
struct FocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    let focused: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if focused { shape.inset(by: -3).stroke(Theme.accent.opacity(0.55), lineWidth: 2) }
        }
    }
}

// MARK: - Chip

/// "mostly blue ×". The whole chip removes the filter; it's one focusable button.
struct ChipButton: View {
    let chip: FilterChip
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 8) {
                leading
                Text(chip.title).font(.bodyStrong).foregroundStyle(Theme.ink)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(ChipStyle())
        .help("Remove this filter")
        .accessibilityLabel("Remove filter: \(chip.title)")
    }

    private struct ChipStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

        private struct Styled: View {
            let configuration: Configuration
            @State private var hovering = false
            @Environment(\.isFocused) private var focused

            var body: some View {
                configuration.label
                    .padding(.leading, 12)
                    .padding(.trailing, 14)
                    .frame(height: 32)
                    .background(Theme.field, in: Capsule())
                    .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1).opacity(hovering ? 1 : 0) }
                    .modifier(FocusRing(shape: Capsule(), focused: focused))
                    .scaleEffect(configuration.isPressed ? 0.97 : 1)
                    .onHover { hovering = $0 }
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            }
        }
    }

    @ViewBuilder private var leading: some View {
        switch chip.kind {
        case .colour(let f):
            SwatchDot(bucket: f.bucket, size: 12)
                .overlay {
                    if f.mode == .without {
                        Rectangle().fill(Theme.ink).frame(width: 15, height: 1.5).rotationEffect(.degrees(-45))
                    }
                }
        case .people:
            Image(systemName: "person").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
        case .faces:
            Image(systemName: "face.smiling").font(.system(size: 12)).foregroundStyle(Theme.ink)
        case .text:
            Image(systemName: "textformat").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink)
        case .orientation(let o):
            Image(systemName: o == .portrait ? "rectangle.portrait" : o == .square ? "square" : "rectangle")
                .font(.system(size: 11)).foregroundStyle(Theme.ink)
        case .label, .freeText:
            EmptyView()
        }
    }
}

// MARK: - Buttons

/// Slight press feedback for custom controls.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// "Save as look": accent outline pill.
struct AccentOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.bodyStrong)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(Theme.accent.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1.5))
                .opacity(enabled ? 1 : 0.4)
                .modifier(FocusRing(shape: Capsule(), focused: focused))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// "Choose folder…": solid ink pill.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.manrope(15, .bold))
                .foregroundStyle(Theme.onInk)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(Theme.ink.opacity(configuration.isPressed ? 0.8 : hovering ? 0.9 : 1), in: Capsule())
                .modifier(FocusRing(shape: Capsule(), focused: focused))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - Grid / list toggle

struct ViewModeToggle: View {
    @Binding var mode: ViewMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.grid, symbol: "square.grid.2x2", label: "Grid")
            segment(.list, symbol: "line.3.horizontal", label: "List")
        }
        .padding(3)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private func segment(_ value: ViewMode, symbol: String, label: String) -> some View {
        Segment(selected: mode == value, symbol: symbol, label: label) {
            withAnimation(.easeOut(duration: 0.15)) { mode = value }
        }
    }

    private struct Segment: View {
        let selected: Bool
        let symbol: String
        let label: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected || hovering ? Theme.ink : Theme.muted)
                    .frame(width: 34, height: 26)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 7).fill(Theme.field)
                                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .onHover { hovering = $0 }
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

enum ViewMode: String, CaseIterable {
    case grid, list
}

// MARK: - Layout

/// Lays children out left to right and wraps to a new line when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
