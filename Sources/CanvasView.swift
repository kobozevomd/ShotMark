import AppKit

/// Overlay for one screen: dims the frozen screenshot, lets the user pick a region and annotate it.
final class CanvasView: NSView, NSTextViewDelegate {
    weak var session: CaptureSession?

    private let image: CGImage
    /// Pixels per point of the captured image.
    private var scale: CGFloat { bounds.width > 0 ? CGFloat(image.width) / bounds.width : 2 }

    private(set) var selection: CGRect?
    private var annotations: [Annotation] = []
    private var current: Annotation?

    private var tool: Tool? { didSet { updateToolButtons() } }
    private var color: NSColor = Settings.color {
        didSet {
            Settings.color = color
            colorButton.swatch = color
            palette?.removeFromSuperview()
            palette = nil
        }
    }
    private var lineWidth: CGFloat = Settings.lineWidth { didSet { Settings.lineWidth = lineWidth } }

    private enum Handle { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    private enum Drag {
        case none
        case creating(start: CGPoint)
        case moving(original: CGRect, start: CGPoint)
        case resizing(handle: Handle, original: CGRect, start: CGPoint)
        case drawing(start: CGPoint)
    }
    private var drag: Drag = .none
    private var lastDragPoint: CGPoint = .zero

    // Text being typed right now.
    private var textView: NSTextView?
    private var textTop: CGFloat = 0
    private var textFontSize: CGFloat = 0
    private var textColor: NSColor = .red

    private var toolsBar: ToolbarView!
    private var actionsBar: ToolbarView!
    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var colorButton: ToolbarButton!
    private var shareButton: ToolbarButton!
    private var palette: ToolbarView?

    private var widthHint: (point: CGPoint, until: Date)?
    private var scrollAccumulator: CGFloat = 0

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        buildToolbars()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Toolbars

    private func buildToolbars() {
        var items: [NSView] = []
        for t in Tool.allCases {
            let b = ToolbarButton(symbol: t.symbol, tooltip: t.title) { [weak self] in
                self?.toggleTool(t)
            }
            toolButtons[t] = b
            items.append(b)
        }
        items.append(ToolbarView.separator())
        colorButton = ToolbarButton(symbol: nil, tooltip: "Цвет и толщина (колесо мыши — толщина)") { [weak self] in
            self?.togglePalette()
        }
        colorButton.swatch = color
        items.append(colorButton)
        items.append(ToolbarButton(symbol: "arrow.uturn.backward", tooltip: "Отменить (⌘Z)") { [weak self] in
            self?.undo()
        })
        toolsBar = ToolbarView(items: items, vertical: true)

        shareButton = ToolbarButton(symbol: "square.and.arrow.up", tooltip: "Поделиться") { [weak self] in self?.share() }
        actionsBar = ToolbarView(items: [
            ToolbarButton(symbol: "doc.on.doc", tooltip: "Копировать (⌘C)") { [weak self] in self?.copyToClipboard() },
            ToolbarButton(symbol: "square.and.arrow.down", tooltip: "Сохранить (⌘S)") { [weak self] in self?.saveToFile() },
            shareButton,
            ToolbarView.separator(),
            ToolbarButton(symbol: "xmark", tooltip: "Закрыть (Esc)") { [weak self] in self?.session?.cancel() },
        ], vertical: false)

        toolsBar.isHidden = true
        actionsBar.isHidden = true
        addSubview(toolsBar)
        addSubview(actionsBar)
    }

    private func updateToolButtons() {
        for (t, b) in toolButtons {
            b.isSelected = (t == tool)
        }
    }

    private func toggleTool(_ t: Tool) {
        commitText()
        tool = (tool == t) ? nil : t
        window?.invalidateCursorRects(for: self)
    }

    private func showToolbars(_ visible: Bool) {
        toolsBar.isHidden = !visible
        actionsBar.isHidden = !visible
        if !visible {
            palette?.removeFromSuperview()
            palette = nil
        }
        if visible { layoutToolbars() }
    }

