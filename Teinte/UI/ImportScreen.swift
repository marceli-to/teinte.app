import SwiftUI
import TeinteCore

/// "Looking at your images": the big counter, one calm sentence, the progress line, the library by colour,
/// and the drop zone. With no folders yet it's only the welcome and the drop zone.
struct ImportScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.folders.isEmpty {
                    welcome
                } else {
                    progress
                }
                DropZone(title: model.folders.isEmpty ? "Drop folders here" : "Drop more folders here")
                    .padding(.top, model.folders.isEmpty ? 44 : 40)
                if !model.folders.isEmpty, model.stats.total > 0 {
                    Button("Browse while it works") { model.importDismissed = true }
                        .buttonStyle(LinkStyle())
                        .padding(.top, 22)
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 40)
            .padding(.top, 72)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    // MARK: Welcome (no folders)

    private var welcome: some View {
        VStack(spacing: 18) {
            Text("Welcome to Teinte").sectionLabel()
            Text("Find images by describing them.")
                .font(.display(44))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Add a folder. Teinte notes colours, people, objects and scenes once, so every search after that is instant.")
                .font(.sans(18, .regular))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 470)
        }
    }

    // MARK: Progress

    private var progress: some View {
        let p = model.progress
        return VStack(spacing: 0) {
            Text("Looking at your images").sectionLabel()
            HStack(alignment: .lastTextBaseline, spacing: 14) {
                Text(p.done.grouped)
                    .font(.display(104))
                    .tracking(-3)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: p.done)
                Text("of \(p.total.grouped)")
                    .font(.sans(24, .regular))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(p.done) of \(p.total) images analysed")

            Text("Teinte notes colours, people, objects and scenes once, so every search after this is instant.")
                .font(.sans(18, .regular))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 440)
                .padding(.top, 20)

            ProgressLine(fraction: p.total > 0 ? CGFloat(p.done) / CGFloat(p.total) : 0)
                .padding(.top, 44)
            HStack(alignment: .firstTextBaseline) {
                Text(eta).lineLimit(1)
                Spacer(minLength: 16)
                Text(model.folders.map(\.info.displayName).prefix(3).joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.mono(13))
            .foregroundStyle(Theme.muted)
            .padding(.top, 14)

            if !model.stats.band.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("your library so far, by colour")
                        .font(.mono(13))
                        .foregroundStyle(Theme.muted)
                    ColourBandView(colours: model.stats.band)
                        .frame(height: 56)
                }
                .padding(.top, 48)
            }
        }
    }

    private var eta: String {
        let p = model.progress
        guard p.isRunning else { return p.done < p.total ? "paused" : "done" }
        guard let s = p.remainingSeconds else { return "starting…" }
        if s < 60 { return "less than a minute left" }
        if s < 3600 { return "~\(Int((s / 60).rounded())) min left" }
        return String(format: "~%.1f h left", s / 3600)
    }
}

/// Solid accent up to a dot, dashed after.
struct ProgressLine: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = w * min(max(fraction, 0), 1)
            let mid = geo.size.height / 2
            ZStack(alignment: .leading) {
                Path { p in
                    p.move(to: CGPoint(x: min(x + 10, w), y: mid))
                    p.addLine(to: CGPoint(x: w, y: mid))
                }
                .stroke(Theme.muted.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                Capsule().fill(Theme.accent).frame(width: x, height: 3)
                Circle().fill(Theme.accent).frame(width: 11, height: 11)
                    .offset(x: x - 5.5)
            }
            .animation(.easeOut(duration: 0.4), value: fraction)
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// The library's dominant colours as a band of equal stripes.
struct ColourBandView: View {
    let colours: [OKLab]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colours.enumerated()), id: \.offset) { _, c in
                Rectangle().fill(Theme.swatch(c))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ring, lineWidth: 0.5))
        .accessibilityElement()
        .accessibilityLabel("The colours of your library so far")
    }
}

/// Dashed drop zone with "Choose folder…". Highlights while a folder is dragged over it.
struct DropZone: View {
    @Environment(AppModel.self) private var model
    let title: String
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.sans(19, .semibold)).foregroundStyle(Theme.ink)
                Text("Your images never leave this Mac.").font(.sans(16, .regular)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
            Button("Choose folder…") { model.chooseFolder() }
                .buttonStyle(InkButtonStyle())
                .help("Add a folder of images (⌘O)")
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.accent.opacity(targeted ? 0.06 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(targeted ? Theme.accent : Theme.muted.opacity(0.55),
                              style: StrokeStyle(lineWidth: targeted ? 1.5 : 1, dash: [4, 4]))
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for url in folders { Task { await model.addFolder(url) } }
            return !folders.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

/// A quiet text link with hover underline.
struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.mono(13))
                .foregroundStyle(hovering || focused ? Theme.ink : Theme.muted)
                .underline(hovering || focused)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}
