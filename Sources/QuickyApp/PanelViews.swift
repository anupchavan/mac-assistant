import AppKit
import QuickyCore
import SwiftUI

/// The panel's content, rendered only from a `PanelScene` value. It drives turns only through `send`.
struct PanelView: View {
    let scene: PanelScene
    var maxHeight: CGFloat = 560
    var send: @MainActor (Input) -> Void = { _ in }
    var openSettings: @MainActor () -> Void = {}
    var onUserScrolled: @MainActor (Bool) -> Void = { _ in }
    var onHeight: @MainActor (CGFloat) -> Void = { _ in }

    @State private var inputHeight = Theme.inputHeight

    private var isTyping: Bool {
        if case .typing = scene.input { return true }
        return false
    }

    private var hasFooter: Bool { scene.footer.primary != nil || scene.footer.chatPosition != nil }

    var body: some View {
        VStack(spacing: 0) {
            InputRowView(input: scene.input, send: send)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputHeight = $0 }
            if !scene.thread.isEmpty {
                ThreadView(
                    items: scene.thread,
                    maxHeight: max(0, maxHeight - inputHeight - (hasFooter ? Theme.footerHeight : 0)),
                    onUserScrolled: onUserScrolled
                )
            }
            if hasFooter {
                FooterView(footer: scene.footer, shortcutsActive: !isTyping, send: send, openSettings: openSettings)
            }
        }
        .frame(width: Theme.panelWidth)
        .background(PanelFill())
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.borderPanel, lineWidth: 1)
        )
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        .environment(\.colorScheme, .dark)
    }
}

/// The tint layers over the window's glass: window/base at 55%, then window/bg to window/bg-secondary.
private struct PanelFill: View {
    var body: some View {
        ZStack {
            Theme.windowBase.opacity(0.55)
            LinearGradient(colors: [Theme.windowBg, Theme.windowBgSecondary], startPoint: .top, endPoint: .bottom)
        }
    }
}

private struct InputRowView: View {
    let input: InputRow
    let send: @MainActor (Input) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.leadGap) {
            lead.frame(width: Theme.leadWidth, height: TypeStyle.input.lineHeight)
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.inset)
        .frame(minHeight: Theme.inputHeight)
        .onChange(of: input, initial: true) {
            guard case let .typing(prefill) = input else { return }
            draft = prefill
            focused = true
        }
        .onChange(of: focused) {
            if focused { Task { @MainActor in moveCaretToEnd() } }
        }
    }

    @ViewBuilder private var lead: some View {
        if input == .working {
            Spinner(size: 22)
        } else {
            GlyphView(glyph: .question, size: 22, color: Theme.textTertiary)
        }
    }

    @ViewBuilder private var text: some View {
        switch input {
        case .idle:
            Text("Ask about what's on screen…").type(.input).foregroundStyle(Theme.textTertiary)
        case .typing:
            TextField(
                "",
                text: $draft,
                prompt: Text("Ask about what's on screen…").foregroundStyle(Theme.textTertiary),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .type(.input)
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .onSubmit { send(.submit(draft)) }
        case .working:
            Color.clear.frame(height: 1)
        }
    }

    /// Focusing a SwiftUI field selects all of it; text carried over from voice must not be replaced
    /// by the next keystroke, so the caret goes to the end.
    private func moveCaretToEnd() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertionPointColor = NSColor(Theme.textPrimary)
    }
}

private struct ThreadView: View {
    let items: [ThreadItem]
    let maxHeight: CGFloat
    let onUserScrolled: @MainActor (Bool) -> Void

    @State private var contentHeight: CGFloat = 0
    @State private var following = true
    private let bottom = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { TurnView(item: $0) }
                    Color.clear.frame(height: 0).id(bottom)
                }
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.bottom)
            .frame(height: min(contentHeight, maxHeight))
            .modifier(FollowTracker(following: $following))
            .onChange(of: contentHeight) {
                if following { proxy.scrollTo(bottom, anchor: .bottom) }
            }
            .onChange(of: items.count) {
                following = true
                proxy.scrollTo(bottom, anchor: .bottom)
            }
            .onChange(of: following) { onUserScrolled(!following) }
        }
    }
}

/// Stops following the newest text the moment the user scrolls, and resumes once they are back at the
/// bottom. Scroll phases need macOS 15; on 14 the thread always follows.
private struct FollowTracker: ViewModifier {
    @Binding var following: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { old, new, context in
                switch new {
                case .interacting:
                    following = false
                case .idle where old == .interacting || old == .decelerating:
                    let g = context.geometry
                    following = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 4
                default:
                    break
                }
            }
        } else {
            content
        }
    }
}

