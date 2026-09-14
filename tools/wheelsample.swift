// Samples the 24 Camelot segments of a colour-wheel image: outer ring = B (major),
// inner ring = A (minor). 12 sits at the top, numbers increase clockwise.
import AppKit
let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { print("cannot read"); exit(1) }
let w = rep.pixelsWide, h = rep.pixelsHigh
// Find the wheel: bounding box of saturated pixels.
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
    if max(r, g, b) - min(r, g, b) > 0.25 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
} }
let cx = Double(minX + maxX) / 2, cy = Double(minY + maxY) / 2, R = Double(max(maxX - minX, maxY - minY)) / 2
print("centre \(Int(cx)),\(Int(cy)) radius \(Int(R))")
func sample(_ number: Int, _ minor: Bool) -> (Int, Int, Int) {
    // angle: 12 at top; clockwise; sample the middle of the segment, offset a bit off the text
    let radiusFrac = minor ? 0.50 : 0.86
    var votes: [UInt32: Int] = [:]
    for dAngle in stride(from: -11.0, through: 11.0, by: 1.0) {
        for dr in stride(from: -0.06, through: 0.06, by: 0.02) {
            let ang = (Double(number % 12) * 30.0 + dAngle) * .pi / 180.0
            let x = Int(cx + (radiusFrac + dr) * R * sin(ang)), y = Int(cy - (radiusFrac + dr) * R * cos(ang))
            guard x >= 0, y >= 0, x < w, y < h, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
            if max(r, g, b) - min(r, g, b) < 30 { continue }   // text, borders
            votes[UInt32((r / 4) << 16 | (g / 4) << 8 | (b / 4)), default: 0] += 1
        }
    }
    let best = votes.max { $0.value < $1.value }!.key
    return (Int((best >> 16) & 0xFF) * 4 + 2, Int((best >> 8) & 0xFF) * 4 + 2, Int(best & 0xFF) * 4 + 2)
}
for n in 1...12 {
    let a = sample(n, true), b = sample(n, false)
    print(String(format: "%2dA #%02X%02X%02X    %2dB #%02X%02X%02X", n, a.0, a.1, a.2, n, b.0, b.1, b.2))
}