    private func layoutToolbars() {
        guard let sel = selection else { return }
        let gap: CGFloat = 8, margin: CGFloat = 4

        // Vertical tools: right of the selection, bottom-aligned (like Lightshot); fall back to left, then inside.
        let ts = toolsBar.frame.size
        var tx = sel.maxX + gap
        if tx + ts.width > bounds.maxX - margin { tx = sel.minX - gap - ts.width }
        if tx < bounds.minX + margin { tx = sel.maxX - gap - ts.width }
        var ty = sel.minY
        ty = min(max(ty, bounds.minY + margin), bounds.maxY - ts.height - margin)
        toolsBar.setFrameOrigin(NSPoint(x: tx.rounded(), y: ty.rounded()))

        // Horizontal actions: under the selection, right-aligned; fall back to above, then inside.
        let asz = actionsBar.frame.size
        var ax = sel.maxX - asz.width
        var ay = sel.minY - gap - asz.height
        if ay < bounds.minY + margin { ay = sel.maxY + gap }
        if ay + asz.height > bounds.maxY - margin { ay = sel.minY + gap }
        ax = min(max(ax, bounds.minX + margin), bounds.maxX - asz.width - margin)
        var aFrame = NSRect(origin: NSPoint(x: ax, y: ay), size: asz)
        if aFrame.intersects(toolsBar.frame) {
            aFrame.origin.x = toolsBar.frame.minX - gap - asz.width
        }
        actionsBar.setFrameOrigin(NSPoint(x: aFrame.minX.rounded(), y: aFrame.minY.rounded()))

        if let palette { positionPalette(palette) }
    }

    private func togglePalette() {
        commitText()
        if let palette {
            palette.removeFromSuperview()
            self.palette = nil
            return
        }
        var items: [NSView] = []
        for c in Palette.colors {
            let b = ToolbarButton(symbol: nil, tooltip: "") { [weak self] in self?.color = c }
            b.swatch = c
            b.showsRing = c.isClose(to: color)
            items.append(b)
        }
        items.append(ToolbarView.separator())
        for w in Palette.widths {
            let b = ToolbarButton(symbol: nil, tooltip: "Толщина \(Int(w))") { [weak self] in
                self?.lineWidth = w
                self?.palette?.removeFromSuperview()
                self?.palette = nil
            }
            b.dotDiameter = w + 3
            b.isSelected = (w == lineWidth)
            items.append(b)
        }
        let p = ToolbarView(items: items, vertical: false)
        addSubview(p)
        palette = p
        positionPalette(p)
    }

