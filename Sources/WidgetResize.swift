// Shared widget chrome: edge-drag resizing for borderless widget windows.
// Compiled into each widget alongside main.swift — keep the copies identical.
//
// A borderless NSWindow has no resize chrome and no frame view to grab, so the
// window gets a transparent overlay that only hit-tests a 9pt band around the
// edges. Everything inside the band resizes; everything else falls through to
// SwiftUI. Double-clicking an edge snaps back to the design size.

import AppKit
import SwiftUI

enum WidgetResize {
    static func savedSize(key: String, fallback: NSSize, min: NSSize) -> NSSize {
        guard let stored = UserDefaults.standard.string(forKey: key) else { return fallback }
        let rect = NSRectFromString(stored)
        if rect.width >= min.width, rect.height >= min.height {
            return NSSize(width: rect.width.rounded(), height: rect.height.rounded())
        }
        return fallback
    }

    /// Wraps the hosted SwiftUI view in a plain container and lays the resize band
    /// on top of it.
    ///
    /// Do NOT make the NSHostingView the content view: it is an Auto Layout view, so
    /// its frame silently disagrees with the window once anything resizes it (seen:
    /// window 380x470, hosting view 380x380, so the bottom 90pt had no resize band).
    /// Pinning it to a dumb container with constraints keeps all three in step.
    @discardableResult
    static func install(window: NSWindow, hosting: NSView,
                        minSize: NSSize, defaultSize: NSSize, key: String) -> NSView {
        let container = WidgetContainerView(frame: NSRect(origin: .zero, size: window.frame.size))
        container.autoresizingMask = [.width, .height]

        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let overlay = ResizeOverlayView(minSize: minSize, defaultSize: defaultSize, key: key)
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(overlay, positioned: .above, relativeTo: nil)

        window.contentView = container
        window.minSize = NSSize(width: max(minSize.width, 260), height: max(minSize.height, 260))
        return overlay
    }
}

/// Plain content view so `isMovableByWindowBackground` keeps working once the
/// hosting view is no longer the content view itself.
final class WidgetContainerView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// A strip that drags the whole window when you press it — the reliable move zone for
/// borderless widgets whose body is mostly SwiftUI (SwiftUI views can swallow the
/// background drag that `isMovableByWindowBackground` relies on).
struct WidgetDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { self }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Pure geometry: given the frame a drag started from and the cursor delta since,
/// return the new frame with the opposite edge anchored. Kept separate from the
/// event code so it can be asserted headlessly (`--resize-test`).
enum ResizeEdge { case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }

func resizedFrame(edge: ResizeEdge, start: NSRect, dx: CGFloat, dy: CGFloat,
                  minSize: NSSize) -> NSRect {
    let minW = max(minSize.width, 240)
    let minH = max(minSize.height, 240)
    var frame = start
    switch edge {
    case .right:
        frame.size.width = max(minW, start.width + dx)
    case .left:
        let width = max(minW, start.width - dx)
        frame.origin.x = start.maxX - width
        frame.size.width = width
    case .top:
        frame.size.height = max(minH, start.height + dy)
    case .bottom:
        let height = max(minH, start.height - dy)
        frame.origin.y = start.maxY - height
        frame.size.height = height
    case .topRight:
        frame.size.width = max(minW, start.width + dx)
        frame.size.height = max(minH, start.height + dy)
    case .topLeft:
        let width = max(minW, start.width - dx)
        frame.origin.x = start.maxX - width
        frame.size.width = width
        frame.size.height = max(minH, start.height + dy)
    case .bottomRight:
        frame.size.width = max(minW, start.width + dx)
        let height = max(minH, start.height - dy)
        frame.origin.y = start.maxY - height
        frame.size.height = height
    case .bottomLeft:
        let width = max(minW, start.width - dx)
        frame.origin.x = start.maxX - width
        frame.size.width = width
        let height = max(minH, start.height - dy)
        frame.origin.y = start.maxY - height
        frame.size.height = height
    }
    return frame
}

final class ResizeOverlayView: NSView {
    private typealias Edge = ResizeEdge

    private let minSize: NSSize
    private let defaultSize: NSSize
    private let key: String
    private let band: CGFloat = 9

