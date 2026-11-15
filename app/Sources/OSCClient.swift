import Foundation
import Darwin

/// Un oggetto audio come lo pubblica il motore Omniphony.
struct AudioObject {
    var x: Double = 0, y: Double = 0, z: Double = 0
    var name: String = ""
    var label: String = ""
    var fixed = false        // canale del letto (bed) invece che oggetto dinamico
    var rmsDB: Double = -120
    var lastUpdate = Date()
}

/// Valore di un argomento OSC.
enum OSCValue {
    case int(Int64), float(Double), string(String), bool(Bool), other

    var double: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .float(let v): return v
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var int: Int64? {
        switch self {
        case .int(let v): return v
        case .float(let v): return Int64(v)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
}

/// Client OSC minimale: si registra presso il motore di rendering incorporato
/// in mpv e riceve le posizioni degli oggetti per la vista 3D.
final class OSCClient {
    private var fd: Int32 = -1
    private var localPort: UInt16 = 0
    private let enginePort: UInt16
    private var thread: Thread?
    private var running = false
    private let lock = NSLock()
    private var objects: [Int: AudioObject] = [:]
    private var lastReceive = Date.distantPast
    private var lastRegister = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var meteringRequested = false
    private var connectedLogged = false
    private var lastStatusLog = Date.distantPast

    init(enginePort: UInt16) {
        self.enginePort = enginePort
    }

    deinit { stop() }

    /// Copia degli oggetti attuali (thread-safe).
    var snapshot: [Int: AudioObject] {
        lock.lock(); defer { lock.unlock() }
        return objects
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastReceive) < 3
    }

    func start() {
        guard !running else { return }
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { NSLog("OSC: socket fallito"); return }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { NSLog("OSC: bind fallito"); close(fd); fd = -1; return }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actual = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        localPort = UInt16(bigEndian: actual.sin_port)

        var bufSize: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        var sendSize: Int32 = 65536
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendSize, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        AppLog.write("OSC: client sulla porta \(localPort), motore atteso sulla \(enginePort)")
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "tc.osc"
        t.start()
        thread = t
    }

    func stop() {
        running = false
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Dimentica gli oggetti (es. quando si apre un altro file).
    func clear() {
        lock.lock(); objects.removeAll(); lock.unlock()
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while running {
            let now = Date()
            lock.lock()
            let silent = now.timeIntervalSince(lastReceive)
            lock.unlock()
            // Senza traffico da qualche secondo: (ri)registrazione. Il motore esiste
            // solo mentre si riproduce una traccia spaziale, quindi si riprova.
            if now.timeIntervalSince(lastStatusLog) > 10 {
                lastStatusLog = now
                lock.lock()
                let total = objects.count, dynamic = objects.values.filter { !$0.fixed }.count
                lock.unlock()
                AppLog.write("OSC: ultimo pacchetto \(silent > 1e6 ? "mai" : String(format: "%.1f s fa", silent)), oggetti \(dynamic) (+\(total - dynamic) letto)")
                if silent > 6 { connectedLogged = false }
            }
            if silent > 6, now.timeIntervalSince(lastRegister) > 2 {
                send(address: "/omniphony/register", int: Int32(localPort))
                lastRegister = now
                lastHeartbeat = now
                meteringRequested = false
            } else if now.timeIntervalSince(lastHeartbeat) > 4 {
                send(address: "/omniphony/heartbeat", int: Int32(localPort))
                lastHeartbeat = now
            }

            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 65536, 0) }
            if n > 0 {
                lock.lock(); lastReceive = Date(); lock.unlock()
                if !connectedLogged {
                    AppLog.write("OSC: il motore risponde")
                    connectedLogged = true
                }
                if !meteringRequested {
                    // Chiede i livelli degli oggetti (per la dimensione delle sfere).
                    send(address: "/omniphony/control/metering", int: 1)
                    meteringRequested = true
                }
                parsePacket(buffer[0..<n])
            }
        }
    }

    // MARK: Invio

    private func pad(_ data: inout Data) {
        while data.count % 4 != 0 { data.append(0) }
    }

