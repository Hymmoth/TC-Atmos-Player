// Disegna l'icona dell'app e la salva come .iconset (poi: iconutil -c icns).
// Uso: swift scripts/make-icon.swift <cartella.iconset>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Fondo: quadrato arrotondato con sfumatura
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.24, alpha: 1),
                        NSColor(calibratedRed: 0.30, green: 0.12, blue: 0.40, alpha: 1)])!
        .draw(in: bg, angle: -60)

    // Cupola di onde (l'altezza dell'Atmos)
    let center = NSPoint(x: size / 2, y: 330 * s)
    for (i, radius) in [230.0, 330.0, 430.0].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: CGFloat(radius) * s, startAngle: 20, endAngle: 160)
        arc.lineWidth = 34 * s
        arc.lineCapStyle = .round
        NSColor(calibratedRed: 1.0, green: 0.78 - CGFloat(i) * 0.12, blue: 0.20, alpha: 1 - CGFloat(i) * 0.18).setStroke()
        arc.stroke()
    }

    // Triangolo "play"
    let play = NSBezierPath()
    play.move(to: NSPoint(x: 440 * s, y: 240 * s))
    play.line(to: NSPoint(x: 440 * s, y: 520 * s))
    play.line(to: NSPoint(x: 660 * s, y: 380 * s))
    play.close()
    play.lineJoinStyle = .round
    play.lineWidth = 30 * s
    NSColor.white.setFill()
    NSColor.white.setStroke()
    play.fill()
    play.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = draw(size: px)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = rep.representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
print("Icona creata in \(outDir)")
