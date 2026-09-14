// Run: sh test.sh
import Foundation

var failures = 0
func expect(_ cond: Bool, _ what: String) { if !cond { failures += 1; print("FAIL \(what)") } }

let cases: [(String, String)] = [
    ("Am", "8A"), ("C", "8B"), ("Dbm", "12A"), ("C#m", "12A"), ("Eb", "5B"), ("D#", "5B"), ("F#m", "11A"), ("Gbm", "11A"),
    ("Abm", "1A"), ("G#m", "1A"), ("B", "1B"), ("Bb", "6B"), ("A#", "6B"), ("Em", "9A"), ("8A", "8A"), ("12b", "12B"),
    ("1m", "8A"), ("1d", "8B"), ("2d", "9B"), ("8d", "3B"), ("A minor", "8A"), ("Db maj", "3B"), ("a", "11B"), ("G", "9B"),
]
for (input, want) in cases {
    let got = Camelot.parse(input)?.label ?? "nil"
    expect(got == want, "parse \(input) -> \(got), wanted \(want)")
}
expect(Camelot.parse("") == nil && Camelot.parse("H") == nil && Camelot.parse("13A") == nil, "invalid keys give nil")
let c = Camelot.parse("8A")!
expect(c.compatible.map { $0.label } == ["7A", "8A", "9A", "8B"], "compatible of 8A: \(c.compatible.map { $0.label })")
let one = Camelot.parse("1B")!
expect(one.compatible.map { $0.label } == ["12B", "1B", "2B", "1A"], "compatible wraps at 1: \(one.compatible.map { $0.label })")
let twelve = Camelot.parse("12A")!
expect(twelve.compatible.map { $0.label } == ["11A", "12A", "1A", "12B"], "compatible wraps at 12: \(twelve.compatible.map { $0.label })")
expect(Camelot.parse("Dbm")!.standard == "Dbm" && Camelot.parse("C#m")!.standard == "Dbm" && Camelot.parse("Ab")!.standard == "Ab", "standard names")
var colours = Set<String>()
for n in 1...12 { for minor in [true, false] { let (r, g, b) = Camelot(number: n, minor: minor).rgb; colours.insert("\(r),\(g),\(b)"); expect(max(r, g, b) <= 255 && max(r, g, b) >= 0x90, "key colour \(n)\(minor ? "A" : "B") is visible") } }
expect(colours.count == 24, "24 distinct key colours (got \(colours.count))")
print(failures == 0 ? "camelot: all \(cases.count + 30) checks ok" : "camelot: \(failures) failed")
exit(failures == 0 ? 0 : 1)
