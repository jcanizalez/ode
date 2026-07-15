import SwiftUI

// Shared building blocks for ODE's dark settings surfaces — used by both the
// menu-bar popover (PanelView) and the Settings window (SettingsView) so the
// two stay visually consistent.

extension Text {
    func rowLabelStyle() -> some View {
        self.font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
    }
}

func sectionLabel(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(.white.opacity(0.4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
}

func settingRow<L: View, T: View>(
    icon: String,
    hint: LocalizedStringKey? = nil,
    @ViewBuilder label: () -> L,
    @ViewBuilder trailing: () -> T
) -> some View {
    HStack(spacing: 10) {
        Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 18)
        label()
        if let hint { HintRing(text: hint) }
        Spacer(minLength: 8)
        trailing()
    }
    .padding(.vertical, 7)
}

func rowValue(_ text: String) -> some View {
    HStack(spacing: 4) {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.35))
    }
}

/// A subtle ⓘ ring next to a setting label; click (or hover) explains what
/// the setting does in plain words.
struct HintRing: View {
    let text: LocalizedStringKey
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .padding(12)
                .frame(width: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Standard switch used across ODE's settings rows.
func settingToggle(isOn: Bool, action: @escaping () -> Void) -> some View {
    Toggle("", isOn: Binding(get: { isOn }, set: { _ in action() }))
        .toggleStyle(.switch).labelsHidden().tint(.accentColor)
        .scaleEffect(0.85)
}
