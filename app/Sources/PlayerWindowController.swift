import Cocoa

/// Finestra principale: video, barra dei controlli, gestione delle tracce.
final class PlayerWindowController: NSWindowController, NSWindowDelegate, MPVPlayerDelegate, NSMenuDelegate {
    let player: MPVPlayer
    let osc: OSCClient
    private(set) var videoView: VideoView!
    private let settings = AppSettings.shared

    // Barra dei controlli
    private let controls = NSVisualEffectView()
    private let playButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let seekSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let audioButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let subButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let atmosBadge = NSTextField(labelWithString: "ATMOS")
    private let placeholder = NSTextField(labelWithString: "Trascina qui un video oppure premi ⌘O")
    private var hideTimer: Timer?
    private var isSeeking = false

    // Analisi delle tracce Atmos
    private var currentPath: String?
    private var probeResults: [tc_audio_stream_info]?
    private var autoSelectDone = false
    private var userPickedAudio = false
    private var fileLoaded = false
    private var sizedForCurrentFile = false

    var onOpenRequest: (() -> Void)?
    var onShow3D: (() -> Void)?

    init(player: MPVPlayer, osc: OSCClient) {
        self.player = player
        self.osc = osc
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "TC Atmos Player"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 480, height: 270)
        window.setFrameAutosaveName("TCPlayerWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        player.delegate = self
        buildUI()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("non supportato") }

    // MARK: Interfaccia

    private func buildUI() {
        guard let content = window?.contentView else { return }
        videoView = VideoView(player: player)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.onDropFiles = { [weak self] urls in self?.open(urls[0]) }
        videoView.onMouseMoved = { [weak self] in self?.showControls() }
        videoView.onDoubleClick = { [weak self] in self?.window?.toggleFullScreen(nil) }
        content.addSubview(videoView)

        placeholder.textColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(placeholder)

        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controls)

        playButton.bezelStyle = .regularSquare
        playButton.isBordered = false
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.imageScaling = .scaleProportionallyUpOrDown
        playButton.target = self
        playButton.action = #selector(togglePause)
        playButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        for l in [timeLabel, durationLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            l.textColor = .white
            l.alignment = .center
            l.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        }