    private func oscString(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0)
        pad(&d)
        return d
    }

    private func send(address: String, int value: Int32) {
        guard fd >= 0 else { return }
        var packet = oscString(address)
        packet.append(oscString(",i"))
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { packet.append(contentsOf: $0) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = enginePort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        packet.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: Ricezione

    private func parsePacket(_ bytes: ArraySlice<UInt8>) {
        let data = Array(bytes)
        if data.count >= 16, data.starts(with: Array("#bundle".utf8)) {
            var pos = 16
            while pos + 4 <= data.count {
                let size = Int(readInt32(data, pos)); pos += 4
                guard size > 0, pos + size <= data.count else { break }
                parsePacket(data[pos..<(pos + size)])
                pos += size
            }
        } else {
            parseMessage(data)
        }
    }

    private func readInt32(_ d: [UInt8], _ p: Int) -> Int32 {
        Int32(bitPattern: UInt32(d[p]) << 24 | UInt32(d[p + 1]) << 16 | UInt32(d[p + 2]) << 8 | UInt32(d[p + 3]))
    }

    private func readInt64(_ d: [UInt8], _ p: Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(d[p + i]) }
        return Int64(bitPattern: v)
    }

    private func readString(_ d: [UInt8], _ p: inout Int) -> String? {
        guard p < d.count, let end = d[p...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: d[p..<end], as: UTF8.self)
        p = (end + 4) & ~3
        return s
    }

    private func parseMessage(_ d: [UInt8]) {
        var p = 0
        guard let address = readString(d, &p), address.hasPrefix("/omniphony/") else { return }
        // Interessano solo gli oggetti: si evita di decodificare il resto.
        guard address.hasPrefix("/omniphony/object/") || address.hasPrefix("/omniphony/meter/object/") else { return }
        guard p < d.count, let tags = readString(d, &p), tags.hasPrefix(",") else { return }
        var args: [OSCValue] = []
        for t in tags.dropFirst() {
            switch t {
            case "i":
                guard p + 4 <= d.count else { return }
                args.append(.int(Int64(readInt32(d, p)))); p += 4
            case "f":
                guard p + 4 <= d.count else { return }
                args.append(.float(Double(Float(bitPattern: UInt32(bitPattern: readInt32(d, p)))))); p += 4
            case "h":
                guard p + 8 <= d.count else { return }
                args.append(.int(readInt64(d, p))); p += 8
            case "d":
                guard p + 8 <= d.count else { return }
                args.append(.float(Double(bitPattern: UInt64(bitPattern: readInt64(d, p))))); p += 8
            case "t":
                guard p + 8 <= d.count else { return }
                args.append(.other); p += 8
            case "s", "S":
                guard let s = readString(d, &p) else { return }
                args.append(.string(s))
            case "b":
                guard p + 4 <= d.count else { return }
                let n = Int(readInt32(d, p)); p += 4
                p = (p + n + 3) & ~3
                args.append(.other)
            case "T": args.append(.bool(true))
            case "F": args.append(.bool(false))
            case "N", "I": args.append(.other)
            default: return
            }
        }
        handle(address: address, args: args)
    }

    private func handle(address: String, args: [OSCValue]) {
        let parts = address.split(separator: "/")
        // /omniphony/object/{id}/{campo}  →  ["omniphony", "object", id, campo]
        if parts.count == 4, parts[1] == "object", let id = Int(parts[2]) {
            let field = parts[3]
            lock.lock(); defer { lock.unlock() }
            switch field {
            case "xyz", "aed":
                guard args.count >= 3, let a = args[0].double, let b = args[1].double, let c = args[2].double else { return }
                // Uno slot "svuotato" arriva come posizione nulla con guadagno -128.
                if args.count >= 5, args[4].int == -128, a == 0, b == 0, c == 0 {
                    objects.removeValue(forKey: id)
                    return
                }
                var o = objects[id] ?? AudioObject()
                if field == "xyz" {
                    o.x = a; o.y = b; o.z = c
                } else {
                    // Azimut/elevazione in gradi (0 = davanti, positivo a destra), distanza.
                    let az = a * .pi / 180, el = b * .pi / 180, dist = c > 0 ? c : 1
                    o.x = sin(az) * cos(el) * dist
                    o.y = cos(az) * cos(el) * dist
                    o.z = sin(el) * dist
                }
                if args.count >= 9, let n = args[8].string { o.name = n }
                o.lastUpdate = Date()
                objects[id] = o
            case "meta":
                var o = objects[id] ?? AudioObject()
                if let f = args.first?.int { o.fixed = f != 0 }
                if args.count >= 2, let l = args[1].string { o.label = l }
                objects[id] = o
            case "remove":
                objects.removeValue(forKey: id)
            default:
                break
            }
        } else if parts.count == 4, parts[1] == "meter", parts[2] == "object", let id = Int(parts[3]) {
            // /omniphony/meter/object/{id}: picco, RMS in dB
            guard args.count >= 2, let rms = args[1].double else { return }
            lock.lock()
            if objects[id] != nil { objects[id]!.rmsDB = rms }
            lock.unlock()
        }
    }
}
