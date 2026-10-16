import AppKit
import SwiftUI

// MARK: - Primitives (ui-spec v4)

/// 24×24 slot in the lead column; every icon centres at x 28 and every text starts at x 52.
struct Lead<Content: View>: View {
    @ViewBuilder var content: Content
    // Color.clear keeps the 24 pt slot even when the content is EmptyView (a frame on EmptyView renders nothing).
    var body: some View { Color.clear.frame(width: Grid.lead, height: Grid.lead).overlay(content) }
}

/// Raycast-style keycap: outlined, nearly no fill (1 px foreground 25%, radius 6, height 22).
struct Keycap: View {
    let label: String
    var body: some View {
        Group {
            switch label {
            case "↵": Icon(name: "enter", size: 12, color: Theme.textSecondary)
            case "⌘": Icon(name: "command", size: 12, color: Theme.textSecondary)
            default: Text(label).font(Fonts.key).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, label.count > 1 ? 6 : 5)
        .frame(minWidth: Grid.keycapHeight, minHeight: Grid.keycapHeight, maxHeight: Grid.keycapHeight)
        .background(RoundedRectangle(cornerRadius: Grid.keycapRadius, style: .continuous).fill(Theme.keycapFill))
        .overlay(RoundedRectangle(cornerRadius: Grid.keycapRadius, style: .continuous).strokeBorder(Theme.keycapBorder, lineWidth: 1))
    }
}

/// "Label + keycaps" in the bottom bar.
struct BarAction: View {
    let label: String
    let keys: [String]
    var primary = true
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(primary ? Fonts.bodyStrong : Fonts.body).tracked(13)
                    .foregroundStyle(primary ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1).fixedSize()
                HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap(label: $0) } }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Selectable list row: inset 8, radius 12, height 32, padding 8 → lead still at x 16…40.
struct ListRow<LeadView: View>: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var keys: [String] = []
    let selected: Bool
    @ViewBuilder var lead: LeadView
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: Grid.gap) {
                Lead { lead }
                Text(title).font(selected ? Fonts.bodyStrong : Fonts.body).tracked(13)
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let subtitle { Text(subtitle).font(Fonts.body).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                Spacer(minLength: 8)
                if let trailing { Text(trailing).font(Fonts.metric).monospacedDigit().foregroundStyle(Theme.textTertiary) }
                HStack(spacing: 4) { ForEach(keys, id: \.self) { Keycap(label: $0) } }
            }
            .padding(.horizontal, Grid.rowInset)
            .frame(height: Grid.rowHeight)
            .background(RoundedRectangle(cornerRadius: Grid.rowRadius, style: .continuous).fill(selected ? Theme.listSelection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Grid.rowInset)
    }
}

/// Non-interactive row on the grid (lead + text), padding 16.
struct LineRow<LeadView: View, Content: View>: View {
    var alignment: VerticalAlignment = .center
    @ViewBuilder var lead: LeadView
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: alignment, spacing: Grid.gap) {
            Lead { lead }
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Grid.inset)
    }
}

