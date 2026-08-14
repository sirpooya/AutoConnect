import SwiftUI

// MARK: - Shared layout primitives for the settings window.
//
// A "card" is a rounded grouped container holding one or more rows. A row has a
// leading title and a trailing control, and rows are separated by hairlines
// inset to match the title. Same vocabulary as the LaunchpadX settings window,
// minus the parts that app needs and this one does not.

/// A grouped rounded container. Children stack vertically; put `SettingsDivider`
/// between rows for the hairline separators.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                // `.continuous` gives the squircle curve; a generous radius makes
                // that smooth corner read clearly instead of as a tight arc.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.settingsCardFill)
            )
    }
}

/// Hairline separator, inset on both edges so it floats inside the card.
struct SettingsDivider: View {
    var body: some View {
        // A plain rectangle, not `Divider()`, whose system separator draws under
        // any overlay tint and cannot be lightened. This keeps the hairline ours.
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, SettingsMetrics.rowHPadding)
    }
}

/// One row: leading title, trailing control.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13))
            if let help {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(help)
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.rowHPadding)
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

/// A row whose trailing control is a text field, right aligned so the values line
/// up in a column down the card.
struct SettingsFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var secure = false

    var body: some View {
        SettingsRow(title: title) {
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            // Monospaced values (a 40-character SHA1, a binary path) are longer than
            // any label, so they get a smaller face and the wider column.
            .font(monospaced ? .system(size: 10, design: .monospaced) : .system(size: 13))
            .frame(maxWidth: monospaced
                ? SettingsMetrics.monospacedFieldWidth
                : SettingsMetrics.fieldWidth)
        }
    }
}

/// The small unlabelled switch every toggle row uses, so seven of them cannot
/// drift into three sizes.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

/// A bold section header above a card.
struct SettingsSectionHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Align with the row TITLE inside the card, not the card's left edge.
            .padding(.leading, SettingsMetrics.rowHPadding)
    }
}

/// Explanatory text under a card.
struct SettingsFootnote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.rowHPadding)
    }
}

/// The scrolling body every tab shares, so their padding and rhythm match.
struct SettingsTabBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
    }
}

enum SettingsMetrics {
    static let rowHPadding: CGFloat = 12
    static let rowHeight: CGFloat = 36
    static let windowWidth: CGFloat = 460
    /// The tab body is a fixed height, so switching tabs never resizes the window
    /// and the window's size stays a constant the Settings scene can measure once.
    static let bodyHeight: CGFloat = 380
    /// Tab bar + body. The window is sized from this, not from the SwiftUI content,
    /// so AppKit never measures the ScrollView mid-layout.
    static let windowHeight: CGFloat = 450
    static let fieldWidth: CGFloat = 250
    static let monospacedFieldWidth: CGFloat = 290
}

extension Color {
    /// Soft elevated panel behind each card, built on the semantic `labelColor` so
    /// it tracks appearance and the "increase contrast" setting instead of a fixed
    /// white or black alpha.
    static let settingsCardFill = Color(nsColor: .labelColor).opacity(0.05)
}

/// A pop-up button that fills the width it is given.
///
/// SwiftUI's menu `Picker` sizes itself to its widest choice and ignores any wider frame, so a
/// picker standing in for a text field never lines up with the fields above and below it: the
/// form reads as three controls of three widths rather than one column. AppKit's own control
/// holds no such opinion once its hugging priority is lowered.
struct WidePopUpButton: NSViewRepresentable {

    struct Option: Equatable {
        var title: String
        var value: String
        /// Drawn in the secondary colour, for a title that stands for no choice yet. A
        /// placeholder rendered like a real value reads as one.
        var isPlaceholder: Bool = false
    }

    @Binding var selection: String
    let options: [Option]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        // Take the offered width instead of the widest title's, which is the whole point.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.options = options
        context.coordinator.selection = $selection

        // Rebuilt wholesale: the choices come from the authenticator accounts and the username
        // typed so far, so which of them exist changes as the sheet is used.
        button.removeAllItems()
        for option in options {
            button.addItem(withTitle: option.title)
            if option.isPlaceholder, let item = button.lastItem {
                item.attributedTitle = NSAttributedString(
                    string: option.title,
                    attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.systemFont(ofSize: 11),
                    ]
                )
            }
        }

        button.selectItem(at: options.firstIndex { $0.value == selection } ?? 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var options: [Option] = []
        var selection: Binding<String>?

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            selection?.wrappedValue = options[index].value
        }
    }
}
