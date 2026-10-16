import AppKit
import Combine
import SwiftUI

/// Non-activating floating panel: it takes keys without activating our app, so the app the user
/// was in stays frontmost (and its window is what we capture).
final class AssistantPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Grid.panelWidth, height: 160),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The ⌘K card. Never key: the panel keeps the keyboard (↑ ↓ ↵, typing filters, Esc closes it).
final class PopoverPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Grid.popoverWidth, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Pure placement (unit-tested). The bottom bar sits just under the pointer (its top 18 pt below it, or
/// below the element the pointer is on), 12 pt to the right, and the panel grows UP from the bar with its
/// bottom edge anchored. It hangs down from the bar instead only when there's clearly more room below.
enum PanelPlacer {
    struct Placement: Equatable { var origin: CGPoint; var growsUp: Bool; var cap: CGFloat }
    static let margin: CGFloat = 24
    static let minUsefulHeight: CGFloat = 240

    /// `pointer` and `visible` are AppKit coordinates (bottom-left origin). `avoid` is the AX frame of the
    /// element under the pointer, also in AppKit coordinates. `size` is the panel's current size.
    static func place(pointer: CGPoint, size: CGSize, visible: CGRect, avoid: CGRect? = nil) -> Placement {
        var x = pointer.x + 12
        if x + size.width > visible.maxX - margin { x = pointer.x - 12 - size.width }
        x = min(max(x, visible.minX + margin), visible.maxX - margin - size.width)

        var barTop = pointer.y - 18
        if let avoid, avoid.height < 120, avoid.minY < barTop, avoid.maxY > barTop - Grid.inputHeight,
           avoid.minX < x + size.width, avoid.maxX > x {
            barTop = avoid.minY - 16
        }
        barTop = min(max(barTop, visible.minY + margin + Grid.inputHeight), visible.maxY - margin)
        let bottom = barTop - Grid.inputHeight
        let full = cap(for: visible)
        let roomUp = visible.maxY - margin - bottom
        let roomDown = barTop - (visible.minY + margin)
        if roomUp >= min(full, minUsefulHeight) || roomUp >= roomDown {
            return Placement(origin: CGPoint(x: x, y: bottom), growsUp: true, cap: min(full, roomUp))
        }
        let h = min(size.height, roomDown)
        return Placement(origin: CGPoint(x: x, y: barTop - h), growsUp: false, cap: min(full, roomDown))
    }

    static func cap(for visible: CGRect) -> CGFloat { min(visible.height * 0.6, 560) }
}

@MainActor
final class PanelController {
    let model: AppModel
    private let panel = AssistantPanel()
    private var pill: NSPanel?
    private var anchor: CGPoint = .zero     // top-left (or bottom-left if growing up) in AppKit coords
    private var growsUp = false
    private var screenVisible: CGRect = .zero
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var height: CGFloat = 0
    private(set) var cap: CGFloat = 560
    private var popover: PopoverPanel?
    private var popoverHeight: CGFloat = 0
    private var overlaySub: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        let root = PanelView(onHeight: { [weak self] h in self?.resize(to: h) }).environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = []
        panel.contentView = Self.glass(around: hosting)

        // ⌘-Tab or any other way another app comes forward. (A click is covered by the click monitor.)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Only real apps: background agents (UserNotificationCenter, permission prompts) also "activate".
            guard let app, app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.model.dismissFromOutside("app switch to \(app.localizedName ?? "?")") }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.dismissFromOutside("resign key") }
        }
        overlaySub = model.$overlay.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] o in
            self?.setPopover(visible: o == .actions)
        }
    }

    // MARK: ⌘K popover (its own glass window, above the bar's right end)

    private func setPopover(visible: Bool) {
        guard visible, panel.isVisible else {
            if let popover { panel.removeChildWindow(popover); popover.orderOut(nil) }
            return
        }
        let p = popover ?? makePopover()
        popover = p
        positionPopover()
        panel.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
    }

    private func makePopover() -> PopoverPanel {
        let p = PopoverPanel()
        let root = ActionsPopover(onHeight: { [weak self] h in
            guard let self, abs(h - self.popoverHeight) > 0.5 else { return }
            self.popoverHeight = h
            self.positionPopover()
        }).environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        p.contentView = Self.glass(around: hosting, radius: Grid.popoverRadius, liquid: false)
        return p
    }

    /// Right edge 8 in from the panel's, bottom edge 4 above the bar; grows up. If that would leave the
    /// screen, it opens below the panel instead.
    private func positionPopover() {
        guard let popover, popoverHeight > 0 else { return }
        let f = panel.frame
        let h = popoverHeight
        var y = f.minY + Grid.inputHeight + 4
        if y + h > screenVisible.maxY - PanelPlacer.margin { y = max(f.minY - 8 - h, screenVisible.minY) }
        popover.setFrame(NSRect(x: f.maxX - 8 - Grid.popoverWidth, y: y, width: Grid.popoverWidth, height: h), display: true)
        popover.invalidateShadow()
    }

    /// Real frosted glass behind the SwiftUI content (ui-spec v4 "Glass").
    /// `liquid: false` uses the masked visual-effect blur even on macOS 26 (the ⌘K card: as a child window
    /// the Liquid Glass view drew square top corners).
    static func glass(around content: NSView, radius: CGFloat = Grid.panelRadius, liquid: Bool = true) -> NSView {
        // Nothing may paint outside the rounded shape (no square corners behind the glass).
        content.wantsLayer = true
        content.layer?.backgroundColor = .clear
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        #if compiler(>=6.2)
        if liquid, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.wantsLayer = true
            glass.layer?.cornerRadius = radius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            content.translatesAutoresizingMaskIntoConstraints = true
            content.autoresizingMask = [.width, .height]
            glass.contentView = content
            return glass
        }
        #endif
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = radius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = roundedMask(radius: radius)
        blur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blur)
        container.addSubview(content)
        for v in [blur, content] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    // MARK: Show / hide

    func show() {
        if panel.isVisible { panel.alphaValue = 1; makeKey(); return }   // may be mid fade-out
        // The chat may have changed while hidden (new chat after 2 min); lay it out now so `height` is current.
        panel.contentView?.layoutSubtreeIfNeeded()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        screenVisible = screen.visibleFrame
        var size = CGSize(width: Grid.panelWidth, height: max(height, Grid.inputHeight))
        var avoid: CGRect?
        if let f = model.context?.pointerElementFrame, let primary = NSScreen.screens.first {
            avoid = CGRect(x: f.minX, y: primary.frame.height - f.maxY, width: f.width, height: f.height)
        }
        let p = PanelPlacer.place(pointer: mouse, size: size, visible: screenVisible, avoid: avoid)
        cap = p.cap
        model.panelCap = cap
        size.height = min(size.height, cap)
        growsUp = p.growsUp
        // Growing up: the bottom-left corner stays put (the bar never moves). Growing down: the top-left.
        anchor = growsUp ? p.origin : CGPoint(x: p.origin.x, y: p.origin.y + size.height)
        panel.alphaValue = 1
        apply(height: size.height, animate: false)
        panel.orderFrontRegardless()   // no animation on appear (ui-spec v3 Motion)
        makeKey()
        installMonitors()
        // Re-assert the measured height once the content has rendered in the window, so a stale size never sticks.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if abs(self.panel.frame.height - self.height) > 0.5 { self.apply(height: self.height, animate: false) }
            Log.info(String(format: "panel shown %.0f tall (content %.0f)", self.panel.frame.height, self.height))
        }
    }

    func makeKey() { panel.makeKey() }

    func hide() {
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.model.visible else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func resize(to h: CGFloat) {
        let clamped = min(h, cap)
        guard abs(clamped - height) > 0.5 else { return }
        Log.info(String(format: "panel height %.0f → %.0f (content %.0f, cap %.0f)", height, clamped, h, cap))
        height = clamped
        if panel.isVisible { apply(height: clamped, animate: true) }
    }

    private func apply(height h: CGFloat, animate: Bool) {
        height = h
        let origin = growsUp ? anchor : CGPoint(x: anchor.x, y: anchor.y - h)
        let frame = NSRect(x: origin.x, y: origin.y, width: Grid.panelWidth, height: h)
        if animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        panel.invalidateShadow()
        positionPopover()
    }

    // MARK: Event monitors

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return self.model.handleKey(e) ? nil : e
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            if let self, e.window === self.panel, e.scrollingDeltaY > 0 { self.model.follow = false }
            return e
        }
        // Global monitors only see clicks in other apps, so any event here is outside the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.model.dismissFromOutside("click") }
        }
    }

    private func removeMonitors() {
        for m in [keyMonitor, scrollMonitor, clickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        keyMonitor = nil; scrollMonitor = nil; clickMonitor = nil
    }

    // MARK: Computer-use pill

    func showPill(over windowFrameCG: CGRect) {
        panel.orderOut(nil)
        let view = NSHostingView(rootView: CUAPill().environmentObject(model))
        let width: CGFloat = 300, h: CGFloat = 32
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let wf = windowFrameCG == .zero ? CGRect(x: 100, y: 100, width: 800, height: 600) : windowFrameCG
        let x = wf.maxX - 12 - width
        let y = primaryH - (wf.minY + 12 + h)
        let p = NSPanel(contentRect: NSRect(x: x, y: y, width: width, height: h),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.translatesAutoresizingMaskIntoConstraints = false
        p.contentView = Self.glass(around: view, radius: h / 2)
        p.orderFrontRegardless()
        pill = p
    }

    func hidePill() {
        pill?.orderOut(nil)
        pill = nil
    }
}