private struct TurnView: View {
    let item: ThreadItem
    @State private var stepsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(lead: GlyphView(glyph: .question, size: 16, color: Theme.textTertiary)) {
                Text(item.ask).type(.body).foregroundStyle(Theme.textSecondary)
            }
            if !item.steps.isEmpty {
                if item.answer.isEmpty || stepsExpanded {
                    ForEach(Array(item.steps.enumerated()), id: \.offset) { StepRowView(step: $0.element) }
                } else {
                    Row(lead: Color.clear) {
                        Button { stepsExpanded = true } label: {
                            Text(item.steps.count == 1 ? "1 step" : "\(item.steps.count) steps")
                                .type(.body)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !item.answer.isEmpty {
                AnswerText(markdown: item.answer, isStreaming: item.isLive)
                    .padding(.leading, Theme.textX)
                    .padding(.trailing, Theme.inset)
                    .padding(.vertical, 6)
            }
            if let error = item.error {
                Row(lead: GlyphView(glyph: .alert, size: 16, color: Theme.red)) {
                    Text(error).type(.body).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }
}

private struct StepRowView: View {
    let step: StepRow

    var body: some View {
        Row(lead: lead) {
            Text(step.text)
                .type(step.state == .active ? .bodyStrong : .body)
                .foregroundStyle(step.state == .active ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder private var lead: some View {
        switch step.state {
        case .active: Spinner(size: 16)
        case .done: GlyphView(glyph: .tick, size: 16, color: Theme.green)
        case .failed: GlyphView(glyph: .alert, size: 16, color: Theme.red)
        }
    }
}

/// A 32 pt row inset 8 from the panel: lead centred at x 28, content from x 52.
private struct Row<Lead: View, Content: View>: View {
    let lead: Lead
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.leadGap) {
            lead.frame(width: Theme.leadWidth, height: TypeStyle.body.lineHeight)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .padding(.horizontal, 8)
    }
}

struct AnswerText: View {
    let markdown: String
    let isStreaming: Bool

    var body: some View {
        Text(Self.attributed(markdown, streaming: isStreaming))
            .type(.body)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .textSelection(.enabled)
    }

    /// Streaming text often ends mid-syntax ("**bol"). The open marker is closed so the words render
    /// styled at once instead of flashing literal asterisks until the closing token arrives.
    static func attributed(_ markdown: String, streaming: Bool) -> AttributedString {
        var source = markdown
        if streaming {
            for marker in ["`", "**"] where source.components(separatedBy: marker).count % 2 == 0 {
                source = source.hasSuffix(marker)
                    ? String(source.dropLast(marker.count))
                    : String(source.reversed().drop(while: \.isWhitespace).reversed()) + marker
            }
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let styled = text.runs.compactMap { run -> (Range<AttributedString.Index>, Font)? in
            guard let intent = run.inlinePresentationIntent else { return nil }
            if intent.contains(.code) { return (run.range, TypeStyle.mono.font) }
            if intent.contains(.stronglyEmphasized) { return (run.range, .custom("Geist-SemiBold", fixedSize: 13)) }
            return nil
        }
        for (range, font) in styled { text[range].font = font }
        return text
    }
}

private struct FooterView: View {
    let footer: Footer
    let shortcutsActive: Bool
    let send: @MainActor (Input) -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Theme.leadGap) {
            if let position = footer.chatPosition {
                Text(position).type(.body).foregroundStyle(Theme.textSecondary)
                    .padding(.leading, Theme.leadWidth + Theme.leadGap)
            }
            Spacer(minLength: 0)
            if let primary = footer.primary {
                FooterActionView(action: primary, shortcutActive: shortcutsActive) {
                    switch primary {
                    case .retry: send(.command(.retry))
                    case .openSettings: openSettings()
                    }
                }
            }
        }
        .padding(.horizontal, Theme.inset)
        .frame(height: Theme.footerHeight)
        .background(Theme.surfaceActionBar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderSeparator).frame(height: 1) }
    }
}

private struct FooterActionView: View {
    let action: FooterAction
    let shortcutActive: Bool
    let perform: () -> Void

    private var label: String {
        switch action {
        case .retry: "Retry"
        case .openSettings: "Open Settings"
        }
    }

    private var keys: [String] {
        switch action {
        case .retry: ["↵"]
        case .openSettings: ["⌘", ","]
        }
    }

    private var shortcut: KeyboardShortcut {
        switch action {
        case .retry: KeyboardShortcut(.return, modifiers: [])
        case .openSettings: KeyboardShortcut(",", modifiers: .command)
        }
    }

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Text(label).type(.bodyStrong).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 4) { ForEach(keys, id: \.self) { Keycap(label: $0) } }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // While typing, ↵ belongs to the text field.
        .keyboardShortcut(shortcutActive ? shortcut : nil)
    }
}

struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .type(.key)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, label.count == 1 ? 4 : 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        Theme.surfaceControl
                            .shadow(.inner(color: .white.opacity(0.3), radius: 0, x: 0, y: 0.5))
                            .shadow(.inner(color: .black.opacity(0.8), radius: 0, x: 0, y: -0.5))
                    )
            )
    }
}
