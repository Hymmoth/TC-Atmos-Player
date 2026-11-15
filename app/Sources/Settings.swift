import Cocoa
import Combine

/// Azioni che si possono associare a una scorciatoia da tastiera.
enum PlayerAction: String, CaseIterable, Identifiable {
    case playPause, seekForward, seekBackward, seekForwardLong, seekBackwardLong
    case volumeUp, volumeDown, mute, fullscreen, nextAudio, nextSubtitle, view3D, open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: return "Play / Pausa"
        case .seekForward: return "Avanti 10 secondi"
        case .seekBackward: return "Indietro 10 secondi"
        case .seekForwardLong: return "Avanti 1 minuto"
        case .seekBackwardLong: return "Indietro 1 minuto"
        case .volumeUp: return "Volume su"
        case .volumeDown: return "Volume giù"
        case .mute: return "Muto"
        case .fullscreen: return "Schermo intero"
        case .nextAudio: return "Traccia audio successiva"
        case .nextSubtitle: return "Sottotitoli successivi"
        case .view3D: return "Vista 3D"
        case .open: return "Apri file…"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .playPause: return Shortcut(key: " ", modifiers: [])
        case .seekForward: return Shortcut(key: Shortcut.rightArrow, modifiers: [])
        case .seekBackward: return Shortcut(key: Shortcut.leftArrow, modifiers: [])
        case .seekForwardLong: return Shortcut(key: Shortcut.rightArrow, modifiers: [.shift])
        case .seekBackwardLong: return Shortcut(key: Shortcut.leftArrow, modifiers: [.shift])
        case .volumeUp: return Shortcut(key: Shortcut.upArrow, modifiers: [])
        case .volumeDown: return Shortcut(key: Shortcut.downArrow, modifiers: [])
        case .mute: return Shortcut(key: "m", modifiers: [])
        case .fullscreen: return Shortcut(key: "f", modifiers: [])
        case .nextAudio: return Shortcut(key: "a", modifiers: [])
        case .nextSubtitle: return Shortcut(key: "s", modifiers: [])
        case .view3D: return Shortcut(key: "3", modifiers: [])
        case .open: return Shortcut(key: "o", modifiers: [.command])
        }
    }
}

/// Una scorciatoia: il carattere del tasto (minuscolo) e i modificatori.
struct Shortcut: Equatable, Codable {
    var key: String
    var modifierRaw: UInt

    static let upArrow = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!))
    static let downArrow = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!))
    static let leftArrow = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!))
    static let rightArrow = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!))

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifierRaw = modifiers.intersection(Shortcut.relevantModifiers).rawValue
    }

    init?(event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        self.init(key: chars, modifiers: event.modifierFlags)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRaw) }

    var displayString: String {
        var s = ""
        let m = modifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch key {
        case " ": s += "Spazio"
        case Shortcut.upArrow: s += "↑"
        case Shortcut.downArrow: s += "↓"
        case Shortcut.leftArrow: s += "←"
        case Shortcut.rightArrow: s += "→"
        case "\r": s += "Invio"
        case "\t": s += "Tab"
        case "\u{1b}": s += "Esc"
        case "\u{7f}": s += "⌫"
        default:
            if let scalar = key.unicodeScalars.first, scalar.value >= 0xF704, scalar.value <= 0xF70F {
                s += "F\(scalar.value - 0xF704 + 1)"
            } else {
                s += key.uppercased()
            }
        }
        return s
    }
}

