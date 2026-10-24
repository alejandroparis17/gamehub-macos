// Genera portadas de ejemplo (degradado + inicial) para examples/art. uso: mkplaceholders <carpeta>
import AppKit
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let sets: [(String, String, [NSColor])] = [
    ("example1", "A", [NSColor(calibratedRed: 0.86, green: 0.10, blue: 0.20, alpha: 1), NSColor(calibratedRed: 0.35, green: 0.05, blue: 0.25, alpha: 1)]),
    ("example2", "B", [NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.45, alpha: 1)]),
    ("example3", "C", [NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.50, alpha: 1), NSColor(calibratedRed: 0.03, green: 0.30, blue: 0.30, alpha: 1)]),
    ("example4", "D", [NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.15, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.15, blue: 0.10, alpha: 1)])]
for (name, letter, cols) in sets {
    let img = NSImage(size: NSSize(width: 640, height: 640), flipped: false) { r in
        NSGradient(colors: cols)!.draw(in: r, angle: -55)
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 360, weight: .black), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
        let s = NSAttributedString(string: letter, attributes: a); let z = s.size()
        s.draw(at: NSPoint(x: (r.width - z.width) / 2, y: (r.height - z.height) / 2))
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
}
