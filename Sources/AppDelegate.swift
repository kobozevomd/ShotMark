import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKey(id: 1)
    private var capturing = false
    private var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-test"), i + 1 < args.count {
            runRenderTest(path: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--ui-test"), i + 1 < args.count {
            runUITest(path: args[i + 1])
            return
        }

        installMainMenu()
        setupStatusItem()

        let status = hotKey.register(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.takeScreenshot()
        }
        if status != noErr {
            alert("Не удалось занять сочетание ⇧⌘9",
                  "Возможно, оно уже используется другим приложением (например, Lightshot). Закройте его и перезапустите ShotMark.")
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { ScreenCapturer.invalidate() }
        }

        if args.contains("--demo") {
            DispatchQueue.main.async {
                CaptureSession.start(shots: ScreenCapturer.demoShots(), previousApp: NSWorkspace.shared.frontmostApplication)
            }
        } else if CGPreflightScreenCaptureAccess() {
            ScreenCapturer.warmUp()
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShotMark")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        let shot = NSMenuItem(title: "Сделать скриншот", action: #selector(menuScreenshot), keyEquivalent: "9")
        shot.keyEquivalentModifierMask = [.command, .shift]
        shot.target = self
        menu.addItem(shot)
        menu.addItem(.separator())

        loginItem = NSMenuItem(title: "Запускать при входе в систему", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let perms = NSMenuItem(title: "Доступ к записи экрана…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)

        menu.addItem(.separator())
        let help = NSMenuItem(title: "Подсказка по клавишам", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(NSMenuItem(title: "Выйти из ShotMark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Hidden Edit menu, so ⌘V / ⌘A / ⌘Z work while typing text on a screenshot.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func menuScreenshot() {
        // Let the menu close before freezing the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.takeScreenshot()
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Не получилось изменить автозапуск", error.localizedDescription)
        }
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showHelp() {
        alert("ShotMark — клавиши", """
        ⇧⌘9 — сделать скриншот
        ⌘C или Enter — скопировать в буфер обмена
        ⌘S — сохранить в файл
        ⇧⌘C — загрузить PNG на Catbox и скопировать ссылку
        ⇧⌘T — распознать текст локально и скопировать
        ⌘Z — отменить последнее действие
        Esc — закрыть

        Инструменты: A — стрелка, R — прямоугольник, E — круг, \
        L — линия, P — карандаш, M — маркер, T — текст.
        С Shift — ровный круг / квадрат и линии под 45°.
        Колесо мыши — толщина линии.
        Стрелки на клавиатуре — сдвинуть область (с Shift — на 10 пунктов).
        """)
    }

    // MARK: - Capture

    private func takeScreenshot() {
        guard CaptureSession.current == nil, !capturing else { return }
        capturing = true
        let previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            defer { self.capturing = false }
            do {
                let shots = try await ScreenCapturer.captureAll()
                CaptureSession.start(shots: shots, previousApp: previousApp)
            } catch {
                self.showPermissionHelp(error)
            }
        }
    }

    private func showPermissionHelp(_ error: Error) {
        let a = NSAlert()
        a.messageText = "Нет доступа к записи экрана"
        a.informativeText = """
        Откройте «Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука» \
        и включите ShotMark. Если macOS попросит — перезапустите приложение.

        (\(error.localizedDescription))
        """
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Отмена")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    // MARK: - Self-test

    /// Snapshots the overlay UI offscreen (window is never shown).
    private func runUITest(path: String) {
        let shot = ScreenCapturer.demoShots().first!
        let size = shot.screen.frame.size
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        let background = NSView(frame: container.bounds)
        background.wantsLayer = true
        background.layer?.contents = shot.image
        background.layer?.contentsGravity = .resize
        let canvas = CanvasView(frame: container.bounds, image: shot.image)
        container.addSubview(background)
        container.addSubview(canvas)
        window.contentView = container
        canvas.debugShowEditorState()
        let scale = shot.screen.backingScaleFactor
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(shot.image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("ok \(path)")
        exit(0)
    }

    private func runRenderTest(path: String) {
        let shot = ScreenCapturer.demoShots().first!
        let canvas = CanvasView(frame: NSRect(origin: .zero, size: shot.screen.frame.size), image: shot.image)
        do {
            try canvas.renderTestScene(to: URL(fileURLWithPath: path))
            print("ok \(path)")
            exit(0)
        } catch {
            print("failed: \(error)")
            exit(1)
        }
    }
}
