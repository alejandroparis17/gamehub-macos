// Genera el icono de la app (un mando dibujado a mano; sin SF Symbols, cuya licencia no permite usarlos en iconos).
// uso: mkicon <salida.png>
import AppKit
let size = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
    let tile = NSBezierPath(roundedRect: r.insetBy(dx: 40, dy: 40), xRadius: 200, yRadius: 200)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.24, alpha: 1), NSColor(calibratedRed: 0.36, green: 0.18, blue: 0.62, alpha: 1)])!.draw(in: tile, angle: -50)
    NSColor.white.setFill()
    // cuerpo: dos empuñaduras unidas por una barra
    let body = NSBezierPath()
    body.append(NSBezierPath(roundedRect: NSRect(x: 230, y: 400, width: 564, height: 250), xRadius: 125, yRadius: 125))
    body.append(NSBezierPath(ovalIn: NSRect(x: 200, y: 290, width: 270, height: 330)))
    body.append(NSBezierPath(ovalIn: NSRect(x: 554, y: 290, width: 270, height: 330)))
    body.fill()
    NSColor(calibratedRed: 0.18, green: 0.16, blue: 0.40, alpha: 1).setFill()
    // cruceta
    NSBezierPath(roundedRect: NSRect(x: 318, y: 478, width: 130, height: 36), xRadius: 10, yRadius: 10).fill()
    NSBezierPath(roundedRect: NSRect(x: 365, y: 431, width: 36, height: 130), xRadius: 10, yRadius: 10).fill()
    // botones
    for (x, y) in [(660, 530), (722, 478), (598, 478), (660, 426)] { NSBezierPath(ovalIn: NSRect(x: x - 26, y: y - 26, width: 52, height: 52)).fill() }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