    private func positionPalette(_ p: ToolbarView) {
        let button = colorButton.convert(colorButton.bounds, to: self)
        var x = toolsBar.frame.minX - 6 - p.frame.width
        if x < bounds.minX + 4 { x = toolsBar.frame.maxX + 6 }
        x = min(x, bounds.maxX - p.frame.width - 4)
        let y = min(max(button.midY - p.frame.height / 2, bounds.minY + 4), bounds.maxY - p.frame.height - 4)
        p.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func isOverChrome(_ p: CGPoint) -> Bool {
        [toolsBar, actionsBar, palette].contains { bar in
            guard let bar, !bar.isHidden else { return false }
            return bar.frame.contains(p)
        }
    }

    // MARK: - Public

    func reset() {
        cancelText()
        selection = nil
        annotations.removeAll()
        current = nil
        tool = nil
        drag = .none
        showToolbars(false)
        needsDisplay = true
    }

    // MARK: - Geometry helpers

    private func align(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    private func alignedRect(_ r: CGRect) -> CGRect {
        let minX = align(r.minX), minY = align(r.minY), maxX = align(r.maxX), maxY = align(r.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func handle(at p: CGPoint, in r: CGRect) -> Handle? {
        let corner: CGFloat = 8
        let edge: CGFloat = tool == nil ? 6 : 4
        let l = abs(p.x - r.minX), rr = abs(p.x - r.maxX), b = abs(p.y - r.minY), t = abs(p.y - r.maxY)
        if l <= corner && t <= corner { return .topLeft }
        if rr <= corner && t <= corner { return .topRight }
        if l <= corner && b <= corner { return .bottomLeft }
        if rr <= corner && b <= corner { return .bottomRight }
        let inX = p.x > r.minX && p.x < r.maxX
        let inY = p.y > r.minY && p.y < r.maxY
        if t <= edge && inX { return .top }
        if b <= edge && inX { return .bottom }
        if l <= edge && inY { return .left }
        if rr <= edge && inY { return .right }
        return nil
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func resized(_ o: CGRect, handle h: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
        switch h {
        case .left, .topLeft, .bottomLeft: minX += dx
        case .right, .topRight, .bottomRight: maxX += dx
        default: break
        }
        switch h {
        case .top, .topLeft, .topRight: maxY += dy
        case .bottom, .bottomLeft, .bottomRight: minY += dy
        default: break
        }
        let r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        return alignedRect(r.intersection(bounds))
    }

    /// Shift: snap lines to 45°, make squares / circles.
    private func constrained(from s: CGPoint, to p: CGPoint, shift: Bool) -> CGPoint {
        guard shift, let tool else { return p }
        let dx = p.x - s.x, dy = p.y - s.y
        switch tool {
        case .line, .arrow:
            let len = hypot(dx, dy)
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
        default:
            return p
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at p: CGPoint) {
        if isOverChrome(p) {
            NSCursor.arrow.set()
            return
        }
        if let textView, textView.frame.contains(p) {
            NSCursor.iBeam.set()
            return
        }
        guard let sel = selection else {
            NSCursor.crosshair.set()
            return
        }
        if let h = handle(at: p, in: sel) {
            resizeCursor(h).set()
        } else if sel.contains(p) {
            switch tool {
            case nil: NSCursor.openHand.set()
            case .text: NSCursor.iBeam.set()
            default: NSCursor.crosshair.set()
            }
        } else {
            (annotations.isEmpty ? NSCursor.crosshair : NSCursor.arrow).set()
        }
    }

    private func resizeCursor(_ h: Handle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch h {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch h {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        lastDragPoint = p

        if let palette {
            palette.removeFromSuperview()
            self.palette = nil
        }

        let wasEditingText = textView != nil
        commitText()

        if let sel = selection {
            if let h = handle(at: p, in: sel) {
                drag = .resizing(handle: h, original: sel, start: p)
                return
            }
            if let tool, sel.contains(p) {
                if tool == .text {
                    // A click while typing just finishes the text; the next click starts a new one.
                    if !wasEditingText { beginText(at: p) }
                    return
                }
                drag = .drawing(start: p)
                current = newAnnotation(tool: tool, at: p)
                needsDisplay = true
                return
            }
            if tool == nil && sel.contains(p) {
                drag = .moving(original: sel, start: p)
                NSCursor.closedHand.set()
                return
            }
            // Don't throw away drawings by a stray click outside.
            if !annotations.isEmpty { return }
        }

        session?.canvasWillStartSelection(self)
        selection = nil
        showToolbars(false)
        drag = .creating(start: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        lastDragPoint = raw
        applyDrag(to: raw, shift: event.modifierFlags.contains(.shift))
    }

    private func applyDrag(to raw: CGPoint, shift: Bool) {
        let p = clamp(raw)
        switch drag {
        case .none:
            return
        case .creating(let start):
            selection = alignedRect(rect(start, p))
        case .moving(let original, let start):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
            selection = alignedRect(r)
            layoutToolbars()
        case .resizing(let h, let original, let start):
            selection = resized(original, handle: h, dx: p.x - start.x, dy: p.y - start.y)
            layoutToolbars()
        case .drawing(let start):
            guard var a = current else { return }
            let end = constrained(from: start, to: raw, shift: shift)
            switch a.kind {
            case .pen(var pts):
                if let last = pts.last, hypot(last.x - raw.x, last.y - raw.y) < 1 { return }
                pts.append(raw)
                a.kind = .pen(pts)
            case .marker(var pts):
                if let last = pts.last, hypot(last.x - raw.x, last.y - raw.y) < 1 { return }
                pts.append(raw)
                a.kind = .marker(pts)
            case .line: a.kind = .line(start, end)
            case .arrow: a.kind = .arrow(start, end)
            case .rectangle: a.kind = .rectangle(rect(start, end))
            case .ellipse: a.kind = .ellipse(rect(start, end))
            case .text: break
            }
            current = a
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .creating:
            if let sel = selection, sel.width >= 4, sel.height >= 4 {
                showToolbars(true)
            } else {
                selection = nil
            }
        case .moving, .resizing:
            if let sel = selection, sel.width < 4 || sel.height < 4 {
                selection = nil
                annotations.removeAll()
                showToolbars(false)
            }
        case .drawing:
            if let current, current.isMeaningful {
                annotations.append(current)
            }
            current = nil
        case .none:
            break
        }
        drag = .none
        updateCursor(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        if case .drawing = drag {
            applyDrag(to: lastDragPoint, shift: event.modifierFlags.contains(.shift))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 6 : 0.5
        guard abs(scrollAccumulator) >= threshold else { return }
        let step: CGFloat = scrollAccumulator > 0 ? 1 : -1
        scrollAccumulator = 0
        lineWidth = min(max(lineWidth + step, 1), 30)
        let until = Date().addingTimeInterval(0.9)
        widthHint = (convert(event.locationInWindow, from: nil), until)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let hint = self.widthHint, hint.until <= Date() else { return }
            self.widthHint = nil
            self.needsDisplay = true
        }
    }

    private func newAnnotation(tool: Tool, at p: CGPoint) -> Annotation {
        let kind: Annotation.Kind
        switch tool {
        case .pen: kind = .pen([p])
        case .marker: kind = .marker([p])
        case .line: kind = .line(p, p)
        case .arrow: kind = .arrow(p, p)
        case .rectangle: kind = .rectangle(CGRect(origin: p, size: .zero))
        case .ellipse: kind = .ellipse(CGRect(origin: p, size: .zero))
        case .text: kind = .text("", .zero, 0)
        }
        return Annotation(kind: kind, color: color, width: lineWidth)
    }

    // MARK: - Text

    private func beginText(at p: CGPoint) {
        let size = Annotation.fontSize(lineWidth)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = font
        tv.textColor = color
        tv.insertionPointColor = color
        tv.typingAttributes = Annotation.textAttributes(size: size, color: color)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let lineHeight = tv.layoutManager?.defaultLineHeight(for: font) ?? size * 1.2
        tv.minSize = NSSize(width: 2, height: lineHeight)
        tv.delegate = self
        textTop = (p.y + lineHeight / 2).rounded()
        tv.frame = NSRect(x: p.x.rounded(), y: textTop - lineHeight, width: 2, height: lineHeight)
        textFontSize = size
        textColor = color
        addSubview(tv)
        textView = tv
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView else { return }
        tv.sizeToFit()
        tv.setFrameOrigin(NSPoint(x: tv.frame.minX, y: textTop - tv.frame.height))
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                commitText()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            cancelText()
            return true
        default:
            return false
        }
    }

    private func commitText() {
        guard let tv = textView else { return }
        let text = tv.string
        let a = Annotation(kind: .text(text, tv.frame, textFontSize), color: textColor, width: lineWidth)
        if a.isMeaningful { annotations.append(a) }
        cancelText()
    }

    private func cancelText() {
        guard let tv = textView else { return }
        textView = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        // Key codes, not characters, so it works on the Russian layout.
        switch event.keyCode {
        case 8: // C
            copyToClipboard()
            return true
        case 1: // S
            saveToFile()
            return true
        case 6: // Z
            if textView != nil { return false } // let the text view undo typing
            undo()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        switch event.keyCode {
        case 53: // Esc
            if let palette {
                palette.removeFromSuperview()
                self.palette = nil
            } else {
                session?.cancel()
            }
        case 36, 76: // Return / Enter
            copyToClipboard()
        case 123, 124, 125, 126: // arrows nudge the selection
            guard var sel = selection, annotations.isEmpty || tool == nil else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1 / scale
            switch event.keyCode {
            case 123: sel.origin.x -= step
            case 124: sel.origin.x += step
            case 125: sel.origin.y -= step
            default: sel.origin.y += step
            }
            sel.origin.x = min(max(sel.origin.x, bounds.minX), bounds.maxX - sel.width)
            sel.origin.y = min(max(sel.origin.y, bounds.minY), bounds.maxY - sel.height)
            selection = alignedRect(sel)
            layoutToolbars()
            needsDisplay = true
        default:
            if flags.isEmpty, selection != nil, let t = Tool.forKeyCode(event.keyCode) {
                toggleTool(t)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    // MARK: - Output

    private func copyToClipboard() {
        commitText()
        let region = selection ?? bounds
        guard let rep = render(region) else { return }
        let screenRect = window.map { $0.convertToScreen(convert(region, to: nil)) } ?? region
        session?.copy(rep, screenRect: screenRect)
    }

    private func saveToFile() {
        commitText()
        guard let rep = render(selection ?? bounds) else { return }
        session?.save(rep)
    }

    private func share() {
        commitText()
        guard let rep = render(selection ?? bounds) else { return }
        session?.share(rep, from: shareButton)
    }

    /// Crops the screenshot to `region` at full pixel resolution and burns the annotations in.
    func render(_ region: CGRect) -> NSBitmapImageRep? {
        let s = scale
        let pw = Int((region.width * s).rounded()), ph = Int((region.height * s).rounded())
        guard pw > 0, ph > 0 else { return nil }
        // Keep the display's color space (e.g. Display P3) so colors don't shift; sRGB if it can't back an 8-bit context.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let makeContext = { (space: CGColorSpace) in
            CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        guard let ctx = image.colorSpace.flatMap(makeContext) ?? makeContext(srgb) else { return nil }
        ctx.interpolationQuality = .none
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        ctx.draw(image, in: bounds)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSBezierPath(rect: region).addClip()
        annotations.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = region.size // keeps Retina DPI, same as the system screenshots
        return rep
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor(white: 0, alpha: 0.45)

        guard let sel = selection else {
            dim.setFill()
            bounds.fill(using: .sourceOver)
            drawWidthHint()
            return
        }

        let shade = NSBezierPath(rect: bounds)
        shade.append(NSBezierPath(rect: sel))
        shade.windingRule = .evenOdd
        dim.setFill()
        shade.fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sel).addClip()
        annotations.forEach { $0.draw() }
        current?.draw()
        NSGraphicsContext.restoreGraphicsState()

        // Dashed frame just outside the selection, so it never ends up in the image.
        let frame = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        frame.lineWidth = 1
        NSColor.black.withAlphaComponent(0.7).setStroke()
        frame.stroke()
        frame.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        frame.stroke()

        let isCreating: Bool = { if case .creating = drag { return true } else { return false } }()
        if !isCreating {
            for pt in handlePoints(sel) {
                let r = CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)
                NSColor.white.setFill()
                r.fill()
                NSColor.black.withAlphaComponent(0.6).setStroke()
                NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }

        if let tv = textView {
            let box = NSBezierPath(rect: tv.frame.insetBy(dx: -4, dy: -3))
            box.lineWidth = 1
            box.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            box.stroke()
        }

        drawSizeLabel(sel)
        drawWidthHint()
    }

    private func drawSizeLabel(_ sel: CGRect) {
        let s = scale
        let text = "\(Int((sel.width * s).rounded())) × \(Int((sel.height * s).rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var box = CGRect(x: sel.minX, y: sel.maxY + 4, width: size.width + 12, height: size.height + 6)
        if box.maxY > bounds.maxY { box.origin.y = sel.maxY - box.height - 4; box.origin.x += 4 }
        box.origin.x = min(max(box.origin.x, bounds.minX), bounds.maxX - box.width)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    private func drawWidthHint() {
        guard let hint = widthHint else { return }
        let p = hint.point
        let d = (tool == .marker) ? Annotation.markerWidth(lineWidth) : lineWidth
        let circle = NSBezierPath(ovalIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
        color.withAlphaComponent(0.8).setFill()
        circle.fill()
        NSColor.white.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        let text = "\(Int(lineWidth)) px" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let box = CGRect(x: p.x + d / 2 + 8, y: p.y - size.height / 2 - 3, width: size.width + 10, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + 5, y: box.minY + 3), withAttributes: attrs)
    }

    // MARK: - Self-test

    /// Puts the editor into a typical state (selection, tool, open palette) for `--ui-test`.
    func debugShowEditorState() {
        let sel = alignedRect(CGRect(x: bounds.width * 0.2, y: bounds.height * 0.3, width: bounds.width * 0.45, height: bounds.height * 0.4))
        selection = sel
        annotations = [
            Annotation(kind: .arrow(CGPoint(x: sel.minX + 60, y: sel.minY + 60), CGPoint(x: sel.midX, y: sel.midY)),
                       color: color, width: lineWidth),
            Annotation(kind: .rectangle(CGRect(x: sel.midX + 20, y: sel.midY - 40, width: 200, height: 120)), color: color, width: lineWidth),
        ]
        tool = .arrow
        showToolbars(true)
        togglePalette()
        needsDisplay = true
    }

    /// Renders a fixed scene to PNG; used by `--render-test` to check drawing without UI.
    func renderTestScene(to url: URL) throws {
        let sel = CGRect(x: 100, y: 100, width: 600, height: 400)
        selection = sel
        let red = Palette.colors[0], blue = Palette.colors[4], yellow = Palette.colors[2]
        annotations = [
            Annotation(kind: .rectangle(CGRect(x: 130, y: 380, width: 160, height: 90)), color: red, width: 4),
            Annotation(kind: .ellipse(CGRect(x: 330, y: 370, width: 140, height: 110)), color: blue, width: 4),
            Annotation(kind: .arrow(CGPoint(x: 150, y: 150), CGPoint(x: 380, y: 300)), color: red, width: 4),
            Annotation(kind: .arrow(CGPoint(x: 680, y: 140), CGPoint(x: 540, y: 330)), color: blue, width: 8),
            Annotation(kind: .line(CGPoint(x: 500, y: 460), CGPoint(x: 680, y: 400)), color: red, width: 2),
            Annotation(kind: .pen((0..<40).map { i in CGPoint(x: 420 + CGFloat(i) * 6, y: 200 + sin(CGFloat(i) / 4) * 30) }),
                       color: red, width: 4),
            Annotation(kind: .marker([CGPoint(x: 140, y: 340), CGPoint(x: 330, y: 340)]), color: yellow, width: 4),
            Annotation(kind: .text("Привет, ShotMark!\nВторая строка", CGRect(x: 140, y: 230, width: 210, height: 52),
                                   Annotation.fontSize(4)), color: red, width: 4),
        ]
        guard let rep = render(sel), let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.noDisplays
        }
        try data.write(to: url)
    }
}

private extension NSColor {
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}
