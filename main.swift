// keylight - a floating "traffic light" for Serato DJ Pro 4.
//
// Shows, for every deck that has a track loaded, the track's key and BPM, the keys that
// mix with it (same key, the two neighbours on the Camelot wheel, and the relative
// major/minor), and whether the loaded decks fit each other. Serato 4 writes deck loads
// into its SQLite library within a second; we read that database read-only once per
// second and never write to it.
//
// Build: sh build.sh  (top-level code must live in main.swift); app bundle: sh make-app.sh

import AppKit
import ServiceManagement
import SQLite3

// MARK: - Serato

struct Deck {
    let number: Int
    let name: String
    let key: String
    let bpm: Double
}

final class SeratoReader {
    let path = NSString(string: "~/Library/Application Support/Serato/Library/master.sqlite").expandingTildeInPath
    private var lastStamp = ""
    private var cached: [Deck]? = nil

    /// Serato appends to the write-ahead log on every change, so a cheap look at the
    /// sizes and modification times of the database files tells us whether anything can
    /// have changed since the last query. Most seconds nothing has, and we skip the query.
    func decksIfChanged() -> [Deck]? {
        var stamp = ""
        for suffix in ["", "-wal"] {
            if let a = try? FileManager.default.attributesOfItem(atPath: path + suffix) {
                stamp += "\((a[.size] as? Int) ?? 0):\(((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0));"
            }
        }
        if stamp == lastStamp { return cached }
        lastStamp = stamp
        cached = decks()
        return cached
    }