    private var active: Edge?
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    init(minSize: NSSize, defaultSize: NSSize, key: String) {
        self.minSize = minSize
        self.defaultSize = defaultSize
        self.key = key
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: hit testing

    private func edge(at point: NSPoint) -> Edge? {
        guard bounds.width > 2 * band + 60, bounds.height > 2 * band + 60 else { return nil }
        let left = point.x <= band
        let right = point.x >= bounds.width - band
        let top = point.y >= bounds.height - band
        let bottom = point.y <= band
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return edge(at: local) == nil ? nil : self
    }

    // MARK: cursors

    private func cursor(for edge: Edge) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch edge {
            case .left: position = .left
            case .right: position = .right
            case .top: position = .top
            case .bottom: position = .bottom
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch edge {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return .resizeLeftRight
        case .topRight, .bottomLeft: return .resizeLeftRight
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let w = bounds.width, h = bounds.height
        addCursorRect(NSRect(x: 0, y: band, width: band, height: max(0, h - 2 * band)), cursor: cursor(for: .left))
        addCursorRect(NSRect(x: w - band, y: band, width: band, height: max(0, h - 2 * band)), cursor: cursor(for: .right))
        addCursorRect(NSRect(x: band, y: h - band, width: max(0, w - 2 * band), height: band), cursor: cursor(for: .top))
        addCursorRect(NSRect(x: band, y: 0, width: max(0, w - 2 * band), height: band), cursor: cursor(for: .bottom))
        addCursorRect(NSRect(x: 0, y: h - band, width: band, height: band), cursor: cursor(for: .topLeft))
        addCursorRect(NSRect(x: w - band, y: h - band, width: band, height: band), cursor: cursor(for: .topRight))
        addCursorRect(NSRect(x: 0, y: 0, width: band, height: band), cursor: cursor(for: .bottomLeft))
        addCursorRect(NSRect(x: w - band, y: 0, width: band, height: band), cursor: cursor(for: .bottomRight))
    }

    // MARK: dragging

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let grabbed = edge(at: point) else { return }

        if event.clickCount == 2 {          // double-click an edge: back to design size
            snapToDefault(edge: grabbed)
            return
        }
        active = grabbed
        startFrame = window.frame
        startMouse = window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabbed = active, let window = window else { return }
        let now = window.convertPoint(toScreen: event.locationInWindow)
        let frame = resizedFrame(edge: grabbed, start: startFrame,
                                 dx: now.x - startMouse.x, dy: now.y - startMouse.y,
                                 minSize: minSize)
        window.setFrame(frame, display: true)
        window.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard active != nil, let window = window else { active = nil; return }
        persist(window.frame.size)
        active = nil
        window.invalidateCursorRects(for: self)
    }

    private func snapToDefault(edge: Edge) {
        guard let window = window else { return }
        let size = NSSize(width: max(defaultSize.width, minSize.width),
                          height: max(defaultSize.height, minSize.height))
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
        persist(size)
        window.invalidateCursorRects(for: self)
    }

    private func persist(_ size: NSSize) {
        UserDefaults.standard.set(NSStringFromRect(NSRect(origin: .zero, size: size)), forKey: key)
    }

    /// Menu-driven reset, for when dragging an edge is fiddly.
    static func resetSize(window: NSWindow, to size: NSSize, key: String) {
        let origin = NSPoint(x: window.frame.minX,
                             y: window.frame.maxY - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        UserDefaults.standard.set(NSStringFromRect(NSRect(origin: .zero, size: size)), forKey: key)
    }
}

// MARK: - one switch for every widget

/// The widgets are separate apps, so "hide all" travels over the distributed
/// notification centre: any status item can command the rest (and itself).
enum WidgetBus {
    enum Command: String {
        case hideAll = "local.abduel.widgets.hideAll"
        case showAll = "local.abduel.widgets.showAll"
    }

    private static var tokens: [NSObjectProtocol] = []

    static func post(_ command: Command) {
        DistributedNotificationCenter.default().post(name: NSNotification.Name(command.rawValue),
                                                     object: nil)
    }

    static func observe(_ handler: @escaping (Command) -> Void) {
        let center = DistributedNotificationCenter.default()
        for command in [Command.hideAll, .showAll] {
            tokens.append(center.addObserver(forName: NSNotification.Name(command.rawValue),
                                             object: nil, queue: .main) { _ in
                handler(command)
            })
        }
    }
}

// MARK: - lock-screen pinning

/// Widgets stay freely draggable while you work, but every lock (and screensaver
/// start) snaps them back to their home slot, so unlocking never lands on a screen
/// full of panels you shoved out of the way.
enum WidgetPin {
    private static var tokens: [NSObjectProtocol] = []

    static func install(window: NSWindow, home: @escaping () -> NSPoint) {
        let center = DistributedNotificationCenter.default()
        let handler: (Notification) -> Void = { _ in
            DispatchQueue.main.async {
                window.setFrameOrigin(home())
            }
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            tokens.append(center.addObserver(forName: NSNotification.Name(name),
                                             object: nil, queue: .main, using: handler))
        }
    }

    /// Offset the window away from home (test hook and the odd manual nudge).
    static func park(_ window: NSWindow, by delta: NSPoint) {
        window.setFrameOrigin(NSPoint(x: window.frame.minX + delta.x,
                                      y: window.frame.minY + delta.y))
    }

    /// Print the live content hierarchy so a resize band that went missing is obvious.
    static func describe(_ window: NSWindow) {
        func walk(_ view: NSView, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            print("\(pad)\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue)")
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        if let cv = window.contentView { walk(cv, depth: 0) }
    }

    /// Headless proof: displace, post the lock notification, confirm it landed home.
    /// Compares against the home closure, not the launch position — on-demand widgets
    /// (mixer, shelf) open under the cursor, so start != home.
    static func runSelfTest(window: NSWindow, home: @escaping () -> NSPoint) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let target = home()
            park(window, by: NSPoint(x: -140, y: 90))
            let parked = window.frame.origin
            DistributedNotificationCenter.default().post(
                name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let after = window.frame.origin
                let moved = abs(parked.x - target.x) > 40 || abs(parked.y - target.y) > 40
                let returned = abs(after.x - target.x) < 1.5 && abs(after.y - target.y) < 1.5
                print("pin-test: home \(target) parked \(parked) after-lock \(after)")
                print(moved && returned ? "PASS" : "FAIL")
                exit(moved && returned ? 0 : 1)
            }
        }
    }
}

// MARK: - desktop layer

/// Pinned widgets live one level above the desktop icons and below every normal
/// window, on every Space, and Mission Control / Show Desktop leave them in place.
/// Clicking one still works (it becomes key) but never raises it over other apps.
/// Above the icon level, not below it: below it, Finder's full-screen icon window
/// would sit on top and eat the clicks.
enum WidgetLayer {
    static let pinKey = "widget.pinnedToDesktop"
    static let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    static var pinned: Bool {
        get {
            UserDefaults.standard.register(defaults: [pinKey: true])
            return UserDefaults.standard.bool(forKey: pinKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: pinKey) }
    }

    static func apply(_ window: NSWindow) {
        if pinned {
            window.level = desktop
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }
}
