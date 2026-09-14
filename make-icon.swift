// Draws the app icon (dark rounded square with a green ♪) at the sizes iconutil wants.
import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = CommandLine.arguments[1]
for px in sizes {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: px, height: px).insetBy(dx: CGFloat(px) * 0.04, dy: CGFloat(px) * 0.04)
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: CGFloat(px) * 0.22, yRadius: CGFloat(px) * 0.22).fill()
    let text = "♪" as NSString
    let font = NSFont.systemFont(ofSize: CGFloat(px) * 0.62, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.55, alpha: 1)]
    let sz = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (CGFloat(px) - sz.width) / 2, y: (CGFloat(px) - sz.height) / 2 + CGFloat(px) * 0.02), withAttributes: attrs)
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    for (name, scale) in [("icon_\(px)x\(px).png", 1), ("icon_\(px / 2)x\(px / 2)@2x.png", 2)] where px / scale >= 16 && px / scale <= 512 {
        try! png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
