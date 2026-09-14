// Prints the dominant saturated colours in an image (e.g. a screenshot of Serato's key
// column) with pixel counts, so text colours can be read off exactly.
// Build/run: xcrun swiftc -O -o /tmp/colorsample colorsample.swift && /tmp/colorsample shot.png [minCount]
import AppKit
let path = CommandLine.arguments[1]
let minCount = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 30 : 30
guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { print("cannot read image"); exit(1) }
var counts: [UInt32: Int] = [:]
for y in 0..<rep.pixelsHigh {
    for x in 0..<rep.pixelsWide {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        let mx = max(r, g, b), mn = min(r, g, b)
        if mx < 60 || mx - mn < 40 { continue }               // skip dark background and greys
        // quantise slightly so anti-aliased shades of the same colour cluster together
        let q = UInt32((r / 8) << 16 | (g / 8) << 8 | (b / 8))
        counts[q, default: 0] += 1
    }
}
let sorted = counts.sorted { $0.value > $1.value }
print("image \(rep.pixelsWide)x\(rep.pixelsHigh); colours with >= \(minCount) px:")
for (q, n) in sorted where n >= minCount {
    let r = Int((q >> 16) & 0xFF) * 8 + 4, g = Int((q >> 8) & 0xFF) * 8 + 4, b = Int(q & 0xFF) * 8 + 4
    print(String(format: "  #%02X%02X%02X  %6d px", r, g, b, n))
}
