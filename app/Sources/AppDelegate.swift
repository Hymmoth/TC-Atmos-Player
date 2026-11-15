import Cocoa
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var player: MPVPlayer!
    private var osc: OSCClient!
    private var playerWindow: PlayerWindowController!
    private var room3D: Room3DWindowController?
    private var prefsWindow: NSWindow?
    private var keyMonitor: Any?
    private var pendingURLs: [URL] = []
    private var launched = false
    private let settings = AppSettings.shared

    private let audioMenu = NSMenu(title: "Audio")
    private let subtitleMenu = NSMenu(title: "Sottotitoli")
    private let recentMenu = NSMenu(title: "Apri recenti")

    // MARK: Avvio

    func applicationDidFinishLaunching(_ notification: Notification) {
        EngineConfig.write(layout: settings.layout)

        player = MPVPlayer()
        configurePlayer()
        player.initialize()

        osc = OSCClient(enginePort: UInt16(EngineConfig.oscPort))
        osc.start()

        // Prova automatica (CI): verifica librerie e motore, senza aprire finestre.
        if ProcessInfo.processInfo.environment["TC_SMOKE_TEST"] == "1" {
            runSmokeTest()
            return
        }

        playerWindow = PlayerWindowController(player: player, osc: osc)
        playerWindow.onOpenRequest = { [weak self] in self?.openDocument(nil) }
        playerWindow.onShow3D = { [weak self] in self?.show3D(nil) }
        playerWindow.showWindow(nil)

        buildMenus()
        installKeyMonitor()

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: AppSettings.changed, object: nil)
        launched = true
        if let first = pendingURLs.first {
            playerWindow.open(first)
        }
        pendingURLs.removeAll()
    }

    private func runSmokeTest() {
        let version = player.getString("mpv-version") ?? "?"
        let ffmpeg = player.getString("ffmpeg-version") ?? "?"
        let ad = player.getString("options/ad") ?? ""
        let lib = player.getString("options/ad-orender-library") ?? ""
        let bridges = player.getString("options/ad-orender-bridge-path") ?? ""
        print("SMOKE mpv=\(version) ffmpeg=\(ffmpeg)")
        print("SMOKE ad=\(ad)")
        print("SMOKE liborender=\(lib)")
        print("SMOKE bridge=\(bridges)")
        let engineOK = ad.contains("orender") && FileManager.default.fileExists(atPath: lib) && !bridges.isEmpty
        if let handle = dlopen(lib, RTLD_NOW) {
            print("SMOKE dlopen liborender: ok")
            dlclose(handle)
        } else {
            print("SMOKE dlopen liborender: ERRORE \(String(cString: dlerror()))")
        }
        for path in bridges.split(separator: ":") {
            if let handle = dlopen(String(path), RTLD_NOW) {
                print("SMOKE dlopen \((path as NSString).lastPathComponent): ok")
                dlclose(handle)
            } else {
                print("SMOKE dlopen \(path): ERRORE \(String(cString: dlerror()))")
            }
        }
        var buf = [tc_audio_stream_info](repeating: tc_audio_stream_info(), count: 4)
        print("SMOKE probe(file inesistente)=\(tc_probe_audio_streams("/nonexistent.mkv", &buf, 4))")

        // Riproduzione di prova di un file Atmos (DD+ JOC), se indicato.
        var playbackOK = true
        if let file = ProcessInfo.processInfo.environment["TC_SMOKE_FILE"] {
            let n = tc_probe_audio_streams(file, &buf, 4)
            print("SMOKE probe: \(n) tracce, atmos=\(n > 0 ? Int(buf[0].is_atmos) : -1), canali=\(n > 0 ? Int(buf[0].channels) : -1)")
            player.command(["loadfile", file, "replace"])
            let expected = settings.layout.speakers.count
            var channels = 0, profile = "", objects = 0
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                channels = Int(player.getDouble("audio-params/channel-count") ?? 0)
                profile = player.getString("current-tracks/audio/codec-profile") ?? ""
                objects = osc.snapshot.values.filter { !$0.fixed }.count
                if channels == expected && objects > 0 { break }
            }
            print("SMOKE audio: decoder=\(player.getString("current-tracks/audio/decoder-desc") ?? "?")")
            print("SMOKE audio: profilo=\(profile) canali=\(channels) (attesi \(expected))")
            print("SMOKE audio: layout=\(player.getString("audio-params/channels") ?? "?")")
            print("SMOKE osc: oggetti=\(objects) collegato=\(osc.isConnected)")
            Thread.sleep(forTimeInterval: 1.5)
            for (id, o) in osc.snapshot.sorted(by: { $0.key < $1.key }) {
                print(String(format: "SMOKE osc: #%d %@ %@ x=%.2f y=%.2f z=%.2f rms=%.1f", id,
                             o.fixed ? "letto" : "oggetto", o.label, o.x, o.y, o.z, o.rmsDB))
            }
            playbackOK = channels == expected
        }
        fflush(stdout)
        player.destroy()
        exit(engineOK && playbackOK ? 0 : 1)
    }

    private func configurePlayer() {
        let p = player!
        p.setOption("config", "no")
        p.setOption("vo", "libmpv")
        p.setOption("hwdec", "auto-safe")
        p.setOption("idle", "yes")
        p.setOption("keep-open", "yes")
        p.setOption("input-default-bindings", "no")
        p.setOption("input-vo-keyboard", "no")
        p.setOption("load-scripts", "no")
        p.setOption("osd-font-size", "40")
        p.setOption("volume-max", "100")
        p.setOption("ao", "coreaudio")
        p.setOption("audio-device", settings.audioDevice)
        p.setOption("alang", AppSettings.mpvLanguageList(settings.audioLanguages))
        p.setOption("slang", AppSettings.mpvLanguageList(settings.subtitleLanguages))
        p.setOption("sid", settings.subtitlesOff ? "no" : "auto")
        p.setOption("screenshot-directory", "~/Desktop")
        if ProcessInfo.processInfo.environment["TC_SMOKE_TEST"] == "1" {
            p.setOption("vo", "null")
            p.setOption("ao", "null")
            p.setOption("loop-file", "inf")
        }

        // Motore di rendering Atmos (Omniphony) e decoder (harletty), dentro l'app.
        guard let engineDir = Bundle.main.resourceURL?.appendingPathComponent("engine") else { return }
        let lib = engineDir.appendingPathComponent("liborender.dylib")
        let bridges = ["libharletty_dolby_bridge.dylib", "libharletty_dts_bridge.dylib", "libharletty_iamf_bridge.dylib"]
            .map { engineDir.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        if FileManager.default.fileExists(atPath: lib.path), !bridges.isEmpty {
            p.setOption("ad", "orender")
            p.setOption("ad-orender-library", lib.path)
            p.setOption("ad-orender-bridge-path", bridges.joined(separator: ":"))
            p.setOption("ad-orender-config", EngineConfig.configURL.path)
            p.setOption("ad-orender-osc", "yes")
            p.setOption("ad-orender-osc-rx-port", String(EngineConfig.oscPort))
        } else {
            NSLog("Motore Atmos non trovato in \(engineDir.path): riproduzione senza rendering a oggetti")
        }
    }

    @objc private func settingsChanged(_ note: Notification) {
        guard let key = note.object as? String else { return }
        switch key {
        case "audioDevice":
            player.setString("audio-device", settings.audioDevice)
        case "audioLanguages":
            player.setString("alang", AppSettings.mpvLanguageList(settings.audioLanguages))
        case "subtitleLanguages":
            player.setString("slang", AppSettings.mpvLanguageList(settings.subtitleLanguages))
        case "layoutId":
            EngineConfig.write(layout: settings.layout)
            room3D?.showLayout(settings.layout)
        case "shortcuts":
            updateMenuShortcuts()
        default:
            break
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        if launched {
            playerWindow.open(first)
        } else {
            pendingURLs = [first]
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { playerWindow.showWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        osc?.stop()
        playerWindow?.videoView.videoLayer.uninit()
        player?.destroy()
    }

    // MARK: Azioni

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent, .audio] +
            ["mkv", "m2ts", "mts", "ts", "webm", "avi", "mka", "thd", "eac3", "ec3"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            playerWindow.open(url)
        }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        playerWindow.open(url)
    }

    @objc func clearRecent(_ sender: Any?) { RecentFiles.clear() }

    @objc func showPreferences(_ sender: Any?) {
        if prefsWindow == nil {
            let view = PreferencesView(devices: { [weak self] in self?.audioDevices() ?? [] })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Preferenze"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            prefsWindow = w
        }
        prefsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func audioDevices() -> [AudioDevice] {
        guard let list = player.getJSON("audio-device-list") as? [[String: Any]] else {
            return [AudioDevice(name: "auto", description: "Predefinito di sistema")]
        }
        var out = list.compactMap { d -> AudioDevice? in
            guard let name = d["name"] as? String else { return nil }
            var desc = d["description"] as? String ?? name
            if name == "auto" { desc = "Predefinito di sistema" }
            return AudioDevice(name: name, description: desc)
        }
        // Il dispositivo salvato resta selezionabile anche se ora non è collegato.
        if !out.contains(where: { $0.name == settings.audioDevice }) {
            out.append(AudioDevice(name: settings.audioDevice, description: "\(settings.audioDevice) (non collegato)"))
        }
        return out
    }

    @objc func show3D(_ sender: Any?) {
        if room3D == nil { room3D = Room3DWindowController(osc: osc) }
        room3D?.showLayout(settings.layout)
        room3D?.showWindow(nil)
    }

    @objc func togglePause(_ sender: Any?) { playerWindow.togglePause() }
    @objc func seekForward(_ sender: Any?) { playerWindow.seek(by: 10) }
    @objc func seekBackward(_ sender: Any?) { playerWindow.seek(by: -10) }
    @objc func seekForwardLong(_ sender: Any?) { playerWindow.seek(by: 60) }
    @objc func seekBackwardLong(_ sender: Any?) { playerWindow.seek(by: -60) }
    @objc func volumeUp(_ sender: Any?) { playerWindow.changeVolume(by: 5) }
    @objc func volumeDown(_ sender: Any?) { playerWindow.changeVolume(by: -5) }
    @objc func toggleMute(_ sender: Any?) { playerWindow.toggleMute() }
    @objc func toggleFullScreenPlayer(_ sender: Any?) { playerWindow.window?.toggleFullScreen(nil) }
    @objc func nextAudio(_ sender: Any?) { playerWindow.nextAudioTrack() }
    @objc func nextSubtitle(_ sender: Any?) { playerWindow.nextSubtitleTrack() }

    private func perform(_ action: PlayerAction) {
        switch action {
        case .playPause: togglePause(nil)
        case .seekForward: seekForward(nil)
        case .seekBackward: seekBackward(nil)
        case .seekForwardLong: seekForwardLong(nil)
        case .seekBackwardLong: seekBackwardLong(nil)
        case .volumeUp: volumeUp(nil)
        case .volumeDown: volumeDown(nil)
        case .mute: toggleMute(nil)
        case .fullscreen: toggleFullScreenPlayer(nil)
        case .nextAudio: nextAudio(nil)
        case .nextSubtitle: nextSubtitle(nil)
        case .view3D: show3D(nil)
        case .open: openDocument(nil)
        }
    }

    // MARK: Tastiera

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, !ShortcutRecorder.isRecording else { return event }
            let w = event.window
            let isPlayerWindow = w === self.playerWindow.window || (self.room3D != nil && w === self.room3D?.window)
            guard isPlayerWindow else { return event }
            // Esc esce dallo schermo intero.
            if event.keyCode == 53, let pw = self.playerWindow.window, pw.styleMask.contains(.fullScreen) {
                pw.toggleFullScreen(nil)
                return nil
            }
            guard let s = Shortcut(event: event) else { return event }
            if let action = PlayerAction.allCases.first(where: {
                let sc = self.settings.shortcut(for: $0)
                return !sc.key.isEmpty && sc == s
            }) {
                self.perform(action)
                return nil
            }
            return event
        }
    }

    // MARK: Menu

    private var actionItems: [PlayerAction: NSMenuItem] = [:]

    private func item(_ title: String, _ action: Selector, _ playerAction: PlayerAction? = nil,
                      key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        if let a = playerAction { actionItems[a] = i }
        return i
    }

    private func buildMenus() {
        let main = NSMenu()

        // App
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Informazioni su TC Cinema Player",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Preferenze…", #selector(showPreferences(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Nascondi TC Cinema Player", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Nascondi altre",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Mostra tutte", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Esci da TC Cinema Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Apri…", #selector(openDocument(_:)), .open))
        let recentItem = NSMenuItem(title: "Apri recenti", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Chiudi finestra", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Riproduzione
        let playItem = NSMenuItem()
        let playMenu = NSMenu(title: "Riproduzione")
        playMenu.addItem(item("Play / Pausa", #selector(togglePause(_:)), .playPause))
        playMenu.addItem(.separator())
        playMenu.addItem(item("Avanti 10 secondi", #selector(seekForward(_:)), .seekForward))
        playMenu.addItem(item("Indietro 10 secondi", #selector(seekBackward(_:)), .seekBackward))
        playMenu.addItem(item("Avanti 1 minuto", #selector(seekForwardLong(_:)), .seekForwardLong))
        playMenu.addItem(item("Indietro 1 minuto", #selector(seekBackwardLong(_:)), .seekBackwardLong))
        playMenu.addItem(.separator())
        playMenu.addItem(item("Volume su", #selector(volumeUp(_:)), .volumeUp))
        playMenu.addItem(item("Volume giù", #selector(volumeDown(_:)), .volumeDown))
        playMenu.addItem(item("Muto", #selector(toggleMute(_:)), .mute))
        playItem.submenu = playMenu
        main.addItem(playItem)

        // Audio
        let audioItem = NSMenuItem()
        audioMenu.delegate = self
        audioItem.submenu = audioMenu
        main.addItem(audioItem)

        // Sottotitoli
        let subItem = NSMenuItem()
        subtitleMenu.delegate = self
        subItem.submenu = subtitleMenu
        main.addItem(subItem)

        // Vista
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Vista")
        viewMenu.addItem(item("Schermo intero", #selector(toggleFullScreenPlayer(_:)), .fullscreen))
        viewMenu.addItem(item("Vista 3D", #selector(show3D(_:)), .view3D))
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Finestra
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Finestra")
        windowMenu.addItem(withTitle: "Contrai", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Ridimensiona", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
        updateMenuShortcuts()
    }

    /// Mostra nei menu le scorciatoie con ⌘ (le altre le gestisce il monitor
    /// della tastiera, per non rubare i tasti ai campi di testo).
    private func updateMenuShortcuts() {
        for (action, menuItem) in actionItems {
            let s = settings.shortcut(for: action)
            if !s.key.isEmpty, s.modifiers.contains(.command) {
                menuItem.keyEquivalent = s.key
                menuItem.keyEquivalentModifierMask = s.modifiers
            } else {
                menuItem.keyEquivalent = ""
                menuItem.keyEquivalentModifierMask = []
            }
            let base = action.title
            menuItem.title = (!s.key.isEmpty && !s.modifiers.contains(.command)) ? "\(base)    [\(s.displayString)]" : base
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === audioMenu {
            playerWindow.fillAudioMenu(menu, keepFirst: false)
            menu.addItem(.separator())
            menu.addItem(item("Traccia audio successiva", #selector(nextAudio(_:))))
        } else if menu === subtitleMenu {
            playerWindow.fillSubtitleMenu(menu, keepFirst: false)
            menu.addItem(.separator())
            menu.addItem(item("Sottotitoli successivi", #selector(nextSubtitle(_:))))
        } else if menu === recentMenu {
            menu.removeAllItems()
            let urls = RecentFiles.urls
            for url in urls {
                let i = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                i.representedObject = url
                i.target = self
                i.toolTip = url.path
                menu.addItem(i)
            }
            if urls.isEmpty {
                let none = NSMenuItem(title: "Nessun file recente", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            } else {
                menu.addItem(.separator())
                menu.addItem(item("Cancella elenco", #selector(clearRecent(_:))))
            }
        }
    }
}
