import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum Corner: String {
    case topLeft, topRight, bottomLeft, bottomRight

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isRight: Bool { self == .topRight || self == .bottomRight }
}

/// How the open panel shows the day: A is a list, B a focus timer, C the card.
enum ViewMode: String, CaseIterable {
    case list, focus, card

    var next: ViewMode {
        let all = ViewMode.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Owns the panel and bubble windows and pins whichever is showing to the corner the user chose.
final class FloatingController: NSObject, ObservableObject {
    @Published private(set) var isExpanded = true
    @Published var mode: ViewMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    private let panelWindow: FloatingPanel
    private let bubbleWindow: FloatingPanel
    /// Published so the panel can put its height grip on the edge away from the corner.
    @Published private(set) var corner: Corner
    private var screen: NSScreen?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isPinning = false
    private var pendingSnap: DispatchWorkItem?
    private lazy var flyingPicture = FlyingPicture()
    /// Counts shrink and grow animations, so a finished one does nothing if a newer one has started.
    private var switchCount = 0

    private static let margin: CGFloat = 12
    private static let panelCornerRadius: CGFloat = 16
    private static let cornerKey = "corner"
    private static let modeKey = "viewMode"

    override init() {
        corner = Corner(rawValue: UserDefaults.standard.string(forKey: Self.cornerKey) ?? "") ?? .topRight
        mode = ViewMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .list
        panelWindow = FloatingPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bubbleWindow = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        for window in [panelWindow, bubbleWindow] {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true
            window.hasShadow = true
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.pin(window)
            }
        }
        panelWindow.titlebarAppearsTransparent = true
        panelWindow.titleVisibility = .hidden
        // Only the top bar moves the panel, so dragging a row reorders it instead of moving the window.
        panelWindow.isMovableByWindowBackground = false
        bubbleWindow.isOpaque = false
        bubbleWindow.backgroundColor = .clear
        wireWindowButtons()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panelWindow, queue: .main) { [weak self] _ in
            self?.panelMoved()
        }
    }

    func show<Panel: View, Bubble: View>(panel: Panel, bubble: Bubble) {
        panelWindow.contentViewController = hostingController(panel)
        bubbleWindow.contentViewController = hostingController(bubble)
        showCurrentWindow()
    }

    func expand() {
        guard !isExpanded else {
            showCurrentWindow()
            return
        }
        isExpanded = true
        animateSwitch(from: bubbleWindow, to: panelWindow)
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        animateSwitch(from: panelWindow, to: bubbleWindow)
    }

    // MARK: - Dragging the bubble

