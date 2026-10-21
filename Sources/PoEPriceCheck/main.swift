import AppKit
import PoECore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: PriceCheckController!
    private var hotKey: HotKey?
    private var keyTap: KeyTap?
    private var keyTapRetry: Timer?
    private var lastFire = Date.distantPast
    private var leagues: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            controller = try PriceCheckController()
        } catch {
            let alert = NSAlert()
            alert.messageText = "PoEPriceCheck couldn't load its game data"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-panel"), args.count > i + 2 {
            let cursor = args.count > i + 4 ? Double(args[i + 3]).flatMap { x in Double(args[i + 4]).map { CGPoint(x: x, y: $0) } } : nil
            Task {
                await controller.renderPanel(input: args[i + 1], output: args[i + 2], cursor: cursor)
                NSApp.terminate(nil)
            }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dollarsign.circle", accessibilityDescription: "PoE Price Check")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerHotKey()
        installKeyTap()
        Log.info("launch: permission=\(ScreenCapturer.hasPermission) inputMonitoring=\(KeyTap.hasPermission) keyTap=\(keyTap != nil) hotkey=\(Settings.hotKey.title) registered=\(hotKey != nil) screens=\(NSScreen.screens.map { "\($0.frame) x\($0.backingScaleFactor)" })")
        if !ScreenCapturer.hasPermission { ScreenCapturer.requestPermission() }
        // Dev hook: trigger a check without touching the keyboard.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(remoteCheck),
                                                            name: Notification.Name("PoEPriceCheck.check"),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        controller.warmUp()
        if CommandLine.arguments.contains("--selftest") { controller.selfTest() }
        Task { leagues = (try? await controller.trade.leagues()) ?? [] }
    }

    @objc private func remoteCheck() { fire("notification") }

    /// Carbon hotkey and the HID key tap can both see one press; only act once.
    private func fire(_ source: String) {
        guard Date().timeIntervalSince(lastFire) > 0.4 else { return }
        lastFire = Date()
        Log.info("hotkey pressed (\(source))")
        controller.trigger()
    }

    /// Key tap for when another app grabs the keyboard (GeForce NOW in Chrome fullscreen).
    private func installKeyTap() {
        if !KeyTap.hasPermission { KeyTap.requestPermission() }
        keyTap = KeyTap { [weak self] code, flags in
            MainActor.assumeIsolated {
                guard let self else { return }
                if KeyTap.matches(Settings.hotKey, keyCode: code, flags: flags) {
                    self.fire("key tap")
                } else if KeyTap.matches(HotKey.escape, keyCode: code, flags: flags), self.controller.panel.isVisible {
                    self.controller.panel.dismiss()
                }
            }
        }
        // Permission may be granted later: keep trying quietly.
        if keyTap == nil, keyTapRetry == nil {
            keyTapRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.keyTap == nil else { return }
                    if KeyTap.hasPermission {
                        self.installKeyTap()
                        Log.info("key tap installed after permission grant: \(self.keyTap != nil)")
                        if self.keyTap != nil { self.keyTapRetry?.invalidate(); self.keyTapRetry = nil }
                    }
                }
            }
        }
    }

    private func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(Settings.hotKey) { [weak self] in self?.fire("carbon") }
        if hotKey == nil {
            let alert = NSAlert()
            alert.messageText = "Hotkey \(Settings.hotKey.title) is taken by another app"
            alert.informativeText = "Pick a different one from the menu bar icon › Hotkey."
            alert.runModal()
        }
    }

    // Rebuild the menu each time it opens so checkmarks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let check = NSMenuItem(title: "Price check (\(Settings.hotKey.title))", action: #selector(priceCheck), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        if !ScreenCapturer.hasPermission {
            let p = NSMenuItem(title: "⚠︎ Allow Screen Recording…", action: #selector(openPermission), keyEquivalent: "")
            p.target = self
            menu.addItem(p)
        }
        if keyTap == nil {
            let p = NSMenuItem(title: "⚠︎ Allow Input Monitoring (hotkey in Chrome fullscreen)…", action: #selector(openInputMonitoring), keyEquivalent: "")
            p.target = self
            menu.addItem(p)
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Hotkey", HotKey.presets.map { combo in
            (combo.title, combo == Settings.hotKey, { [weak self] in Settings.hotKey = combo; self?.registerHotKey() })
        }))

        let detected = UserDefaults.standard.string(forKey: "detectedLeague")
        var leagueItems: [(String, Bool, () -> Void)] = [("Auto (\(detected.map { "seen in game: \($0)" } ?? "poe.ninja current"))",
                                                           Settings.league == nil, { Settings.league = nil })]
        for l in leagues { leagueItems.append((l, Settings.league == l, { Settings.league = l })) }
        menu.addItem(submenu("League", leagueItems))

        menu.addItem(submenu("Default min-value margin", [0.05, 0.10, 0.15, 0.20, 0.30].map { m in
            ("\(Int(m * 100))% below roll", abs(Settings.margin - m) < 0.001, { Settings.margin = m })
        }))
        menu.addItem(submenu("Listings", [("Instant buyout + in person (online)", "available"), ("Instant buyout only", "securable"),
                                          ("Online in league", "onlineleague"), ("Any", "any")].map { title, v in
            (title, Settings.status == v, { Settings.status = v })
        }))
        let zoom = UserDefaults.standard.object(forKey: "zoom") as? Double
        menu.addItem(submenu("Panel size", [("Auto", nil), ("100%", 1.0), ("125%", 1.25), ("160%", 1.6), ("200%", 2.0)].map { title, v in
            (title, zoom == v, { UserDefaults.standard.set(v, forKey: "zoom") })
        }))

        menu.addItem(.separator())
        let save = NSMenuItem(title: "Save captures (for debugging)", action: #selector(toggleSave), keyEquivalent: "")
        save.state = Settings.saveCaptures ? .on : .off
        save.target = self
        menu.addItem(save)
        let open = NSMenuItem(title: "Open captures folder", action: #selector(openCaptures), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PoEPriceCheck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }


    private func submenu(_ title: String, _ items: [(String, Bool, () -> Void)]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (t, on, action) in items {
            let mi = ClosureMenuItem(title: t, action: action)
            mi.state = on ? .on : .off
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func priceCheck() {
        // Give the menu time to close so it isn't in the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.controller.trigger() }
    }

    @objc private func openPermission() {
        ScreenCapturer.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openInputMonitoring() {
        KeyTap.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func toggleSave() { Settings.saveCaptures.toggle() }
    @objc private func openCaptures() { NSWorkspace.shared.open(Settings.capturesDirectory) }
}

final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void
    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { closure() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