        seekSlider.target = self
        seekSlider.action = #selector(seekSliderMoved(_:))
        seekSlider.isContinuous = true
        seekSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderMoved(_:))
        volumeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let volumeIcon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2.fill",
                                                    accessibilityDescription: "Volume")!)
        volumeIcon.contentTintColor = .white

        configurePopup(audioButton, symbol: "waveform", tooltip: "Tracce audio")
        configurePopup(subButton, symbol: "captions.bubble", tooltip: "Sottotitoli")

        atmosBadge.font = .systemFont(ofSize: 10, weight: .bold)
        atmosBadge.textColor = .black
        atmosBadge.backgroundColor = .systemYellow
        atmosBadge.drawsBackground = true
        atmosBadge.isBezeled = false
        atmosBadge.alignment = .center
        atmosBadge.isHidden = true
        atmosBadge.toolTip = "La traccia in riproduzione contiene oggetti Atmos"

        let view3D = iconButton("cube.transparent", tooltip: "Vista 3D", action: #selector(show3D))
        let full = iconButton("arrow.up.left.and.arrow.down.right", tooltip: "Schermo intero",
                              action: #selector(toggleFullScreenAction))

        let stack = NSStackView(views: [playButton, timeLabel, seekSlider, durationLabel, atmosBadge,
                                        audioButton, subButton, volumeIcon, volumeSlider, view3D, full])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)

        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: content.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            controls.heightAnchor.constraint(equalToConstant: 44),

            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controls.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            atmosBadge.widthAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func configurePopup(_ b: NSPopUpButton, symbol: String, tooltip: String) {
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.toolTip = tooltip
        (b.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let menu = NSMenu()
        menu.delegate = self
        let titleItem = NSMenuItem()
        titleItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        menu.addItem(titleItem)
        b.menu = menu
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func iconButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!,
                         target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tooltip
        return b
    }

    // MARK: Comparsa dei controlli

    func showControls() {
        if controls.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                controls.animator().alphaValue = 1
            }
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.hideControlsIfIdle()
        }
    }

    private func hideControlsIfIdle() {
        guard fileLoaded, !player.isPaused, let window = window else { return }
        let mouse = window.mouseLocationOutsideOfEventStream
        if controls.frame.contains(mouse) {
            showControls()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            controls.animator().alphaValue = 0
        }
        if window.styleMask.contains(.fullScreen) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: Apertura file

    func open(_ url: URL) {
        currentPath = url.path
        probeResults = nil
        autoSelectDone = false
        userPickedAudio = false
        fileLoaded = false
        sizedForCurrentFile = false
        osc.clear()
        window?.title = url.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentFiles.add(url)

        // Selezione automatica a ogni file (non ereditata dal file precedente).
        player.setString("aid", "auto")
        player.setString("sid", settings.subtitlesOff ? "no" : "auto")
        player.loadFile(url)
        player.setFlag("pause", false)
        placeholder.isHidden = true

        let path = url.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buf = [tc_audio_stream_info](repeating: tc_audio_stream_info(), count: 64)
            let n = tc_probe_audio_streams(path, &buf, Int32(buf.count))
            let results = n > 0 ? Array(buf[0..<Int(n)]) : []
            DispatchQueue.main.async {
                guard let self = self, self.currentPath == path else { return }
                self.probeResults = results
                self.refreshTrackUI()
                self.applyAtmosPreference()
            }
        }
        showWindow(nil)
    }

    // MARK: Tracce

    /// Le tracce di mpv, con il flag Atmos ricavato dall'analisi del file.
    func annotatedTracks() -> [Track] {
        var tracks = player.tracks
        guard let probe = probeResults, !probe.isEmpty else { return tracks }
        let format = player.getString("file-format") ?? ""
        let isMatroska = format.contains("mkv") || format.contains("matroska") || format.contains("webm")
        for i in tracks.indices where tracks[i].type == "audio" && !tracks[i].external {
            let t = tracks[i]
            let match = probe.first { info in
                if isMatroska, let src = t.srcId { return Int64(src) == info.id }
                if let ff = t.ffIndex { return Int32(ff) == info.index }
                return false
            }
            if let m = match, m.is_atmos != 0 { tracks[i].isAtmos = true }
            if let title = t.title, title.localizedCaseInsensitiveContains("atmos") { tracks[i].isAtmos = true }
        }
        return tracks
    }

    /// Se richiesto, sceglie la traccia Atmos nella lingua preferita.
    private func applyAtmosPreference() {
        guard settings.preferAtmos, fileLoaded, probeResults != nil, !autoSelectDone, !userPickedAudio else { return }
        autoSelectDone = true
        let audio = annotatedTracks().filter { $0.type == "audio" }
        guard audio.contains(where: { $0.isAtmos }) else { return }
        let current = audio.first { $0.selected }

        var candidates: [Track] = []
        for codes in AppSettings.languageCodes(settings.audioLanguages) {
            let inLang = audio.filter { codes.contains(($0.lang ?? "").lowercased()) }
            if !inLang.isEmpty { candidates = inLang; break }
        }
        if candidates.isEmpty, let cur = current {
            candidates = audio.filter { ($0.lang ?? "") == (cur.lang ?? "") }
        }
        if let best = candidates.first(where: { $0.isAtmos }), best.id != current?.id {
            player.setString("aid", String(best.id))
            player.command(["show-text", "Traccia audio: \(best.menuTitle)", "2500"])
        }
    }

    private func refreshTrackUI() {
        let tracks = annotatedTracks()
        let current = tracks.first { $0.type == "audio" && $0.selected }
        let live = player.getString("current-tracks/audio/codec-profile") ?? ""
        atmosBadge.isHidden = !((current?.isAtmos ?? false) || live.localizedCaseInsensitiveContains("atmos"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === audioButton.menu {
            fillAudioMenu(menu, keepFirst: true)
        } else if menu === subButton.menu {
            fillSubtitleMenu(menu, keepFirst: true)
        }
    }

    /// Riempie un menu con le tracce audio (usato sia dalla barra sia dal menu "Audio").
    func fillAudioMenu(_ menu: NSMenu, keepFirst: Bool) {
        let first = keepFirst ? menu.items.first : nil
        menu.removeAllItems()
        if let f = first { menu.addItem(f) }
        let audio = annotatedTracks().filter { $0.type == "audio" }
        if audio.isEmpty {
            let none = NSMenuItem(title: "Nessuna traccia audio", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for t in audio {
            let item = NSMenuItem(title: t.menuTitle, action: #selector(selectAudioTrack(_:)), keyEquivalent: "")
            item.target = self
            item.tag = t.id
            item.state = t.selected ? .on : .off
            if t.isAtmos {
                let s = NSMutableAttributedString(string: t.menuTitle)
                if let r = t.menuTitle.range(of: "ATMOS") {
                    s.addAttributes([.foregroundColor: NSColor.systemOrange,
                                     .font: NSFont.menuFont(ofSize: 0).withWeight(.bold)],
                                    range: NSRange(r, in: t.menuTitle))
                }
                item.attributedTitle = s
            }
            menu.addItem(item)
        }
    }

    func fillSubtitleMenu(_ menu: NSMenu, keepFirst: Bool) {
        let first = keepFirst ? menu.items.first : nil
        menu.removeAllItems()
        if let f = first { menu.addItem(f) }
        let subs = player.tracks.filter { $0.type == "sub" }
        let off = NSMenuItem(title: "Nessuno", action: #selector(selectSubtitleTrack(_:)), keyEquivalent: "")
        off.target = self
        off.tag = -1
        off.state = subs.contains(where: { $0.selected }) ? .off : .on
        menu.addItem(off)
        for t in subs {
            let item = NSMenuItem(title: t.menuTitle, action: #selector(selectSubtitleTrack(_:)), keyEquivalent: "")
            item.target = self
            item.tag = t.id
            item.state = t.selected ? .on : .off
            menu.addItem(item)
        }
    }

    @objc func selectAudioTrack(_ sender: NSMenuItem) {
        userPickedAudio = true
        player.setString("aid", String(sender.tag))
    }

    @objc func selectSubtitleTrack(_ sender: NSMenuItem) {
        player.setString("sid", sender.tag < 0 ? "no" : String(sender.tag))
    }

    @objc func nextAudioTrack() {
        userPickedAudio = true
        player.command(["cycle", "audio"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.announceAudioTrack() }
    }

    @objc func nextSubtitleTrack() {
        player.command(["cycle", "sub"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            let t = self.player.tracks.first { $0.type == "sub" && $0.selected }
            self.player.command(["show-text", "Sottotitoli: \(t?.menuTitle ?? "nessuno")", "2000"])
        }
    }

    private func announceAudioTrack() {
        let t = annotatedTracks().first { $0.type == "audio" && $0.selected }
        player.command(["show-text", "Audio: \(t?.menuTitle ?? "nessuno")", "2000"])
    }

    // MARK: Azioni

    @objc func togglePause() {
        guard fileLoaded else { onOpenRequest?(); return }
        player.togglePause()
        showControls()
    }

    @objc private func seekSliderMoved(_ sender: NSSlider) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseDown: isSeeking = true
        case .leftMouseUp: isSeeking = false
        default: break
        }
        player.seek(absolute: sender.doubleValue)
        timeLabel.stringValue = formatTime(sender.doubleValue)
    }

    @objc private func volumeSliderMoved(_ sender: NSSlider) {
        player.setDouble("volume", sender.doubleValue)
    }

    @objc func show3D() { onShow3D?() }

    @objc func toggleFullScreenAction() { window?.toggleFullScreen(nil) }

    func seek(by seconds: Double) {
        guard fileLoaded else { return }
        player.seek(relative: seconds)
        showControls()
    }

    func changeVolume(by delta: Double) {
        player.addVolume(delta)
        let v = Int((player.getDouble("volume") ?? 0).rounded())
        player.command(["show-text", "Volume \(v)%", "1000"])
    }

    func toggleMute() {
        player.toggleMute()
        player.command(["show-text", player.getFlag("mute") ? "Muto" : "Audio attivo", "1000"])
    }

    // MARK: Eventi di mpv

    func playerFileLoaded(_ player: MPVPlayer) {
        fileLoaded = true
        placeholder.isHidden = true
        if let title = player.getString("media-title"), !title.isEmpty {
            window?.title = title
        }
        refreshTrackUI()
        applyAtmosPreference()
        showControls()
    }

    func playerVideoReconfig(_ player: MPVPlayer) {
        updateHDR()
        guard !sizedForCurrentFile, let window = window, !window.styleMask.contains(.fullScreen),
              let w = player.getDouble("dwidth"), let h = player.getDouble("dheight"), w > 0, h > 0,
              let screen = window.screen ?? NSScreen.main else { return }
        sizedForCurrentFile = true
        let maxSize = NSSize(width: screen.visibleFrame.width * 0.8, height: screen.visibleFrame.height * 0.8)
        let scale = min(1, maxSize.width / CGFloat(w), maxSize.height / CGFloat(h))
        let size = NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.midX - frame.width / 2
        frame.origin.y = window.frame.midY - frame.height / 2
        window.setFrame(frame, display: true, animate: true)
    }

    func playerPropertyChanged(_ player: MPVPlayer, name: String) {
        switch name {
        case "pause":
            let paused = player.isPaused
            playButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                       accessibilityDescription: paused ? "Play" : "Pausa")
            if paused { showControls() }
        case "time-pos":
            let t = player.getDouble("time-pos") ?? 0
            timeLabel.stringValue = formatTime(t)
            if !isSeeking { seekSlider.doubleValue = t }
        case "duration":
            let d = player.getDouble("duration") ?? 0
            seekSlider.maxValue = max(d, 1)
            durationLabel.stringValue = formatTime(d)
        case "volume":
            volumeSlider.doubleValue = player.getDouble("volume") ?? 100
        case "track-list", "current-tracks/audio/codec-profile":
            refreshTrackUI()
        case "video-params/gamma":
            updateHDR()
        case "media-title":
            if fileLoaded, let title = player.getString("media-title"), !title.isEmpty { window?.title = title }
        default:
            break
        }
    }

    func playerEndFile(_ player: MPVPlayer) {
        showControls()
    }

    func playerShutdown(_ player: MPVPlayer) {}

    // MARK: HDR

    func updateHDR() {
        let gamma = player.getString("video-params/gamma") ?? ""
        let isHDR = gamma == "pq" || gamma == "hlg"
        let screen = window?.screen ?? NSScreen.main
        let edr = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        videoView.videoLayer.setHDR(isHDR && edr > 1, peakNits: Double(edr) * 100)
    }

    func windowDidChangeScreen(_ notification: Notification) { updateHDR() }

    func windowWillClose(_ notification: Notification) {
        // Chiudendo la finestra si ferma la riproduzione (l'app resta aperta).
        player.command(["stop"])
        fileLoaded = false
        currentPath = nil
        placeholder.isHidden = false
        window?.title = "TC Atmos Player"
        osc.clear()
    }

    func windowDidResize(_ notification: Notification) { videoView.videoLayer.forceDraw() }

    // MARK: Utilità

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

/// Elenco dei file aperti di recente.
enum RecentFiles {
    private static let key = "recentFiles"

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