    /// The track currently loaded on each deck: the newest history entry per deck whose
    /// end_time is still -1 (Serato sets it when the deck is cleared or reloaded).
    func decks() -> [Deck]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        let sql = """
            SELECT deck, name, key, bpm FROM history_entry
             WHERE end_time = -1
               AND id IN (SELECT MAX(id) FROM history_entry WHERE end_time = -1 GROUP BY deck)
             ORDER BY deck
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [Deck] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let deck = Int(sqlite3_column_int(stmt, 0))
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let key = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let bpm = sqlite3_column_double(stmt, 3)
            out.append(Deck(number: deck, name: name, key: key, bpm: bpm))
        }
        return out
    }
}

func seratoRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Serato DJ Pro" || $0.bundleIdentifier == "com.serato.seratodj" }
}

// MARK: - UI pieces

enum Notation: Int { case both = 0, camelot = 1, standard = 2 }

/// A row of key "chips": rounded rectangles filled with the key's colour, like Serato's
/// key column. Optional dim prefix/suffix text.
final class ChipsView: NSView {
    struct Chip { let text: String; let color: NSColor; let highlight: Bool }
    var chips: [Chip] = [] { didSet { needsDisplay = true } }
    var prefix = "" { didSet { needsDisplay = true } }
    var prefixColor: NSColor? = nil { didSet { needsDisplay = true } }   // nil = dim white
    var suffix = "" { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 15
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.6)]
        let h = bounds.height
        var x: CGFloat = 0
        if !prefix.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = prefixColor.map { [.font: font, .foregroundColor: $0] } ?? dim
            let sz = (prefix as NSString).size(withAttributes: attrs)
            (prefix as NSString).draw(at: NSPoint(x: x, y: (h - sz.height) / 2), withAttributes: attrs)
            x += sz.width + 12
        }
        for chip in chips {
            // Dark text on the bright (A) colours, white text on the dim (B) colours.
            let c = chip.color.usingColorSpace(.sRGB) ?? chip.color
            let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            let ink: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: luminance > 0.55 ? NSColor(white: 0.08, alpha: 1) : NSColor.white]
            let sz = (chip.text as NSString).size(withAttributes: ink)
            let padX = fontSize * 0.6, padY = fontSize * 0.2
            let rect = NSRect(x: x, y: (h - sz.height) / 2 - padY, width: sz.width + 2 * padX, height: sz.height + 2 * padY)
            let path = NSBezierPath(roundedRect: rect, xRadius: fontSize * 0.45, yRadius: fontSize * 0.45)
            chip.color.setFill()
            path.fill()
            if chip.highlight {
                NSColor.white.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            (chip.text as NSString).draw(at: NSPoint(x: x + padX, y: (h - sz.height) / 2), withAttributes: ink)
            x += rect.width + fontSize * 0.55
        }
        if !suffix.isEmpty {
            let sz = (suffix as NSString).size(withAttributes: dim)
            (suffix as NSString).draw(at: NSPoint(x: x + 6, y: (h - sz.height) / 2), withAttributes: dim)
        }
    }
}

final class DeckRow {
    let head = ChipsView()
    let track = NSTextField(labelWithString: "")
    let keys = ChipsView()
    let scale: CGFloat
    var height: CGFloat { 92 * scale }

    init(scale: CGFloat) {
        self.scale = scale
        head.fontSize = 21 * scale
        keys.fontSize = 14 * scale
        track.font = NSFont.systemFont(ofSize: 12 * scale)
        track.textColor = NSColor(white: 1, alpha: 0.6)
        track.lineBreakMode = .byTruncatingTail
        track.isEditable = false; track.isBordered = false; track.drawsBackground = false
    }

    func layout(in view: NSView, top: CGFloat, width: CGFloat) {
        let x: CGFloat = 16 * scale
        head.frame = NSRect(x: x, y: top - 38 * scale, width: width - 2 * x, height: 36 * scale)
        track.frame = NSRect(x: x, y: top - 56 * scale, width: width - 2 * x, height: 16 * scale)
        keys.frame = NSRect(x: x, y: top - 88 * scale, width: width - 2 * x, height: 30 * scale)
        for v in [head, track, keys] as [NSView] where v.superview == nil { view.addSubview(v) }
    }

    func remove() { for v in [head, track, keys] as [NSView] { v.removeFromSuperview() } }

    static func color(_ c: Camelot) -> NSColor {
        let (r, g, b) = c.rgb
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    static func text(_ c: Camelot, _ notation: Notation) -> String {
        switch notation {
        case .camelot: return c.label
        case .standard: return c.standard
        case .both: return "\(c.label) \(c.standard)"
        }
    }

    /// A green that is none of Serato's key greens (1A mint, 2A/3A yellow-greens).
    static let matchGreen = NSColor(srgbRed: 0.0, green: 1.0, blue: 0.35, alpha: 1)

    func show(_ deck: Deck, notation: Notation, fits: Bool) {
        let cam = Camelot.parse(deck.key)
        head.prefix = "\(deck.number)"
        head.prefixColor = fits ? DeckRow.matchGreen : nil
        head.suffix = deck.bpm > 0 ? String(format: "%.1f", deck.bpm) : ""
        track.stringValue = deck.name
        if let c = cam {
            head.chips = [ChipsView.Chip(text: DeckRow.text(c, notation), color: DeckRow.color(c), highlight: false)]
            keys.prefix = "➜"
            keys.chips = c.compatible.map { ChipsView.Chip(text: DeckRow.text($0, notation), color: DeckRow.color($0), highlight: $0 == c) }
        } else {
            head.chips = [ChipsView.Chip(text: deck.key.isEmpty ? "ingen toneart" : deck.key, color: NSColor(white: 0.75, alpha: 1), highlight: false)]
            keys.prefix = ""
            keys.chips = []
        }
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let panel: NSPanel
    let content = NSView()
    let status = NSTextField(labelWithString: "")
    var rows: [DeckRow] = []
    var statusItem: NSStatusItem?
    let reader = SeratoReader()
    let defaults = UserDefaults.standard
    var notation: Notation
    var scale: CGFloat
    var followSerato: Bool                    // show the panel only while Serato is running
    var seratoWasRunning = false
    var lastSignature = ""
    var width: CGFloat { 360 * scale }

    override init() {
        notation = Notation(rawValue: defaults.integer(forKey: "notation")) ?? .both
        let s = defaults.double(forKey: "scale")
        scale = s > 0 ? CGFloat(s) : 1.0
        followSerato = defaults.object(forKey: "followSerato") == nil ? true : defaults.bool(forKey: "followSerato")
        panel = NSPanel(contentRect: NSRect(x: 80, y: 80, width: 360, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel.level = .floating                       // above every normal window, even when Serato has focus
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true       // drag it anywhere by its body
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.title = "keylight"

        content.wantsLayer = true                     // nearly opaque, no blur: colours stay crisp
        content.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.94).cgColor
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        panel.contentView = content

        status.textColor = NSColor(white: 1, alpha: 0.7)
        status.isEditable = false; status.isBordered = false; status.drawsBackground = false
        content.addSubview(status)

        if let saved = defaults.string(forKey: "frame") {
            let r = NSRectFromString(saved)
            if r.width > 0 { panel.setFrameOrigin(r.origin) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.defaults.set(NSStringFromRect(self.panel.frame), forKey: "frame")
        }

        // The same menu in two places: the ♪ icon in the menu bar (top right) and a
        // right-click on the panel itself, for when the menu bar is hidden or crowded.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "♪"
        item.menu = makeMenu()
        statusItem = item
        content.menu = makeMenu()

        seratoWasRunning = seratoRunning()
        refresh(force: true)
        if !(followSerato && !seratoWasRunning) { panel.orderFrontRegardless() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh(force: false) }
    }

    // MARK: menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ sel: Selector, key: String = "", on: Bool = false) {
            let m = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            m.target = self
            m.state = on ? .on : .off
            menu.addItem(m)
        }
        add("Skjul panel (vis igen fra ♪ i menulinjen)", #selector(toggle))
        menu.addItem(.separator())
        add("Camelot + standard", #selector(setBoth), on: notation == .both)
        add("Kun Camelot (8A)", #selector(setCamelot), on: notation == .camelot)
        add("Kun standard (Am)", #selector(setStandard), on: notation == .standard)
        menu.addItem(.separator())
        add("Lille", #selector(setSmall), on: scale < 0.95)
        add("Mellem", #selector(setMedium), on: scale >= 0.95 && scale <= 1.05)
        add("Stor", #selector(setLarge), on: scale > 1.05)
        menu.addItem(.separator())
        add("Vis kun mens Serato kører", #selector(toggleFollow), on: followSerato)
        add("Start ved login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Afslut keylight", #selector(quit), key: "q")
        return menu
    }

    func rebuildMenus() {
        statusItem?.menu = makeMenu()
        content.menu = makeMenu()
    }

    @objc func toggle() { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func setBoth() { setNotation(.both) }
    @objc func setCamelot() { setNotation(.camelot) }
    @objc func setStandard() { setNotation(.standard) }
    @objc func setSmall() { setScale(0.85) }
    @objc func setMedium() { setScale(1.0) }
    @objc func setLarge() { setScale(1.3) }

    func setNotation(_ n: Notation) { notation = n; defaults.set(n.rawValue, forKey: "notation"); rebuildMenus(); refresh(force: true) }

    func setScale(_ s: CGFloat) {
        scale = s
        defaults.set(Double(s), forKey: "scale")
        for r in rows { r.remove() }
        rows = []
        rebuildMenus()
        refresh(force: true)
    }

    @objc func toggleFollow() {
        followSerato.toggle()
        defaults.set(followSerato, forKey: "followSerato")
        rebuildMenus()
        if !followSerato { panel.orderFrontRegardless() }
        refresh(force: true)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Kunne ikke ændre login-start"
            a.informativeText = "\(error.localizedDescription)\n\nDu kan også tilføje keylight under Systemindstillinger → Generelt → Loginemner."
            a.runModal()
        }
        rebuildMenus()
    }

    // MARK: refresh

    func refresh(force: Bool) {
        let decks = force ? reader.decks() : reader.decksIfChanged()
        let running = seratoRunning()

        if followSerato {
            if running && !seratoWasRunning { panel.orderFrontRegardless() }   // Serato just started: appear
            if !running && panel.isVisible { panel.orderOut(nil) }             // Serato gone: disappear
        }
        seratoWasRunning = running

        let signature = (decks ?? []).map { "\($0.number)|\($0.name)|\($0.key)|\($0.bpm)" }.joined(separator: ";") + "|\(running)|\(notation.rawValue)|\(scale)"
        if !force && signature == lastSignature { return }
        lastSignature = signature

        let shown = (decks ?? []).filter { !$0.name.isEmpty }
        while rows.count < shown.count { rows.append(DeckRow(scale: scale)) }
        while rows.count > shown.count { rows.removeLast().remove() }

        // A deck number turns green when its key fits at least one other loaded deck.
        let keys = shown.map { Camelot.parse($0.key) }
        let fits: [Bool] = keys.indices.map { i in
            guard let a = keys[i] else { return false }
            return keys.indices.contains { j in j != i && keys[j].map { a.compatible.contains($0) } == true }
        }

        let rowH = 92 * scale
        let statusHeight: CGFloat = shown.isEmpty ? 40 * scale : 0
        let height = CGFloat(shown.count) * rowH + statusHeight + 12 * scale
        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = topEdge - height          // grow downwards, keep the top edge where the user put it
        panel.setFrame(frame, display: true)

        var top = height - 8 * scale
        for (i, (row, deck)) in zip(rows, shown).enumerated() {
            row.layout(in: content, top: top, width: width)
            row.show(deck, notation: notation, fits: fits[i])
            top -= rowH
        }
        if shown.isEmpty {
            status.font = NSFont.systemFont(ofSize: 13 * scale, weight: .medium)
            status.stringValue = decks == nil ? "Serato-bibliotek ikke fundet" : (running ? "Intet nummer på decks" : "Serato kører ikke")
            status.frame = NSRect(x: 16 * scale, y: height - 34 * scale, width: width - 32 * scale, height: 20 * scale)
            status.isHidden = false
        } else {
            status.isHidden = true
        }
    }
}

// One instance is enough: if keylight is already running (e.g. launched twice from the
// Dock), exit quietly.
if let me = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
