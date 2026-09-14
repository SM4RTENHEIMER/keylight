// Key parsing and Camelot-wheel compatibility (shared by the app and its test).

import Foundation

// MARK: - keys

struct Camelot: Equatable {
    let number: Int      // 1...12
    let minor: Bool      // A = minor, B = major

    var label: String { "\(number)\(minor ? "A" : "B")" }
    var standard: String {
        let majors = [1: "B", 2: "F#", 3: "Db", 4: "Ab", 5: "Eb", 6: "Bb", 7: "F", 8: "C", 9: "G", 10: "D", 11: "A", 12: "E"]
        let minors = [1: "Abm", 2: "Ebm", 3: "Bbm", 4: "Fm", 5: "Cm", 6: "Gm", 7: "Dm", 8: "Am", 9: "Em", 10: "Bm", 11: "F#m", 12: "Dbm"]
        return (minor ? minors[number] : majors[number]) ?? "?"
    }
    /// Colour of this key as Serato DJ Pro 4 shows it in the Key column (read off a
    /// screenshot of Serato's own key colouring, 0-255 RGB). A/minor keys are bright,
    /// B/major keys are the dimmer version. 12B was not in the screenshot and is derived.
    var rgb: (Int, Int, Int) {
        let minors = [1: (0x6E, 0xD8, 0xA4), 2: (0x8E, 0xF6, 0x72), 3: (0xBC, 0xF8, 0x60), 4: (0xFA, 0xDC, 0x58), 5: (0xF0, 0xA2, 0x52), 6: (0xF2, 0x82, 0x4E),
                      7: (0xEC, 0x6C, 0x62), 8: (0xF0, 0x70, 0xE8), 9: (0xB2, 0x82, 0xF8), 10: (0x62, 0x9C, 0xF6), 11: (0x6A, 0xD0, 0xFA), 12: (0x78, 0xE8, 0xEA)]
        let majors = [1: (0x48, 0x98, 0x72), 2: (0x68, 0xB8, 0x52), 3: (0x8A, 0xB8, 0x42), 4: (0xBA, 0xA6, 0x3E), 5: (0xB2, 0x78, 0x3A), 6: (0xB4, 0x60, 0x38),
                      7: (0xB0, 0x50, 0x46), 8: (0xB2, 0x50, 0xAE), 9: (0x84, 0x5E, 0xB8), 10: (0x46, 0x74, 0xB8), 11: (0x4A, 0x9A, 0xBA), 12: (0x56, 0xA7, 0xA8)]
        return (minor ? minors[number] : majors[number]) ?? (0xFF, 0xFF, 0xFF)
    }
    /// Same key, the neighbours on the wheel, and the relative major/minor.
    var compatible: [Camelot] {
        let prev = (number + 10) % 12 + 1
        let next = number % 12 + 1
        return [Camelot(number: prev, minor: minor), self, Camelot(number: next, minor: minor), Camelot(number: number, minor: !minor)]
    }

    static func parse(_ raw: String) -> Camelot? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        // Camelot "8A" / "12B"
        if let m = s.range(of: #"^(1[0-2]|[1-9])\s*([ABab])$"#, options: .regularExpression) {
            let t = String(s[m])
            let letter = t.last!.uppercased()
            let n = Int(t.dropLast().trimmingCharacters(in: .whitespaces)) ?? 0
            return Camelot(number: n, minor: letter == "A")
        }
        // Open Key "1m" / "8d"
        if let m = s.range(of: #"^(1[0-2]|[1-9])\s*([mdMD])$"#, options: .regularExpression) {
            let t = String(s[m])
            let letter = t.last!.lowercased()
            let n = Int(t.dropLast().trimmingCharacters(in: .whitespaces)) ?? 0
            return Camelot(number: (n + 6) % 12 + 1, minor: letter == "m")
        }
        // Standard "F#m", "Eb", "A minor", "Dbmaj"
        guard let m = s.range(of: #"^([A-Ga-g])([#b♯♭]?)\s*(m|min|minor|maj|major|dur|mol|moll)?$"#, options: .regularExpression) else { return nil }
        let t = String(s[m])
        var chars = Array(t)
        let note = String(chars.removeFirst()).uppercased()
        var acc = ""
        if let c = chars.first, "#b♯♭".contains(c) { acc = (c == "♯" ? "#" : (c == "♭" ? "b" : String(c))); chars.removeFirst() }
        let rest = String(chars).trimmingCharacters(in: .whitespaces).lowercased()
        let minor = ["m", "min", "minor", "mol", "moll"].contains(rest)
        let majors: [String: Int] = ["C": 8, "C#": 3, "Db": 3, "D": 10, "D#": 5, "Eb": 5, "E": 12, "F": 7, "F#": 2, "Gb": 2, "G": 9, "G#": 4, "Ab": 4, "A": 11, "A#": 6, "Bb": 6, "B": 1, "Cb": 1, "Fb": 12, "E#": 7, "B#": 8]
        let minors: [String: Int] = ["A": 8, "A#": 3, "Bb": 3, "B": 10, "C": 5, "C#": 12, "Db": 12, "D": 7, "D#": 2, "Eb": 2, "E": 9, "F": 4, "F#": 11, "Gb": 11, "G": 6, "G#": 1, "Ab": 1, "Cb": 10]
        guard let n = (minor ? minors : majors)[note + acc] else { return nil }
        return Camelot(number: n, minor: minor)
    }
}