    /// Moves the bubble with the mouse. Screen coordinates stay stable while the window itself moves.
    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil {
            dragStartMouse = mouse
            dragStartOrigin = bubbleWindow.frame.origin
        }
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        bubbleWindow.setFrameOrigin(NSPoint(x: startOrigin.x + mouse.x - startMouse.x, y: startOrigin.y + mouse.y - startMouse.y))
    }

    func dragEnded() {
        dragStartMouse = nil
        dragStartOrigin = nil
        snapToNearestCorner(bubbleWindow)
    }

    // MARK: - Windows

    /// Size from the content only, and ignore the title bar's safe area: letting either drive layout loops the window forever.
    private func hostingController<Content: View>(_ view: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        controller.safeAreaRegions = []
        return controller
    }

    private func showCurrentWindow() {
        let shown = isExpanded ? panelWindow : bubbleWindow
        let hidden = isExpanded ? bubbleWindow : panelWindow
        hidden.orderOut(nil)
        pin(shown)
        shown.alphaValue = 1
        shown.orderFrontRegardless()
    }

    // MARK: - Shrinking to the bubble and growing back

    /// Flies a picture of the panel between the panel's place and the bubble's, so the real panel's layout is never squeezed.
    private func animateSwitch(from oldWindow: NSWindow, to newWindow: NSWindow) {
        switchCount += 1
        let thisSwitch = switchCount
        flyingPicture.hide()
        pin(newWindow)
        let isCollapsing = newWindow === bubbleWindow
        guard oldWindow.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let picture = picture(of: panelWindow) else {
            showCurrentWindow()
            return
        }
        let panelFrame = panelWindow.frame
        let bubbleFrame = bubbleWindow.frame
        let flying = flyingPicture
        flying.show(picture, frame: isCollapsing ? panelFrame : bubbleFrame, isFaded: !isCollapsing, cornerRadius: isCollapsing ? Self.panelCornerRadius : bubbleFrame.width / 2)
        oldWindow.orderOut(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = isCollapsing ? 0.28 : 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            flying.move(to: isCollapsing ? bubbleFrame : panelFrame, isFaded: isCollapsing, cornerRadius: isCollapsing ? bubbleFrame.width / 2 : Self.panelCornerRadius)
        }, completionHandler: { [weak self] in
            guard let self, thisSwitch == self.switchCount else { return }
            self.fadeIn(newWindow) {
                if thisSwitch == self.switchCount {
                    flying.hide()
                }
            }
        })
    }

    private func fadeIn(_ window: NSWindow, then finish: @escaping () -> Void) {
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }, completionHandler: finish)
    }

    private func picture(of window: NSWindow) -> NSImage? {
        guard let view = window.contentView, view.bounds.width > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Red and yellow shrink to the bubble instead of closing, so the alarms keep running. Green switches the view.
    private func wireWindowButtons() {
        let actions: [(NSWindow.ButtonType, Selector)] = [
            (.closeButton, #selector(collapseFromWindowButton)),
            (.miniaturizeButton, #selector(collapseFromWindowButton)),
            (.zoomButton, #selector(switchModeFromWindowButton)),
        ]
        for (type, action) in actions {
            panelWindow.standardWindowButton(type)?.target = self
            panelWindow.standardWindowButton(type)?.action = action
        }
        panelWindow.standardWindowButton(.closeButton)?.toolTip = "Shrink to the bubble. Alarms keep running."
        panelWindow.standardWindowButton(.miniaturizeButton)?.toolTip = "Shrink to the bubble. Alarms keep running."
        panelWindow.standardWindowButton(.zoomButton)?.toolTip = "Switch to the next view"
    }

    @objc private func collapseFromWindowButton() {
        collapse()
    }

    @objc private func switchModeFromWindowButton() {
        mode = mode.next
    }

    /// The panel is dragged by its title bar, which gives no mouse-up, so snap once it has stopped moving.
    private func panelMoved() {
        guard !isPinning else { return }
        pendingSnap?.cancel()
        let snap = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons != 0 {
                self.panelMoved()
            } else {
                self.snapToNearestCorner(self.panelWindow)
            }
        }
        pendingSnap = snap
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: snap)
    }

    private func snapToNearestCorner(_ window: NSWindow) {
        screen = window.screen ?? screen
        guard let screen = visibleScreenFrame else { return }
        let isRight = window.frame.midX > screen.midX
        let isTop = window.frame.midY > screen.midY
        corner = isTop ? (isRight ? .topRight : .topLeft) : (isRight ? .bottomRight : .bottomLeft)
        UserDefaults.standard.set(corner.rawValue, forKey: Self.cornerKey)
        isPinning = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().setFrame(frame(in: screen, size: window.frame.size), display: true)
        }, completionHandler: { [weak self] in
            self?.isPinning = false
        })
    }

    private func pin(_ window: NSWindow) {
        guard dragStartMouse == nil, let screen = visibleScreenFrame else { return }
        isPinning = true
        window.setFrame(frame(in: screen, size: window.frame.size), display: true)
        window.invalidateShadow()
        isPinning = false
    }

    /// The screen the user last dropped a window on, else the menu-bar screen; a window's own screen can be wrong mid-resize.
    /// The most the panel's scrolling content may take on the screen it is on, leaving room for its header, grip and footer.
    var tallestContentHeight: Double {
        Double((visibleScreenFrame?.height ?? 800) - 160)
    }

    private var visibleScreenFrame: NSRect? {
        (screen ?? NSScreen.screens.first)?.visibleFrame
    }

    private func frame(in screen: NSRect, size: NSSize) -> NSRect {
        let x = corner.isRight ? screen.maxX - size.width - Self.margin : screen.minX + Self.margin
        let y = corner.isTop ? screen.maxY - size.height - Self.margin : screen.minY + Self.margin
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

/// A borderless window that shows a picture of the panel while it shrinks into the bubble or grows back.
/// One is reused for every animation, and it lets go of the picture when hidden.
final class FlyingPicture {
    private let window: NSWindow
    private let imageView = NSImageView()

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        window.contentView = imageView
    }

    func show(_ picture: NSImage, frame: NSRect, isFaded: Bool, cornerRadius: CGFloat) {
        imageView.image = picture
        imageView.layer?.cornerRadius = cornerRadius
        window.setFrame(frame, display: true)
        window.alphaValue = isFaded ? 0 : 1
        window.orderFrontRegardless()
    }

    /// Call inside an animation group.
    func move(to frame: NSRect, isFaded: Bool, cornerRadius: CGFloat) {
        window.animator().setFrame(frame, display: true)
        window.animator().alphaValue = isFaded ? 0 : 1
        let rounding = CABasicAnimation(keyPath: "cornerRadius")
        rounding.fromValue = imageView.layer?.cornerRadius
        rounding.toValue = cornerRadius
        rounding.duration = NSAnimationContext.current.duration
        rounding.timingFunction = NSAnimationContext.current.timingFunction
        imageView.layer?.add(rounding, forKey: "cornerRadius")
        imageView.layer?.cornerRadius = cornerRadius
    }

    func hide() {
        window.orderOut(nil)
        imageView.image = nil
    }
}
