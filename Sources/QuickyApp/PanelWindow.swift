import AppKit
import QuickyCore
import SwiftUI

struct PanelPlacement: Equatable {
    var x: CGFloat
    var fixedEdgeY: CGFloat
    var growsUp: Bool
    var maxHeight: CGFloat

    func frame(width: CGFloat, height: CGFloat) -> CGRect {
        let h = min(height, maxHeight)
        return CGRect(x: x, y: growsUp ? fixedEdgeY : fixedEdgeY - h, width: width, height: h)
    }
}

enum PanelPlacer {
    static let margin: CGFloat = 24
    static let minUsefulHeight: CGFloat = 240

    static func cap(for visible: CGRect) -> CGFloat { min(visible.height * 0.6, 560) }

    static func place(pointer: CGPoint, width: CGFloat, visible: CGRect) -> PanelPlacement {
        let cap = cap(for: visible)
        var x = pointer.x + 12
        if x + width > visible.maxX - margin { x = pointer.x - 12 - width }
        x = max(visible.minX + margin, min(x, visible.maxX - margin - width))

        let top = min(pointer.y - 18, visible.maxY - margin)
        let bottom = max(pointer.y + 12, visible.minY + margin)
        let roomDown = top - (visible.minY + margin)
        let roomUp = (visible.maxY - margin) - bottom
        if roomDown >= min(cap, minUsefulHeight) || roomDown >= roomUp {
            return PanelPlacement(x: x, fixedEdgeY: top, growsUp: false, maxHeight: max(0, min(cap, roomDown)))
        }
        return PanelPlacement(x: x, fixedEdgeY: bottom, growsUp: true, maxHeight: max(0, min(cap, roomUp)))
    }
}

final class PanelWindow: NSPanel {
    private let engine: Engine
    private let hosting: NSHostingView<TopPinnedPanel>
    var openSettings: @MainActor () -> Void = {}
    /// A listen-only tap still sees Esc, so the panel handles Esc only with no tap at all.
    var hasTap = false

    private var shown = false
    private var sizedSinceShow = false
    private var placement = PanelPlacement(x: 0, fixedEdgeY: 0, growsUp: false, maxHeight: 560)
    private var userScrolled = false
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    init(engine: Engine) {
        self.engine = engine
        hosting = NSHostingView(rootView: TopPinnedPanel(panel: PanelView(scene: .hidden)))
        hosting.sizingOptions = []
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.inputHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        contentView = Self.glass(containing: hosting)
        installEscapeFallback()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func observe() {
        withObservationTracking { apply(engine.scene) } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    func apply(_ scene: PanelScene) {
        guard scene.presence == .panel else { return hide() }
        let appearing = !shown
        if appearing {
            shown = true
            sizedSinceShow = false
            userScrolled = false
            placement = Self.placementAtPointer()
        }
        render(scene)
        if appearing {
            alphaValue = 1
            let height = max(hosting.fittingSize.height, Theme.inputHeight)
            setFrame(placement.frame(width: Theme.panelWidth, height: height), display: true)
            orderFrontRegardless()
            installDismissalMonitors()
        }
        if case .typing = scene.input { makeKey() }
    }

    func escape() -> Bool {
        engine.send(.escape) == .handled
    }

    private func render(_ scene: PanelScene) {
        hosting.rootView = TopPinnedPanel(panel: PanelView(
            scene: scene,
            maxHeight: placement.maxHeight,
            send: { [weak self] in _ = self?.engine.send($0) },
            openSettings: { [weak self] in self?.openSettings() },
            onUserScrolled: { [weak self] in self?.userScrolled = $0 },
            onHeight: { [weak self] in self?.resize(toContentHeight: $0) }
        ))
    }

    private func resize(toContentHeight height: CGFloat) {
        guard shown else { return }
        let target = placement.frame(width: Theme.panelWidth, height: height)
        guard target != frame else { return }
        if sizedSinceShow && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
        }
        sizedSinceShow = true
        invalidateShadow()
    }

    private func hide() {
        guard shown else { return }
        shown = false
        removeDismissalMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.shown else { return }
                self.orderOut(nil)
            }
        }
    }

    private static func placementAtPointer() -> PanelPlacement {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        return PanelPlacer.place(pointer: pointer, width: Theme.panelWidth, visible: screen?.visibleFrame ?? .zero)
    }

    private func installDismissalMonitors() {
        // A global monitor only sees clicks in other apps, so every click it reports is outside the panel.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.engine.send(.dismiss(.clickOutside(userScrolled: self.userScrolled)))
            }
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Background agents (notification centre, permission prompts) activate too; only real apps count.
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular, app.processIdentifier != ownPID else { return }
            let bundleID = app.bundleIdentifier ?? ""
            MainActor.assumeIsolated { _ = self?.engine.send(.dismiss(.otherAppActivated(bundleID: bundleID))) }
        }
    }

    private func removeDismissalMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        mouseMonitor = nil
        activationObserver = nil
    }

    private func installEscapeFallback() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.keyCode == 53, event.window === self, !self.hasTap else { return false }
                return self.escape()
            }
            return handled ? nil : event
        }
    }

    private static func glass(containing content: NSView) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Theme.panelRadius
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = roundedMask(radius: Theme.panelRadius)
        content.frame = blur.bounds
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        return blur
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

struct TopPinnedPanel: View {
    let panel: PanelView
    var body: some View {
        panel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
