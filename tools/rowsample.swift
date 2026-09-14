// For a screenshot of Serato's key column: find the text rows and print each row's
// dominant saturated colour. Rows are labelled in the given order (argument 2, comma list).
import AppKit
let path = CommandLine.arguments[1]
let labels = CommandLine.arguments[2].split(separator: ",").map(String.init)
guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { print("cannot read"); exit(1) }
let w = rep.pixelsWide, h = rep.pixelsHigh
func sat(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
    let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
    return (max(r, g, b) - min(r, g, b) >= 40 && max(r, g, b) >= 70) ? (r, g, b) : nil
}
var rowHasColour = [Bool](repeating: false, count: h)
for y in 0..<h { for x in 0..<w where sat(x, y) != nil { rowHasColour[y] = true; break } }
var bands: [(Int, Int)] = []
var y = 0
while y < h {
    if rowHasColour[y] { var e = y; while e + 1 < h && rowHasColour[e + 1] { e += 1 }; bands.append((y, e)); y = e + 1 } else { y += 1 }
}
print("rows found: \(bands.count), labels: \(labels.count)")
for (i, band) in bands.enumerated() {
    var votes: [UInt32: Int] = [:]
    for yy in band.0...band.1 { for x in 0..<w { if let (r, g, b) = sat(x, yy) { votes[UInt32((r / 2) << 16 | (g / 2) << 8 | (b / 2)), default: 0] += 1 } } }
    let best = votes.max { $0.value < $1.value }!.key
    let r = Int((best >> 16) & 0xFF) * 2, g = Int((best >> 8) & 0xFF) * 2, b = Int(best & 0xFF) * 2
    let label = i < labels.count ? labels[i] : "?"
    print(String(format: "%-4@ #%02X%02X%02X   (rows %d-%d)", label as NSString, r, g, b, band.0, band.1))
}
