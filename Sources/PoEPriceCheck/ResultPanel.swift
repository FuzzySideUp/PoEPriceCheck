import AppKit
import Combine
import SwiftUI

/// Floating, non-activating panel that sits above a fullscreen GeForce NOW window.
/// It never becomes key, so keyboard input keeps going to the game.
final class ResultPanel: NSPanel {
    private let hosting: FirstMouseHostingView<PanelView>
    private var anchorTopLeft = CGPoint.zero
    private var triggerPoint = CGPoint.zero
    private var watchTimer: Timer?
    private var outsideSince: Date?
    private var escKey: HotKey?
    private var sizeObserver: AnyCancellable?
    var onDismiss: (() -> Void)?

    init(model: PanelModel) {
        hosting = FirstMouseHostingView(rootView: PanelView(model: model))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 430, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        contentView = hosting
        // Re-fit whenever SwiftUI content changes size.
        sizeObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel next to `cursor` (global coords), on the side away from the tooltip.
    func show(near cursor: CGPoint, tooltipCenterX: CGFloat?, on screen: NSScreen) {
        triggerPoint = cursor
        let size = hosting.fittingSize
        let tooltipOnLeft = (tooltipCenterX ?? cursor.x + 1) < cursor.x
        var x = tooltipOnLeft ? cursor.x + 28 : cursor.x - 28 - size.width
        let f = screen.frame
        if x < f.minX + 8 { x = cursor.x + 28 }
        if x + size.width > f.maxX - 8 { x = cursor.x - 28 - size.width }
        let top = min(f.maxY - 8, cursor.y + 120)
        anchorTopLeft = CGPoint(x: x, y: top)
        fitToContent()
        orderFrontRegardless()
        startWatching()
    }

    func reposition(tooltipCenterX: CGFloat, on screen: NSScreen) {
        show(near: triggerPoint, tooltipCenterX: tooltipCenterX, on: screen)
    }

    func fitToContent() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard let screen = screen ?? NSScreen.main else { return }
        var top = anchorTopLeft.y
        if top - size.height < screen.frame.minY + 8 { top = screen.frame.minY + 8 + size.height }
        setFrame(NSRect(x: anchorTopLeft.x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    func dismiss() {
        watchTimer?.invalidate(); watchTimer = nil
        escKey = nil
        orderOut(nil)
        onDismiss?()
    }

    /// Esc (only while visible) and "mouse moved well away" close the panel.
    private func startWatching() {
        escKey = HotKey(HotKey.escape) { [weak self] in self?.dismiss() }
        outsideSince = nil
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let m = NSEvent.mouseLocation
            // Keep alive while the mouse is over the panel, near where the check started,
            // or on the path between the two.
            let near = CGRect(x: triggerPoint.x - 90, y: triggerPoint.y - 90, width: 180, height: 180)
            let keep = frame.insetBy(dx: -40, dy: -40).union(near)
            if keep.contains(m) {
                outsideSince = nil
            } else if let since = outsideSince {
                if Date().timeIntervalSince(since) > 0.35 { dismiss() }
            } else {
                outsideSince = Date()
            }
        }
    }
}

/// Lets clicks land on controls even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
