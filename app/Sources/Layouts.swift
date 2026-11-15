import Foundation

/// Un diffusore del layout, in coordinate cartesiane normalizzate di Omniphony:
/// x sinistra → destra, y dietro → davanti, z pavimento → soffitto, tutte in [-1, 1].
struct Speaker {
    let name: String
    let x: Double
    let y: Double
    let z: Double
    var spatialize: Bool = true
}

/// Layout di uscita: l'ordine dei diffusori è l'ordine dei canali in uscita.
struct SpeakerLayout {
    let id: String
    let name: String
    let speakers: [Speaker]

    var channelOrder: String {
        speakers.enumerated().map { "\($0.offset + 1) \($0.element.name)" }.joined(separator: " · ")
    }

    static let all: [SpeakerLayout] = [
        SpeakerLayout(id: "5.1.2", name: "5.1.2", speakers: [
            Speaker(name: "FL", x: -1, y: 1, z: 0),
            Speaker(name: "FR", x: 1, y: 1, z: 0),
            Speaker(name: "C", x: 0, y: 1, z: 0),
            Speaker(name: "LFE", x: 1, y: 1, z: -0.5, spatialize: false),
            Speaker(name: "BL", x: -1, y: -1, z: 0),
            Speaker(name: "BR", x: 1, y: -1, z: 0),
            Speaker(name: "TFL", x: -1, y: 1, z: 1),
            Speaker(name: "TFR", x: 1, y: 1, z: 1),
        ]),
        SpeakerLayout(id: "5.1.2-noc", name: "5.1.2 senza centrale", speakers: [
            Speaker(name: "FL", x: -1, y: 1, z: 0),
            Speaker(name: "FR", x: 1, y: 1, z: 0),
            Speaker(name: "LFE", x: 1, y: 1, z: -0.5, spatialize: false),
            Speaker(name: "BL", x: -1, y: -1, z: 0),
            Speaker(name: "BR", x: 1, y: -1, z: 0),
            Speaker(name: "TFL", x: -1, y: 1, z: 1),
            Speaker(name: "TFR", x: 1, y: 1, z: 1),
        ]),
        SpeakerLayout(id: "7.1.2", name: "7.1.2", speakers: [
            Speaker(name: "FL", x: -1, y: 1, z: 0),
            Speaker(name: "FR", x: 1, y: 1, z: 0),
            Speaker(name: "C", x: 0, y: 1, z: 0),
            Speaker(name: "LFE", x: 1, y: 1, z: -0.5, spatialize: false),
            Speaker(name: "SL", x: -1, y: 0, z: 0),
            Speaker(name: "SR", x: 1, y: 0, z: 0),
            Speaker(name: "BL", x: -1, y: -1, z: 0),
            Speaker(name: "BR", x: 1, y: -1, z: 0),
            Speaker(name: "TFL", x: -1, y: 1, z: 1),
            Speaker(name: "TFR", x: 1, y: 1, z: 1),
        ]),
        SpeakerLayout(id: "7.1.4", name: "7.1.4", speakers: [
            Speaker(name: "FL", x: -1, y: 1, z: 0),
            Speaker(name: "FR", x: 1, y: 1, z: 0),
            Speaker(name: "C", x: 0, y: 1, z: 0),
            Speaker(name: "LFE", x: 1, y: 1, z: -1, spatialize: false),
            Speaker(name: "BL", x: -1, y: -1, z: 0),
            Speaker(name: "BR", x: 1, y: -1, z: 0),
            Speaker(name: "SL", x: -1, y: 0, z: 0),
            Speaker(name: "SR", x: 1, y: 0, z: 0),
            Speaker(name: "TFL", x: -1, y: 1, z: 1),
            Speaker(name: "TFR", x: 1, y: 1, z: 1),
            Speaker(name: "TBL", x: -1, y: -1, z: 1),
            Speaker(name: "TBR", x: 1, y: -1, z: 1),
        ]),
        SpeakerLayout(id: "7.1.4-noc", name: "7.1.4 senza centrale", speakers: [
            Speaker(name: "FL", x: -1, y: 1, z: 0),
            Speaker(name: "FR", x: 1, y: 1, z: 0),
            Speaker(name: "LFE", x: 1, y: 1, z: -1, spatialize: false),
            Speaker(name: "BL", x: -1, y: -1, z: 0),
            Speaker(name: "BR", x: 1, y: -1, z: 0),
            Speaker(name: "SL", x: -1, y: 0, z: 0),
            Speaker(name: "SR", x: 1, y: 0, z: 0),
            Speaker(name: "TFL", x: -1, y: 1, z: 1),
            Speaker(name: "TFR", x: 1, y: 1, z: 1),
            Speaker(name: "TBL", x: -1, y: -1, z: 1),
            Speaker(name: "TBR", x: 1, y: -1, z: 1),
        ]),
        SpeakerLayout(id: "9.1.6", name: "9.1.6", speakers: [
            Speaker(name: "FL", x: -1, y: 1, z: 0),
            Speaker(name: "FR", x: 1, y: 1, z: 0),
            Speaker(name: "C", x: 0, y: 1, z: 0),
            Speaker(name: "LFE", x: 1, y: 1, z: -0.5, spatialize: false),
            Speaker(name: "FWL", x: -1, y: 0.5, z: 0),
            Speaker(name: "FWR", x: 1, y: 0.5, z: 0),
            Speaker(name: "SL", x: -1, y: 0, z: 0),
            Speaker(name: "SR", x: 1, y: 0, z: 0),
            Speaker(name: "BL", x: -1, y: -1, z: 0),
            Speaker(name: "BR", x: 1, y: -1, z: 0),
            Speaker(name: "TFL", x: -1, y: 1, z: 1),
            Speaker(name: "TFR", x: 1, y: 1, z: 1),
            Speaker(name: "TSL", x: -1, y: 0, z: 1),
            Speaker(name: "TSR", x: 1, y: 0, z: 1),
            Speaker(name: "TBL", x: -1, y: -1, z: 1),
            Speaker(name: "TBR", x: 1, y: -1, z: 1),
        ]),
    ]

