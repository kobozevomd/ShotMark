import AppKit
import UniformTypeIdentifiers

/// Borderless full-screen panel above everything, including the menu bar and full-screen apps.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One screenshot in progress: an overlay per screen, a single selection across them.
final class CaptureSession: NSObject, NSSharingServicePickerDelegate {
    static private(set) var current: CaptureSession?

    private var windows: [OverlayWindow] = []
    private var canvases: [CanvasView] = []
    private let previousApp: NSRunningApplication?
    private var sharePicker: NSSharingServicePicker?

    static func start(shots: [Shot], previousApp: NSRunningApplication?) {
        let session = CaptureSession(shots: shots, previousApp: previousApp)
        current = session
        session.show()
    }

    private init(shots: [Shot], previousApp: NSRunningApplication?) {
        self.previousApp = previousApp
        for shot in shots {
            let window = OverlayWindow(screen: shot.screen)
            let size = shot.screen.frame.size
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            container.wantsLayer = true

            let background = NSView(frame: container.bounds)
            background.wantsLayer = true
            background.layer?.contents = shot.image
            background.layer?.contentsGravity = .resize
            background.layerContentsRedrawPolicy = .never
            background.autoresizingMask = [.width, .height]

            let canvas = CanvasView(frame: container.bounds, image: shot.image)
            canvas.session = self
            canvas.autoresizingMask = [.width, .height]

            container.addSubview(background)
            container.addSubview(canvas)
            window.contentView = container
            windows.append(window)
            canvases.append(canvas)
        }
        super.init()
    }

    private func show() {
        NSApp.unhideWithoutActivation()
        let mouse = NSEvent.mouseLocation
        let keyIndex = windows.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        for window in windows {
            window.orderFrontRegardless()
        }
        NSApp.activate()
        windows[keyIndex].makeKeyAndOrderFront(nil)
        windows[keyIndex].makeFirstResponder(canvases[keyIndex])
        NSCursor.crosshair.set()
    }

    /// A new selection on one screen drops the selection on the others.
    func canvasWillStartSelection(_ canvas: CanvasView) {
        for other in canvases where other !== canvas {
            other.reset()
        }
    }

    func cancel() {
        close()
        restoreFocus()
    }

    /// Hands focus back to the app that was active before the hotkey.
    private func restoreFocus() {
        if let previousApp, previousApp != NSRunningApplication.current, !previousApp.isTerminated,
           previousApp.activate(from: NSRunningApplication.current, options: []) {
            return
        }
        NSApp.hide(nil)
    }

    func copy(_ rep: NSBitmapImageRep, screenRect: CGRect) {
        close()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation(using: .lzw, factor: 0) {
            pasteboard.setData(tiff, forType: .tiff)
        }
        restoreFocus()
        Toast.show("Скопировано в буфер обмена", around: screenRect)
    }

    func save(_ rep: NSBitmapImageRep) {
        close()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = CaptureSession.defaultFileName()
        if panel.directoryURL == nil {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        NSApp.activate()
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
            let data = isJPEG
                ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                : rep.representation(using: .png, properties: [:])
            do {
                try data?.write(to: url)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
        restoreFocus()
    }

    /// Shows the system share picker under `anchor`; the overlay stays up until a service is chosen.
    func share(_ rep: NSBitmapImageRep, from anchor: NSView) {
        // A file with a readable name, not a bare image: messengers and Mail keep the name and the PNG as is.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShotMark", isDirectory: true)
        let url = dir.appendingPathComponent(CaptureSession.defaultFileName())
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        // The picker is a menu/popover: it would open under a screen-saver-level window.
        for window in windows { window.level = .statusBar }
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        sharePicker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        sharePicker = nil
        if service == nil {
            // Dismissed: back to editing.
            for window in windows { window.level = .screenSaver }
            return
        }
        // The service brings up its own window (AirDrop, Messages, Mail…); it must not end up under the overlay.
        close()
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return "Снимок экрана \(formatter.string(from: Date())).png"
    }

    private func close() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        canvases.removeAll()
        CaptureSession.current = nil
    }
}

/// Small "copied" bubble that fades out by itself.
enum Toast {
    private static var window: NSPanel?

    static func show(_ text: String, around rect: CGRect) {
        window?.orderOut(nil)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 28, height: label.frame.height + 14)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.maskImage = ToolbarView.roundedMask(radius: size.height / 2)
        label.frame.origin = NSPoint(x: 14, y: 7)
        effect.addSubview(label)

        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = effect
        panel.orderFrontRegardless()
        window = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if window === panel { window = nil }
            })
        }
    }
}
