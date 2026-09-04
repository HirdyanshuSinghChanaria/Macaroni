import SwiftUI

/// The design system: one place for every color, size and reusable control,
/// so the panel and the review window stay consistent.
///
/// Deliberately a fixed dark palette rather than semantic system colors — the
/// panel is designed as a dark instrument, the way Stats and iStat Menus are.
enum DS {
    static let panelWidth: CGFloat = 340

    // Surfaces
    static let panel = Color(red: 0.102, green: 0.102, blue: 0.114)
    static let headerTint = Color.white.opacity(0.025)
    static let footerTint = Color.black.opacity(0.18)
    static let control = Color.white.opacity(0.05)
    static let controlStroke = Color.white.opacity(0.07)
    static let panelStroke = Color.white.opacity(0.09)
    static let rule = Color.white.opacity(0.06)
    static let track = Color.white.opacity(0.13)

    // Text
    static let text = Color(white: 0.949)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.36)
    static let textFaint = Color.white.opacity(0.28)

    // Accents — same chroma, different hue
    static let accent = Color(red: 0.431, green: 0.659, blue: 1.0)
    static let accentSoft = Color(red: 0.431, green: 0.659, blue: 1.0).opacity(0.16)
    static let green = Color(red: 0.290, green: 0.831, blue: 0.627)
    static let amber = Color(red: 0.941, green: 0.702, blue: 0.302)
    static let danger = Color(red: 0.824, green: 0.271, blue: 0.227)

    // Type
    static func label(_ size: CGFloat = 11.5) -> Font { .system(size: size) }
    static func mono(_ size: CGFloat = 10.5) -> Font { .system(size: size, design: .monospaced) }
    static let sectionLabel = Font.system(size: 9.5, weight: .semibold)

    /// Short relative age: 4s / 12m / 3h / 2d.
    static func shortAge(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

// MARK: - Section header

/// "OUTPUT ──────────── trailing" — the hairline rule keeps sections apart
/// without spending a full divider's worth of vertical space.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(DS.sectionLabel)
                .kerning(0.7)
                .foregroundStyle(DS.textTertiary)
            Rectangle()
                .fill(DS.rule)
                .frame(height: 1)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

// MARK: - Slider

/// A thin track with a small round knob — the system Slider is far too tall
/// and too blue for a dense panel.
struct ThinSlider: View {
    @Binding var value: Double
    var tint: Color = DS.accent
    var trackHeight: CGFloat = 4
    var knobSize: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.track)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(tint)
                    .frame(width: width * clamped, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
                    .offset(x: min(max(width * clamped - knobSize / 2, 0), width - knobSize))
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        value = min(max(drag.location.x / width, 0), 1)
                    }
            )
        }
        .frame(height: knobSize + 3)
    }
}

// MARK: - Toggle

struct PillToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? DS.accent : Color.white.opacity(0.14))
            .frame(width: 28, height: 16)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white.opacity(isOn ? 1 : 0.85))
                    .frame(width: 12, height: 12)
                    .padding(2)
            }
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
            .animation(.easeOut(duration: 0.14), value: isOn)
    }
}

// MARK: - Meter

/// A proportional bar. `segments` are (fraction, color) drawn left to right.
struct MeterBar: View {
    var segments: [(Double, Color)]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.1)
                        .frame(width: geo.size.width * min(max(segment.0, 0), 1))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(DS.track)
        .clipShape(Capsule())
    }
}

// MARK: - Buttons

/// Small square icon button (mute, rescan).
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 12
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 22, height: 20)
                .background(hovering ? Color.white.opacity(0.1) : DS.control)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DS.controlStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Wide action button, filled when it's the primary thing to do here.
struct PanelButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium))
                }
                Text(title).font(DS.label(11))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .foregroundStyle(prominent ? DS.accent : DS.text.opacity(0.85))
            .background(prominent
                        ? (hovering ? DS.accent.opacity(0.24) : DS.accentSoft)
                        : (hovering ? Color.white.opacity(0.09) : DS.control))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(prominent ? DS.accent.opacity(0.3) : DS.controlStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The three-bar equalizer glyph marking an app that's actually making sound.
struct PlayingIndicator: View {
    var heights: [CGFloat] = [5, 10, 7]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(DS.green)
                    .frame(width: 2, height: height)
            }
        }
        .frame(width: 9, height: 11, alignment: .bottom)
    }
}
