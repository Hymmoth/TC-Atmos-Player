import SwiftUI
import AppKit

/// Dispositivo audio come lo elenca mpv.
struct AudioDevice: Hashable, Identifiable {
    let name: String
    let description: String
    var id: String { name }
}

/// Stato condiviso per la registrazione di una scorciatoia.
enum ShortcutRecorder {
    static var isRecording = false
}

struct PreferencesView: View {
    @ObservedObject var settings = AppSettings.shared
    let devices: () -> [AudioDevice]

    init(devices: @escaping () -> [AudioDevice]) {
        self.devices = devices
    }

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("Generale", systemImage: "gearshape") }
            AudioPane(settings: settings, devices: devices)
                .tabItem { Label("Audio", systemImage: "hifispeaker.2") }
            ShortcutsPane(settings: settings)
                .tabItem { Label("Scorciatoie", systemImage: "keyboard") }
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TextField("Lingue audio", text: $settings.audioLanguages, prompt: Text("eng, ita"))
                Toggle("Preferisci le tracce Atmos", isOn: $settings.preferAtmos)
                Text("Tra le tracce nella lingua preferita sceglie quella con Atmos, se c'è.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Audio")
            }
            Section {
                TextField("Lingue sottotitoli", text: $settings.subtitleLanguages, prompt: Text("ita"))
                    .disabled(settings.subtitlesOff)
                Text("Se l'audio è in un'altra lingua si attivano i sottotitoli completi; se è nella stessa lingua, solo i forced (se ci sono).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Nessun sottotitolo automatico", isOn: $settings.subtitlesOff)
            } header: {
                Text("Sottotitoli")
            }
            Text("Scrivi i codici delle lingue in ordine di preferenza, separati da virgole (es. ita, eng). Valgono dal prossimo file aperto.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AudioPane: View {
    @ObservedObject var settings: AppSettings
    let devices: () -> [AudioDevice]
    @State private var list: [AudioDevice] = []

    var body: some View {
        Form {
            Section {
                Picker("Dispositivo", selection: $settings.audioDevice) {
                    ForEach(list) { d in
                        Text(d.description).tag(d.name)
                    }
                }
                Button("Aggiorna elenco") { list = devices() }
            } header: {
                Text("Uscita")
            }
            Section {
                Picker("Layout", selection: $settings.layoutId) {
                    ForEach(SpeakerLayout.all, id: \.id) { l in
                        Text(l.name).tag(l.id)
                    }
                }
                Text("Ordine dei canali in uscita:")
                    .font(.caption).foregroundStyle(.secondary)
                Text(settings.layout.channelOrder)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text("Le tracce Atmos e quelle multicanale vengono distribuite su questi canali. Il cambio di layout vale dalla prossima traccia audio aperta.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Rendering")
            }
        }
        .formStyle(.grouped)
        .onAppear { list = devices() }
    }
}

private struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings
    @State private var recording: PlayerAction?
    @State private var message = ""
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(PlayerAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        Button(action: { startRecording(action) }) {
                            Text(label(for: action))
                                .frame(minWidth: 110)
                                .foregroundStyle(recording == action ? Color.accentColor : Color.primary)
                        }
                    }
                }
            }
            HStack {
                Text(message.isEmpty ? "Clicca una scorciatoia e premi il nuovo tasto. Esc annulla, ⌫ la toglie." : message)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Ripristina predefinite") {
                    stopRecording()
                    settings.resetShortcuts()
                    message = "Scorciatoie predefinite ripristinate."
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func label(for action: PlayerAction) -> String {
        if recording == action { return "Premi un tasto…" }
        let s = settings.shortcut(for: action)
        return s.key.isEmpty ? "—" : s.displayString
    }

    private func startRecording(_ action: PlayerAction) {
        stopRecording()
        recording = action
        ShortcutRecorder.isRecording = true
        message = ""
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let action = recording else { return event }
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117 { // ⌫ / Canc
                settings.setShortcut(Shortcut(key: "", modifiers: []), for: action)
                message = "«\(action.title)» senza scorciatoia."
                stopRecording()
                return nil
            }
            guard let s = Shortcut(event: event) else { return nil }
            if let other = settings.action(using: s, except: action) {
                settings.setShortcut(Shortcut(key: "", modifiers: []), for: other)
                message = "\(s.displayString) era usata da «\(other.title)», che ora non ne ha."
            } else {
                message = "«\(action.title)»: \(s.displayString)"
            }
            settings.setShortcut(s, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
        ShortcutRecorder.isRecording = false
    }
}