struct StatusRow: View {
    let step: StatusStep
    var body: some View {
        LineRow {
            switch step.state {
            case .done: Icon(name: "tick", size: 16, color: Theme.done)
            case .active: Spinner(size: 16)
            case .error: Icon(name: "alert", size: 16, color: Theme.error)
            }
        } content: {
            Text(step.title).font(step.state == .active ? Fonts.bodyStrong : Fonts.body).tracked(13)
                .foregroundStyle(step.state == .active ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(height: 28)
    }
}

// MARK: - Panel

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelBackground: View {
    var body: some View {
        ZStack {
            Theme.windowBase.opacity(0.35)
            LinearGradient(colors: [Theme.windowBg, Theme.windowBgSecondary], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var m: AppModel
    let onHeight: (CGFloat) -> Void

    /// The ⌘K popover floats in its own window, so the thread stays visible behind it.
    var hasBody: Bool { (m.overlay != .none && m.overlay != .actions) || !m.turns.isEmpty || !m.steps.isEmpty || m.notice != nil }

    var body: some View {
        VStack(spacing: 0) {
            if hasBody { BodyArea() }
            BottomBar()
        }
        .frame(width: Grid.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onPreferenceChange(HeightKey.self) { onHeight($0) }
        // Bottom-aligned: if the window is ever shorter than the content, the thread loses its top, never the bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(PanelBackground())
        .overlay(RoundedRectangle(cornerRadius: Grid.panelRadius, style: .continuous).strokeBorder(Theme.borderPanel, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grid.panelRadius, style: .continuous))
        .focusEffectDisabled()      // no blue focus rings anywhere in the panel (inherited by every button/row)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Bottom bar

/// One row at the bottom: [lead glyph] [transcript or typing field] [app chip] [primary action] [Actions ⌘K].
/// 56 tall: the 24 pt lead slot sits 16 from the left, top and bottom; typing grows it to 3 lines.
struct BottomBar: View {
    @EnvironmentObject var m: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Grid.gap) {
            Lead {
                if m.listening { Icon(name: "mic", size: 22, color: Theme.listening) }
                else if m.busy && !m.answerStarted { Spinner(size: 22) }
                else { Icon(name: "question", size: 22, color: Theme.textSecondary) }
            }
            .padding(.vertical, 16)
            Group {
                if m.input == .typed && !m.listening { field } else { transcript }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(height: Grid.inputHeight)
        }
        .padding(.horizontal, Grid.inset)
        .frame(minHeight: Grid.inputHeight)
        .onChange(of: m.focusField) { _, want in if want { focused = true; m.focusField = false; caretToEnd() } }
        .onAppear { if m.input == .typed { focused = true } }
    }

    /// Focusing a field selects all of its text; with words carried over from voice, the next key would
    /// replace them. Put the caret at the end instead.
    private func caretToEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp.windows.first(where: { $0.isKeyWindow })?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    /// Text lines are 24 tall (16/24 type), so 16 above and below centres them on the lead glyph.
    private var field: some View {
        ZStack(alignment: .topLeading) {
            // SwiftUI ignores the prompt colour on macOS, so the placeholder is drawn here.
            if m.draft.isEmpty {
                Text("Ask about what's on screen…").font(Fonts.input).tracked(16)
                    .foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .frame(height: 24).allowsHitTesting(false)
            }
            TextField("", text: $m.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Fonts.input).tracked(16)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.accent)
                .lineLimit(1...3)
                .lineSpacing(4)
                .focused($focused)
                .frame(minHeight: 24)
        }
        .padding(.vertical, 16)
    }

    /// Voice transcript stays on one line; newest words stay visible, a 16 px fade marks hidden text.
    private var transcript: some View {
        let text: String
        let color: Color
        if m.listening {
            text = m.partial.isEmpty ? "Listening…" : m.partial
            color = m.partial.isEmpty ? Theme.textTertiary : Theme.textSecondary
        } else if !m.partial.isEmpty {
            text = m.partial; color = Theme.textSecondary
        } else {
            text = m.turns.isEmpty ? "Hold fn to talk, or shift + fn to type" : "Hold fn to ask a follow-up"
            color = Theme.textTertiary
        }
        return Text(text)
            .font(Fonts.input).tracked(16)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(m.listening || !m.partial.isEmpty ? .head : .tail)   // newest words win; hints keep their start
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .mask(
                Group {
                    if m.listening && m.partial.count > 40 {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                            Color.black
                        }
                    } else {
                        Color.black
                    }
                }
            )
            .padding(.vertical, 16)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !m.busy else { return }
                if m.listening { _ = m.escape() } else { m.input = .typed; m.focusField = true }
            }
    }

    private var trailing: some View {
        let primary = primaryAction
        return HStack(spacing: Grid.gap) {
            AppChip(compact: primary != nil || m.listening || !m.draft.isEmpty)
            if let primary {
                BarAction(label: primary.label, keys: primary.keys, action: primary.action)
                Theme.separator.frame(width: 1, height: 16)
            }
            BarAction(label: "Actions", keys: ["⌘", "K"], primary: false) {
                m.overlay = m.overlay == .actions ? .none : .actions
                m.selection = 0; m.filter = ""
            }
        }
    }

    /// The one contextual action worth a keycap right now, if any.
    private var primaryAction: (label: String, keys: [String], action: () -> Void)? {
        switch m.overlay {
        case .confirm:
            return (m.pendingTool?.confirmVerb ?? m.pendingComputer?.confirmText ?? "Confirm", ["↵"], { m.resolveConfirm(true) })
        case .chats: return ("Open", ["↵"], { let c = m.recentChats; if c.indices.contains(m.selection) { m.openChat(c[m.selection].id) } })
        case .apps: return ("Look", ["↵"], { let a = m.switchableApps; if a.indices.contains(m.selection) { m.switchTo(a[m.selection]) } })
        case .actions, .none: break
        }
        if m.listening { return nil }
        if m.busy || m.speaking { return ("Stop", ["esc"], { _ = m.escape() }) }
        if m.input == .typed && !m.draft.trimmingCharacters(in: .whitespaces).isEmpty { return ("Send", ["↵"], { m.submitTyped() }) }
        if m.turns.last?.error?.contains("Retry") == true { return ("Retry", ["↵"], { m.retry() }) }
        if m.lastAnswerTyped { return ("Insert", ["↵"], { m.insertLastAnswer() }) }
        return nil
    }
}

/// The app being looked at, as a capsule; click opens the app switcher. Icon only when the bar is busy.
struct AppChip: View {
    @EnvironmentObject var m: AppModel
    var compact = false
    var body: some View {
        Button {
            m.filter = ""; m.selection = 0
            m.overlay = m.overlay == .apps ? .none : .apps
        } label: {
            HStack(spacing: 6) {
                if let icon = m.context?.appIcon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                else { Icon(name: "question", size: 16, color: Theme.textSecondary) }
                if !compact {
                    (Text(m.context?.label ?? "Your screen").foregroundColor(Theme.textPrimary)
                     + Text(m.chatPosition.map { " · \($0)" } ?? "").foregroundColor(Theme.textTertiary))
                        .font(Fonts.bodyStrong).tracked(13).lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 6 : 10)
            .frame(height: Grid.chipHeight)
            .frame(maxWidth: 200)
            .background(Capsule().fill(Theme.chipFill))
            .overlay(Capsule().strokeBorder(Theme.chipBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - Body

struct BodyArea: View {
    @EnvironmentObject var m: AppModel
    @State private var contentHeight: CGFloat = 0

    var maxHeight: CGFloat { max(80, m.panelCap - (m.input == .typed ? 104 : Grid.inputHeight)) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    switch m.overlay {
                    case .none, .actions: ThreadView()
                    case .chats: ChatsList()
                    case .apps: AppsList()
                    case .confirm: ConfirmCard()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
            }
            .frame(height: min(contentHeight, maxHeight))
            .clipped()      // the bar sits outside the scroll view; nothing scrolls under it
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: m.turns.last?.answer.count ?? 0) { _, _ in
                if m.follow && m.overlay == .none { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: m.steps.count) { _, _ in if m.follow { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: m.chatIndex) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !m.follow && contentHeight > maxHeight && m.overlay == .none {
                    Button {
                        m.follow = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } label: {
                        HStack(spacing: 4) {
                            Icon(name: "down", size: 12, color: Theme.textSecondary)
                            Text("Latest").font(Fonts.bodyStrong).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Capsule().fill(Theme.backgroundSecondary))
                        .overlay(Capsule().strokeBorder(Theme.borderPanel, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .bottom) {
                // 1 px edge above the bar only when the thread scrolls.
                if contentHeight > maxHeight { Theme.separator.frame(height: 1) }
            }
        }
    }
}

struct ThreadView: View {
    @EnvironmentObject var m: AppModel
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(m.turns.enumerated()), id: \.element.id) { i, turn in
                let isLive = i == m.turns.count - 1 && m.busy
                TurnView(turn: turn, live: isLive, expanded: expanded.contains(turn.id)) {
                    if expanded.contains(turn.id) { expanded.remove(turn.id) } else { expanded.insert(turn.id) }
                }
            }
            if m.turns.isEmpty && !m.steps.isEmpty {
                ForEach(m.steps) { StatusRow(step: $0) }
            }
            if let notice = m.notice {
                LineRow { Icon(name: notice.contains("lost") || notice.contains("unavailable") ? "offline" : "globe", size: 16, color: Theme.textTertiary) } content: {
                    Text(notice).font(Fonts.body).foregroundStyle(Theme.textTertiary)
                }
                .frame(minHeight: 32)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

struct TurnView: View {
    @EnvironmentObject var m: AppModel
    let turn: Turn
    let live: Bool
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let divider = turn.divider {
                Text(divider).font(Fonts.body).tracked(13).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .padding(.bottom, 4)
            }
            // Your message: a compact bubble on the right, at most ~75% of the panel.
            HStack(spacing: 0) {
                Spacer(minLength: Grid.panelWidth * 0.25)
                Text(turn.ask).font(Fonts.body).tracked(13).lineSpacing(4)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chipFill))
            }
            .padding(.horizontal, Grid.inset)

            // Status: live rows while working, then one collapsed line above the answer.
            if live && !m.answerStarted {
                VStack(alignment: .leading, spacing: 0) { ForEach(m.steps.suffix(4)) { StatusRow(step: $0) } }
                    .padding(.top, 8)
            } else if live || turn.workedFor != nil {
                Button(action: toggle) {
                    Text(summary).font(Fonts.body).tracked(13).foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .padding(.horizontal, Grid.inset)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                if expanded {
                    ForEach(live ? m.steps.map(\.title) : turn.steps, id: \.self) { t in
                        StatusRow(step: StatusStep(title: t, state: .done))
                    }
                }
            }

            // The answer: plain text from x 16, no bubble.
            if !turn.answer.isEmpty {
                answerText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Grid.inset)
                    .padding(.top, 4)
            }
            if let error = turn.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Icon(name: "alert", size: 14, color: Theme.error)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                    Text(error).font(Fonts.body).tracked(13).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Grid.inset)
                .padding(.top, 8)
            }
        }
        .padding(.bottom, 12)       // 12 between turns
    }

    private var summary: String {
        if live { return "Working · \(m.steps.count) step\(m.steps.count == 1 ? "" : "s")" }
        return String(format: "Worked for %.1fs", turn.workedFor ?? 0)
    }

    @ViewBuilder private var answerText: some View {
        if turn.voice {
            let n = min(turn.spokenUpTo ?? turn.answer.count, turn.answer.count)
            let heard = String(turn.answer.prefix(n)), rest = String(turn.answer.dropFirst(n))
            (Text(heard).foregroundColor(Theme.textPrimary) + Text(rest).foregroundColor(Theme.textSecondary))
                .font(Fonts.body).tracked(13).lineSpacing(7)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(Self.markdown(turn.answer))
                .font(Fonts.body).tracked(13).lineSpacing(7)
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.link)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Tolerates unclosed syntax while streaming.
    static func markdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                           failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

// MARK: - Overlays

/// ⌘K: a separate glass card above the bar's right end (its own window, see PanelController).
struct ActionsPopover: View {
    @EnvironmentObject var m: AppModel
    let onHeight: (CGFloat) -> Void

    var body: some View {
        let items = m.filteredActions()
        let sections = items.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element) { si, section in
                    if si > 0 { Theme.separator.frame(height: 1).padding(.vertical, 4) }
                    Text(section).font(Fonts.body).tracked(13).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Grid.inset).frame(height: 28)
                    ForEach(items.filter { $0.section == section }) { a in
                        PopoverRow(item: a, selected: items.firstIndex { $0.id == a.id } == m.selection)
                    }
                }
                if items.isEmpty {
                    Text("No matching actions").font(Fonts.body).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Grid.inset).frame(height: Grid.popoverRowHeight)
                }
            }
            .padding(.vertical, 6)
            Theme.separator.frame(height: 1)
            HStack(spacing: 0) {
                if m.filter.isEmpty {
                    Theme.accent.frame(width: 1.5, height: 16)
                    Text("Search for actions…").font(Fonts.body).tracked(13).foregroundStyle(Theme.textTertiary).padding(.leading, 2)
                } else {
                    Text(m.filter).font(Fonts.body).tracked(13).foregroundStyle(Theme.textPrimary)
                    Theme.accent.frame(width: 1.5, height: 16).padding(.leading, 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Grid.inset)
            .frame(height: 44)
        }
        .frame(width: Grid.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onPreferenceChange(HeightKey.self) { onHeight($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(PanelBackground())
        .overlay(RoundedRectangle(cornerRadius: Grid.popoverRadius, style: .continuous).strokeBorder(Theme.borderPanel, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grid.popoverRadius, style: .continuous))
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
    }
}

/// Popover row: inset 8, radius 10, height 36, 16 pt icon, keycaps right.
struct PopoverRow: View {
    @EnvironmentObject var m: AppModel
    let item: ActionItem
    let selected: Bool
    var body: some View {
        Button(action: item.perform) {
            HStack(spacing: 10) {
                Icon(name: item.icon, size: 16, color: selected ? Theme.textPrimary : Theme.textSecondary)
                Text(item.title).font(Fonts.body).tracked(13).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 3) { ForEach(item.keys, id: \.self) { Keycap(label: $0) } }
            }
            .padding(.horizontal, Grid.rowInset)
            .frame(height: Grid.popoverRowHeight)
            .background(RoundedRectangle(cornerRadius: Grid.popoverRowRadius, style: .continuous).fill(selected ? Theme.listSelection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Grid.rowInset)
    }
}

struct ChatsList: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if m.recentChats.isEmpty {
                LineRow { EmptyView() } content: { Text("No chats yet").font(Fonts.body).foregroundStyle(Theme.textTertiary) }.frame(height: 32)
            }
            ForEach(Array(m.recentChats.prefix(12).enumerated()), id: \.element.id) { i, c in
                ListRow(title: c.title, trailing: Self.ago(c.updatedAt), selected: i == m.selection) {
                    Icon(name: "chats", size: 16, color: c.id == m.chat.id ? Theme.textPrimary : Theme.textSecondary)
                } action: { m.openChat(c.id) }
            }
        }
        .padding(.vertical, 8)
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

struct AppsList: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(m.switchableApps.enumerated()), id: \.element.processIdentifier) { i, app in
                ListRow(title: app.localizedName ?? "App",
                        subtitle: app.processIdentifier == m.context?.pid ? "Current" : nil,
                        selected: i == m.selection) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                } action: { m.switchTo(app) }
            }
        }
        .padding(.vertical, 8)
    }
}

struct ConfirmCard: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = m.pendingTool {
                LineRow(alignment: .firstTextBaseline) {
                    Icon(name: t.name == "create_event" ? "calendar" : "tick", size: 16, color: Theme.textSecondary)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.confirmTitle).font(Fonts.title).foregroundStyle(Theme.textPrimary)
                        if !t.confirmDetail.isEmpty { Text(t.confirmDetail).font(Fonts.body).foregroundStyle(Theme.textSecondary) }
                    }
                }
            } else if let c = m.pendingComputer {
                LineRow(alignment: .firstTextBaseline) {
                    Icon(name: "cursor", size: 16, color: Theme.textSecondary)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.confirmText).font(Fonts.title).foregroundStyle(Theme.textPrimary)
                        Text(c.task).font(Fonts.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Computer-use pill

struct CUAPill: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Spinner(size: 16)
            Text(m.cuaStatus ?? "Working").font(Fonts.body).tracked(13).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 8)
            Button { _ = m.escape() } label: {
                HStack(spacing: 8) {
                    Keycap(label: "esc")
                    Text("Stop").font(Fonts.bodyStrong).foregroundStyle(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8).padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground())
        .overlay(Capsule().strokeBorder(Theme.borderPanel, lineWidth: 1))
        .clipShape(Capsule())
        .environment(\.colorScheme, .dark)
    }
}
