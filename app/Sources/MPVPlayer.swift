import Cocoa

/// Una traccia (audio, video o sottotitoli) come la descrive mpv.
struct Track {
    let id: Int
    let type: String          // "audio", "video", "sub"
    let lang: String?
    let title: String?
    let codec: String?
    let codecProfile: String?
    let channels: Int?
    let selected: Bool
    let isDefault: Bool
    let external: Bool
    let ffIndex: Int?
    let srcId: Int?
    var isAtmos: Bool = false

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int, let type = json["type"] as? String else { return nil }
        self.id = id
        self.type = type
        lang = json["lang"] as? String
        title = json["title"] as? String
        codec = json["codec"] as? String
        codecProfile = json["codec-profile"] as? String
        channels = json["demux-channel-count"] as? Int
        selected = json["selected"] as? Bool ?? false
        isDefault = json["default"] as? Bool ?? false
        external = json["external"] as? Bool ?? false
        ffIndex = json["ff-index"] as? Int
        srcId = json["src-id"] as? Int
        if let p = codecProfile, p.localizedCaseInsensitiveContains("atmos") || p.contains("DTS:X") {
            isAtmos = true
        }
    }

    /// Nome della lingua in italiano ("Italiano", "Inglese"…), o il codice se sconosciuto.
    var languageName: String? {
        guard let lang = lang, !lang.isEmpty, lang != "und" else { return nil }
        let language = Locale.Language(identifier: lang)
        let code = language.languageCode?.identifier(.alpha2) ?? lang
        if let name = Locale(identifier: "it").localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return lang
    }

    var codecName: String {
        switch codec?.lowercased() ?? "" {
        case "truehd": return "TrueHD"
        case "eac3": return "DD+"
        case "ac3": return "Dolby Digital"
        case "dts": return (codecProfile?.contains("MA") ?? false) ? "DTS-HD MA" : "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_bluray": return "PCM"
        case "subrip": return "SRT"
        case "ass", "ssa": return "ASS"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        case "": return ""
        default: return codec!.uppercased()
        }
    }

    var channelsText: String? {
        guard let c = channels, c > 0 else { return nil }
        switch c {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(c) can."
        }
    }

    /// Testo per i menu: "Italiano · TrueHD 7.1 · ATMOS · titolo".
    var menuTitle: String {
        var parts: [String] = []
        parts.append(languageName ?? "Lingua sconosciuta")
        var fmt = codecName
        if type == "audio", let ch = channelsText { fmt += fmt.isEmpty ? ch : " \(ch)" }
        if !fmt.isEmpty { parts.append(fmt) }
        if isAtmos { parts.append("ATMOS") }
        if let t = title, !t.isEmpty { parts.append(t) }
        if external { parts.append("esterno") }
        return parts.joined(separator: " · ")
    }
}

protocol MPVPlayerDelegate: AnyObject {
    func playerFileLoaded(_ player: MPVPlayer)
    func playerPropertyChanged(_ player: MPVPlayer, name: String)
    func playerEndFile(_ player: MPVPlayer)
    func playerVideoReconfig(_ player: MPVPlayer)
    func playerShutdown(_ player: MPVPlayer)
}

/// Involucro di libmpv: crea l'istanza, imposta le opzioni, inoltra gli eventi.
final class MPVPlayer {
    private(set) var handle: OpaquePointer?
    weak var delegate: MPVPlayerDelegate?
    private let eventQueue = DispatchQueue(label: "tc.mpv.events")

    init() {
        handle = mpv_create()
        guard handle != nil else {
            fatalError("Impossibile creare l'istanza di mpv")
        }
    }

    // MARK: Opzioni e avvio

    func setOption(_ name: String, _ value: String) {
        let r = mpv_set_option_string(handle, name, value)
        if r < 0 {
            NSLog("mpv: opzione \(name)=\(value) rifiutata: \(String(cString: mpv_error_string(r)))")
        }
    }