    static func with(id: String) -> SpeakerLayout {
        all.first { $0.id == id } ?? all.first { $0.id == "7.1.4" }!
    }
}

/// Scrive la configurazione del motore Omniphony usata dal player.
/// È un file privato dell'app: non tocca ~/.config/omniphony/config.yaml
/// (quello di Omniphony Studio, se installato).
enum EngineConfig {
    /// Porta su cui il motore riceve i client OSC (la vista 3D).
    /// Diversa dalla 9000 di Omniphony Studio, così non si disturbano.
    static let oscPort = 9137

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TC Atmos Player/omniphony", isDirectory: true)
    }

    static var configURL: URL { directory.appendingPathComponent("config.yaml") }

    private static func num(_ v: Double) -> String { String(format: "%.2f", v) }

    @discardableResult
    static func write(layout: SpeakerLayout) -> URL {
        var y = "# Generato da TC Atmos Player: viene riscritto quando cambi le preferenze.\n"
        y += "render:\n"
        y += "  osc: true\n"
        y += "  osc_metering: true\n"
        y += "  osc_rx_port: \(oscPort)\n"
        y += "  current_layout:\n"
        y += "    radius_m: 2.0\n"
        y += "    speakers:\n"
        for s in layout.speakers {
            y += "      - name: \"\(s.name)\"\n"
            y += "        coord_mode: \"cartesian\"\n"
            y += "        x: \(num(s.x))\n"
            y += "        y: \(num(s.y))\n"
            y += "        z: \(num(s.z))\n"
            y += "        spatialize: \(s.spatialize)\n"
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Un eventuale file di passaggio "live" del motore ignorerebbe le nostre modifiche.
        try? fm.removeItem(at: directory.appendingPathComponent("config.live.yaml"))
        do {
            try y.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Impossibile scrivere \(configURL.path): \(error)")
        }
        return configURL
    }
}
