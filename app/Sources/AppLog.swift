import Foundation

/// Registro diagnostico dell'app: ~/Library/Logs/TC Cinema Player/app.log
/// (accanto c'è mpv.log, il registro dettagliato di mpv). Si azzera a ogni avvio.
enum AppLog {
    static let directory: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/TC Cinema Player", isDirectory: true)
    }()
    static var mpvLogPath: String { directory.appendingPathComponent("mpv.log").path }
    private static let url = directory.appendingPathComponent("app.log")
    private static let queue = DispatchQueue(label: "tc.log")
    private static var handle: FileHandle?
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        write("TC Cinema Player \(v) (\(b)) avviato")
    }

    static func write(_ text: String) {
        let line = "\(formatter.string(from: Date())) \(text)\n"
        queue.async {
            handle?.write(line.data(using: .utf8)!)
        }
    }
}