    func initialize() {
        let r = mpv_initialize(handle)
        if r < 0 {
            fatalError("mpv_initialize fallito: \(String(cString: mpv_error_string(r)))")
        }
        mpv_request_log_messages(handle, "warn")

        for (name, format) in [("pause", MPV_FORMAT_FLAG),
                               ("time-pos", MPV_FORMAT_DOUBLE),
                               ("duration", MPV_FORMAT_DOUBLE),
                               ("volume", MPV_FORMAT_DOUBLE),
                               ("mute", MPV_FORMAT_FLAG),
                               ("track-list", MPV_FORMAT_NONE),
                               ("current-tracks/audio/codec-profile", MPV_FORMAT_NONE),
                               ("video-params/gamma", MPV_FORMAT_NONE),
                               ("media-title", MPV_FORMAT_NONE),
                               ("eof-reached", MPV_FORMAT_FLAG),
                               ("idle-active", MPV_FORMAT_FLAG)] {
            mpv_observe_property(handle, 0, name, format)
        }

        let me = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx = ctx else { return }
            let player = Unmanaged<MPVPlayer>.fromOpaque(ctx).takeUnretainedValue()
            player.wakeup()
        }, me)
    }

    private func wakeup() {
        eventQueue.async { [weak self] in self?.drainEvents() }
    }

    private func drainEvents() {
        guard let handle = handle else { return }
        while true {
            guard let ev = mpv_wait_event(handle, 0) else { break }
            let id = ev.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            switch id {
            case MPV_EVENT_SHUTDOWN:
                DispatchQueue.main.async { self.delegate?.playerShutdown(self) }
                return
            case MPV_EVENT_FILE_LOADED:
                DispatchQueue.main.async { self.delegate?.playerFileLoaded(self) }
            case MPV_EVENT_END_FILE:
                DispatchQueue.main.async { self.delegate?.playerEndFile(self) }
            case MPV_EVENT_VIDEO_RECONFIG:
                DispatchQueue.main.async { self.delegate?.playerVideoReconfig(self) }
            case MPV_EVENT_PROPERTY_CHANGE:
                if let data = ev.pointee.data {
                    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    let name = String(cString: prop.name)
                    DispatchQueue.main.async { self.delegate?.playerPropertyChanged(self, name: name) }
                }
            case MPV_EVENT_LOG_MESSAGE:
                if let data = ev.pointee.data {
                    let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let prefix = String(cString: msg.prefix)
                    let text = String(cString: msg.text)
                    NSLog("mpv[\(prefix)] \(text.trimmingCharacters(in: .newlines))")
                }
            default:
                break
            }
        }
    }

    func destroy() {
        guard let h = handle else { return }
        handle = nil
        mpv_terminate_destroy(h)
    }

    // MARK: Proprietà

    func getString(_ name: String) -> String? {
        guard let handle = handle, let c = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    func getDouble(_ name: String) -> Double? {
        guard let handle = handle else { return nil }
        var v = Double(0)
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func getFlag(_ name: String) -> Bool {
        guard let handle = handle else { return false }
        var v: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &v) >= 0 && v != 0
    }

    func setString(_ name: String, _ value: String) {
        guard let handle = handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let handle = handle else { return }
        var v = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let handle = handle else { return }
        var v: Int32 = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
    }

    /// Legge una proprietà strutturata (es. "track-list") come JSON.
    func getJSON(_ name: String) -> Any? {
        guard let s = getString(name), let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func command(_ args: [String]) {
        guard let handle = handle else { return }
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)
        defer { cargs.forEach { free($0) } }
        cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                let r = mpv_command(handle, p)
                if r < 0 {
                    NSLog("mpv: comando \(args) fallito: \(String(cString: mpv_error_string(r)))")
                }
            }
        }
    }

    // MARK: Comodità

    var tracks: [Track] {
        guard let list = getJSON("track-list") as? [[String: Any]] else { return [] }
        return list.compactMap(Track.init(json:))
    }

    func loadFile(_ url: URL) {
        command(["loadfile", url.path, "replace"])
    }

    var isPaused: Bool { getFlag("pause") }
    func togglePause() { command(["cycle", "pause"]) }
    func seek(relative seconds: Double) { command(["seek", String(seconds), "relative+exact"]) }
    func seek(absolute seconds: Double) { command(["seek", String(seconds), "absolute"]) }
    func addVolume(_ delta: Double) { command(["add", "volume", String(delta)]) }
    func toggleMute() { command(["cycle", "mute"]) }
}