/// Preferenze dell'app (salvate in UserDefaults).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    /// Notifica inviata quando cambia qualcosa che il player deve applicare.
    static let changed = Notification.Name("TCSettingsChanged")

    @Published var audioLanguages: String { didSet { save("audioLanguages", audioLanguages) } }
    @Published var subtitleLanguages: String { didSet { save("subtitleLanguages", subtitleLanguages) } }
    @Published var subtitlesOff: Bool { didSet { save("subtitlesOff", subtitlesOff) } }
    @Published var preferAtmos: Bool { didSet { save("preferAtmos", preferAtmos) } }
    @Published var audioDevice: String { didSet { save("audioDevice", audioDevice) } }
    @Published var layoutId: String { didSet { save("layoutId", layoutId) } }
    @Published var shortcuts: [String: Shortcut] { didSet { saveShortcuts() } }

    private init() {
        defaults.register(defaults: [
            "audioLanguages": "eng, ita",
            "subtitleLanguages": "ita",
            "subtitlesOff": false,
            "preferAtmos": true,
            "audioDevice": "auto",
            "layoutId": "7.1.4",
        ])
        // Prima versione: i predefiniti erano audio "ita, eng" e sottotitoli spenti.
        // Se non sono stati cambiati a mano, si passa ai nuovi predefiniti.
        if defaults.integer(forKey: "settingsVersion") < 2 {
            if defaults.string(forKey: "audioLanguages") == "ita, eng" { defaults.removeObject(forKey: "audioLanguages") }
            if defaults.object(forKey: "subtitlesOff") as? Bool == true { defaults.removeObject(forKey: "subtitlesOff") }
            defaults.set(2, forKey: "settingsVersion")
        }
        audioLanguages = defaults.string(forKey: "audioLanguages") ?? ""
        subtitleLanguages = defaults.string(forKey: "subtitleLanguages") ?? ""
        subtitlesOff = defaults.bool(forKey: "subtitlesOff")
        preferAtmos = defaults.bool(forKey: "preferAtmos")
        audioDevice = defaults.string(forKey: "audioDevice") ?? "auto"
        layoutId = defaults.string(forKey: "layoutId") ?? "7.1.4"
        if let data = defaults.data(forKey: "shortcuts"),
           let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = decoded
        } else {
            shortcuts = [:]
        }
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: AppSettings.changed, object: key)
    }

    private func saveShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            defaults.set(data, forKey: "shortcuts")
        }
        NotificationCenter.default.post(name: AppSettings.changed, object: "shortcuts")
    }

    var layout: SpeakerLayout { SpeakerLayout.with(id: layoutId) }

    func shortcut(for action: PlayerAction) -> Shortcut {
        shortcuts[action.rawValue] ?? action.defaultShortcut
    }

    func setShortcut(_ s: Shortcut, for action: PlayerAction) {
        shortcuts[action.rawValue] = s
    }

    func resetShortcuts() { shortcuts = [:] }

    /// L'azione che usa già questa scorciatoia, se c'è.
    func action(using s: Shortcut, except: PlayerAction? = nil) -> PlayerAction? {
        PlayerAction.allCases.first { $0 != except && shortcut(for: $0) == s }
    }

    /// Codici bibliografici ISO 639-2 usati spesso negli MKV, oltre a quelli standard.
    private static let bibliographic: [String: String] = [
        "de": "ger", "fr": "fre", "nl": "dut", "zh": "chi", "cs": "cze", "el": "gre",
        "ro": "rum", "sk": "slo", "fa": "per", "hy": "arm", "ka": "geo", "is": "ice",
        "mk": "mac", "ms": "may", "my": "bur", "sq": "alb", "eu": "baq", "cy": "wel",
        "bo": "tib",
    ]

    /// Tutti i codici con cui può comparire una lingua: "ita" → ["ita", "it"].
    static func codes(for code: String) -> [String] {
        var out = [code]
        let lang = Locale.Language(identifier: code)
        if let a2 = lang.languageCode?.identifier(.alpha2) {
            out.append(a2)
            if let b = bibliographic[a2] { out.append(b) }
        }
        if let a3 = lang.languageCode?.identifier(.alpha3) { out.append(a3) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Lingue come lista per mpv: "ita, eng" → "ita,it,eng,en".
    static func mpvLanguageList(_ text: String) -> String {
        var seen = Set<String>()
        return split(text).flatMap { codes(for: $0) }
            .filter { seen.insert($0).inserted }
            .joined(separator: ",")
    }

    /// Codici delle lingue preferite, in ordine (per confrontarli con le tracce).
    static func languageCodes(_ text: String) -> [Set<String>] {
        split(text).map { Set(codes(for: $0)) }
    }
}
