// keylight - a floating "traffic light" for Serato DJ Pro 4.
//
// Shows, for every deck that has a track loaded, the track's key and BPM, the keys that
// mix with it (same key, the two neighbours on the Camelot wheel, and the relative
// major/minor), and whether the loaded decks fit each other. Optionally lists the tracks
// in a crate (or the whole library) that fit the deck you are mixing from.
//
// Serato 4 writes deck loads into its SQLite library within a second; we read that
// database read-only and never write to it.
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
    let startTime: Double
}

struct LibraryTrack {
    let id: Int
    let name: String
    let artist: String
    let key: Camelot
    let bpm: Double
}

struct Crate {
    let id: Int
    let parent: Int?
    let name: String
}

final class SeratoReader {
    let path = NSString(string: "~/Library/Application Support/Serato/Library/master.sqlite").expandingTildeInPath
    private var lastStamp = ""
    private var cachedDecks: [Deck]? = nil
    private var libraryStamp = ""
    private var libraryCache: [Int: [LibraryTrack]] = [:]   // crate id (0 = whole library) -> tracks

    /// Serato appends to the write-ahead log on every change, so a cheap look at the
    /// sizes and modification times of the database files tells us whether anything can
    /// have changed since the last query. Most seconds nothing has, and we skip the query.
    func stamp() -> String {
        var s = ""
        for suffix in ["", "-wal"] {
            if let a = try? FileManager.default.attributesOfItem(atPath: path + suffix) {
                s += "\((a[.size] as? Int) ?? 0):\(((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0));"
            }
        }
        return s
    }

    func decksIfChanged() -> [Deck]? {
        let s = stamp()
        if s == lastStamp { return cachedDecks }
        lastStamp = s
        cachedDecks = decks()
        return cachedDecks
    }

    private func open() -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 250)
        return db
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
    }

    /// The track currently loaded on each deck: the newest history entry per deck whose
    /// end_time is still -1 (Serato sets it when the deck is cleared or reloaded).
    func decks() -> [Deck]? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT deck, name, key, bpm, start_time FROM history_entry
             WHERE end_time = -1
               AND id IN (SELECT MAX(id) FROM history_entry WHERE end_time = -1 GROUP BY deck)
             ORDER BY deck
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [Deck] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Deck(number: Int(sqlite3_column_int(stmt, 0)), name: text(stmt, 1), key: text(stmt, 2),
                            bpm: sqlite3_column_double(stmt, 3), startTime: sqlite3_column_double(stmt, 4)))
        }
        return out
    }

    /// All crates in the "Serato Library" space, with their parent for building paths.
    func crates() -> [Crate] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT id, parent_id, name FROM container
             WHERE type = 1 AND space_id = (SELECT id FROM space WHERE name = 'Serato Library')
             ORDER BY parent_id, list_order
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Crate] = []
        let rootId = rootContainerId(db)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let parent = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 1))
            out.append(Crate(id: Int(sqlite3_column_int(stmt, 0)), parent: parent == rootId ? nil : parent, name: text(stmt, 2)))
        }
        return out
    }

    private func rootContainerId(_ db: OpaquePointer) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM container WHERE name = 'Serato Library root' AND type = 0", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : nil
    }

    /// Local tracks with a readable key, from one crate (id) or the whole library (0).
    func tracks(inCrate crateId: Int) -> [LibraryTrack] {
        let s = stamp()
        if s != libraryStamp { libraryStamp = s; libraryCache = [:] }
        if let c = libraryCache[crateId] { return c }
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        let sql = crateId == 0
            ? "SELECT a.id, a.name, a.artist, a.key, a.bpm FROM asset a WHERE a.location_id = 1 AND a.key != '' AND a.is_missing = 0"
            : """
              SELECT a.id, a.name, a.artist, a.key, a.bpm FROM asset a
                JOIN container_asset ca ON ca.asset_id = a.id
                JOIN location_container lc ON lc.id = ca.location_container_id
               WHERE lc.container_id = ? AND a.key != '' AND a.is_missing = 0
               ORDER BY ca.list_order
              """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if crateId != 0 { sqlite3_bind_int(stmt, 1, Int32(crateId)) }
        var out: [LibraryTrack] = []
        var seen = Set<Int>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(stmt, 0))
            guard !seen.contains(id), let cam = Camelot.parse(text(stmt, 3)) else { continue }
            seen.insert(id)
            out.append(LibraryTrack(id: id, name: text(stmt, 1), artist: text(stmt, 2), key: cam, bpm: sqlite3_column_double(stmt, 4)))
        }
        libraryCache[crateId] = out
        return out
    }
}

func seratoRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Serato DJ Pro" || $0.bundleIdentifier == "com.serato.seratodj" }
}

// MARK: - UI pieces

enum Notation: Int { case both = 0, camelot = 1, standard = 2 }

func keyColor(_ c: Camelot) -> NSColor {
    let (r, g, b) = c.rgb
    return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

func keyText(_ c: Camelot, _ notation: Notation) -> String {
    switch notation {
    case .camelot: return c.label
    case .standard: return c.standard
    case .both: return "\(c.label) \(c.standard)"
    }
}

/// Draws one key "chip": a rounded rectangle in the key's colour with dark or white text.
func drawChip(_ text: String, color: NSColor, at x: CGFloat, centerY: CGFloat, fontSize: CGFloat, highlight: Bool = false) -> CGFloat {
    let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
    let c = color.usingColorSpace(.sRGB) ?? color
    let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    let ink: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: luminance > 0.55 ? NSColor(white: 0.08, alpha: 1) : NSColor.white]
    let sz = (text as NSString).size(withAttributes: ink)
    let padX = fontSize * 0.6, padY = fontSize * 0.2
    let rect = NSRect(x: x, y: centerY - sz.height / 2 - padY, width: sz.width + 2 * padX, height: sz.height + 2 * padY)
    let path = NSBezierPath(roundedRect: rect, xRadius: fontSize * 0.45, yRadius: fontSize * 0.45)
    color.setFill()
    path.fill()
    if highlight {
        NSColor.white.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
    (text as NSString).draw(at: NSPoint(x: x + padX, y: centerY - sz.height / 2), withAttributes: ink)
    return rect.width
}

/// A row of key chips with optional dim prefix/suffix text.
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
            x += drawChip(chip.text, color: chip.color, at: x, centerY: h / 2, fontSize: fontSize, highlight: chip.highlight) + fontSize * 0.55
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

    /// A green that is none of Serato's key greens (1A mint, 2A/3A yellow-greens).
    static let matchGreen = NSColor(srgbRed: 0.0, green: 1.0, blue: 0.35, alpha: 1)

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

    func show(_ deck: Deck, notation: Notation, fits: Bool, isReference: Bool) {
        let cam = Camelot.parse(deck.key)
        head.prefix = isReference ? "\(deck.number) ▸" : "\(deck.number)"
        head.prefixColor = fits ? DeckRow.matchGreen : nil
        head.suffix = deck.bpm > 0 ? String(format: "%.1f", deck.bpm) : ""
        track.stringValue = deck.name
        if let c = cam {
            head.chips = [ChipsView.Chip(text: keyText(c, notation), color: keyColor(c), highlight: false)]
            keys.prefix = "➜"
            keys.chips = c.compatible.map { ChipsView.Chip(text: keyText($0, notation), color: keyColor($0), highlight: $0 == c) }
        } else {
            head.chips = [ChipsView.Chip(text: deck.key.isEmpty ? "ingen toneart" : deck.key, color: NSColor(white: 0.75, alpha: 1), highlight: false)]
            keys.prefix = ""
            keys.chips = []
        }
    }
}

/// One line in the list of matching tracks: key chip, BPM, artist - title.
final class MatchCellView: NSView {
    var track: LibraryTrack?
    var notation: Notation = .camelot
    var scale: CGFloat = 1
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = track else { return }
        let fs = 12.5 * scale
        var x: CGFloat = 4 * scale
        x += drawChip(keyText(t.key, notation == .both ? .camelot : notation), color: keyColor(t.key), at: x, centerY: bounds.height / 2, fontSize: fs) + 8 * scale
        let mono = NSFont.monospacedDigitSystemFont(ofSize: fs, weight: .semibold)
        let bpm = t.bpm > 0 ? String(format: "%.1f", t.bpm) : "—"
        let bpmAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor(white: 1, alpha: 0.6)]
        let bsz = (bpm as NSString).size(withAttributes: bpmAttrs)
        (bpm as NSString).draw(at: NSPoint(x: x, y: (bounds.height - bsz.height) / 2), withAttributes: bpmAttrs)
        x += 44 * scale
        let title = t.artist.isEmpty ? t.name : "\(t.artist) – \(t.name)"
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fs, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: style]
        let tsz = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(in: NSRect(x: x, y: (bounds.height - tsz.height) / 2, width: bounds.width - x - 4 * scale, height: tsz.height + 2), withAttributes: attrs)
    }
}

final class ClickableTable: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // a click works without focusing the panel first
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let panel: NSPanel
    let content = NSView()
    let status = NSTextField(labelWithString: "")
    var rows: [DeckRow] = []
    var statusItem: NSStatusItem?
    let reader = SeratoReader()
    let defaults = UserDefaults.standard

    // settings
    var notation: Notation
    var scale: CGFloat
    var followSerato: Bool                    // show the panel only while Serato is running
    var showMatches: Bool
    var crateId: Int                          // 0 = whole library
    var bpmTolerance: Double                  // percent, 0 = any BPM
    var referenceMode: Int                    // 0 = the deck that has been playing longest, 1-4 = that deck

    // matches section
    let matchHeader = NSTextField(labelWithString: "")
    let search = NSSearchField()
    let scroll = NSScrollView()
    let table = ClickableTable()
    var matches: [LibraryTrack] = []
    var filtered: [LibraryTrack] = []
    var crateNames: [Int: String] = [:]
    var copiedUntil = Date.distantPast

    var seratoWasRunning = false
    var lastSignature = ""
    var currentDecks: [Deck] = []
    var width: CGFloat { 360 * scale }

    override init() {
        notation = Notation(rawValue: defaults.integer(forKey: "notation")) ?? .both
        let s = defaults.double(forKey: "scale")
        scale = s > 0 ? CGFloat(s) : 1.0
        followSerato = defaults.object(forKey: "followSerato") == nil ? true : defaults.bool(forKey: "followSerato")
        showMatches = defaults.bool(forKey: "showMatches")
        crateId = defaults.integer(forKey: "crateId")
        bpmTolerance = defaults.object(forKey: "bpmTolerance") == nil ? 6 : defaults.double(forKey: "bpmTolerance")
        referenceMode = defaults.integer(forKey: "referenceMode")
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
        panel.becomesKeyOnlyIfNeeded = true            // only the search field ever takes the keyboard
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

        matchHeader.textColor = NSColor(white: 1, alpha: 0.6)
        matchHeader.isEditable = false; matchHeader.isBordered = false; matchHeader.drawsBackground = false
        matchHeader.lineBreakMode = .byTruncatingTail
        search.placeholderString = "søg titel eller artist"
        search.delegate = self
        search.focusRingType = .none
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("m"))
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        for v in [matchHeader, search, scroll] as [NSView] { v.isHidden = true; content.addSubview(v) }

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
        statusItem = item
        rebuildMenus()

        seratoWasRunning = seratoRunning()
        refresh(force: true)
        if !(followSerato && !seratoWasRunning) { panel.orderFrontRegardless() }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refresh(force: false) }
    }

    // MARK: menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ m: NSMenu, _ title: String, _ sel: Selector, key: String = "", on: Bool = false, tag: Int = 0) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.target = self
            it.state = on ? .on : .off
            it.tag = tag
            m.addItem(it)
        }
        add(menu, "Skjul panel (vis igen fra ♪ i menulinjen)", #selector(toggle))
        menu.addItem(.separator())
        add(menu, "Vis matchende numre", #selector(toggleMatches), on: showMatches)
        let crateMenu = NSMenu()
        add(crateMenu, "Hele biblioteket", #selector(pickCrate), on: crateId == 0, tag: 0)
        crateMenu.addItem(.separator())
        buildCrateMenu(into: crateMenu)
        let crateItem = NSMenuItem(title: "Crate", action: nil, keyEquivalent: "")
        crateItem.submenu = crateMenu
        menu.addItem(crateItem)
        let bpmMenu = NSMenu()
        for (title, pct) in [("± 3 %", 3.0), ("± 6 %", 6.0), ("± 8 %", 8.0), ("± 12 %", 12.0), ("Alle BPM", 0.0)] {
            add(bpmMenu, title, #selector(pickBpm), on: bpmTolerance == pct, tag: Int(pct * 10))
        }
        let bpmItem = NSMenuItem(title: "BPM-område", action: nil, keyEquivalent: "")
        bpmItem.submenu = bpmMenu
        menu.addItem(bpmItem)
        let refMenu = NSMenu()
        add(refMenu, "Det deck der har spillet længst", #selector(pickReference), on: referenceMode == 0, tag: 0)
        for d in 1...4 { add(refMenu, "Deck \(d)", #selector(pickReference), on: referenceMode == d, tag: d) }
        let refItem = NSMenuItem(title: "Match mod", action: nil, keyEquivalent: "")
        refItem.submenu = refMenu
        menu.addItem(refItem)
        menu.addItem(.separator())
        add(menu, "Camelot + standard", #selector(setBoth), on: notation == .both)
        add(menu, "Kun Camelot (8A)", #selector(setCamelot), on: notation == .camelot)
        add(menu, "Kun standard (Am)", #selector(setStandard), on: notation == .standard)
        menu.addItem(.separator())
        add(menu, "Lille", #selector(setSmall), on: scale < 0.95)
        add(menu, "Mellem", #selector(setMedium), on: scale >= 0.95 && scale <= 1.05)
        add(menu, "Stor", #selector(setLarge), on: scale > 1.05)
        menu.addItem(.separator())
        add(menu, "Vis kun mens Serato kører", #selector(toggleFollow), on: followSerato)
        add(menu, "Start ved login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add(menu, "Afslut keylight", #selector(quit), key: "q")
        return menu
    }

    /// Crates as nested submenus mirroring Serato's tree.
    func buildCrateMenu(into menu: NSMenu) {
        let crates = reader.crates()
        crateNames = [:]
        var children: [Int?: [Crate]] = [:]
        for c in crates { children[c.parent, default: []].append(c) }
        func path(_ c: Crate) -> String {
            var parts = [c.name]
            var p = c.parent
            var guardCount = 0
            while let pid = p, let pc = crates.first(where: { $0.id == pid }), guardCount < 20 { parts.insert(pc.name, at: 0); p = pc.parent; guardCount += 1 }
            return parts.joined(separator: " / ")
        }
        for c in crates { crateNames[c.id] = path(c) }
        func fill(_ m: NSMenu, parent: Int?) {
            for c in children[parent] ?? [] {
                let kids = children[c.id] ?? []
                let it = NSMenuItem(title: c.name, action: #selector(pickCrate), keyEquivalent: "")
                it.target = self
                it.tag = c.id
                it.state = crateId == c.id ? .on : .off
                if !kids.isEmpty {
                    let sub = NSMenu()
                    let selfItem = NSMenuItem(title: "\(c.name) (selve craten)", action: #selector(pickCrate), keyEquivalent: "")
                    selfItem.target = self
                    selfItem.tag = c.id
                    selfItem.state = crateId == c.id ? .on : .off
                    sub.addItem(selfItem)
                    sub.addItem(.separator())
                    fill(sub, parent: c.id)
                    it.submenu = sub
                    it.action = nil
                }
                m.addItem(it)
            }
        }
        fill(menu, parent: nil)
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
    @objc func toggleMatches() { showMatches.toggle(); defaults.set(showMatches, forKey: "showMatches"); rebuildMenus(); refresh(force: true) }
    @objc func pickCrate(_ sender: NSMenuItem) { crateId = sender.tag; defaults.set(crateId, forKey: "crateId"); rebuildMenus(); refresh(force: true) }
    @objc func pickBpm(_ sender: NSMenuItem) { bpmTolerance = Double(sender.tag) / 10; defaults.set(bpmTolerance, forKey: "bpmTolerance"); rebuildMenus(); refresh(force: true) }
    @objc func pickReference(_ sender: NSMenuItem) { referenceMode = sender.tag; defaults.set(referenceMode, forKey: "referenceMode"); rebuildMenus(); refresh(force: true) }

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

    // MARK: matches

    func referenceDeck(in shown: [Deck]) -> Deck? {
        if referenceMode > 0 { return shown.first { $0.number == referenceMode } }
        return shown.min { $0.startTime < $1.startTime }
    }

    func computeMatches(reference: Deck?, loaded: [Deck]) {
        matches = []
        guard showMatches, let ref = reference, let cam = Camelot.parse(ref.key) else { applyFilter(); return }
        let compatible = cam.compatible
        let loadedNames = Set(loaded.map { $0.name })
        var list = reader.tracks(inCrate: crateId).filter { t in
            compatible.contains(t.key) && !loadedNames.contains(t.name)
                && (bpmTolerance == 0 || ref.bpm <= 0 || t.bpm <= 0 || abs(t.bpm - ref.bpm) / ref.bpm * 100 <= bpmTolerance)
        }
        func rank(_ k: Camelot) -> Int { k == cam ? 0 : (k.number == cam.number ? 1 : 2) }   // same key, relative, neighbours
        list.sort { a, b in
            let ra = rank(a.key), rb = rank(b.key)
            if ra != rb { return ra < rb }
            let da = abs(a.bpm - ref.bpm), db = abs(b.bpm - ref.bpm)
            if da != db { return da < db }
            return a.name < b.name
        }
        matches = list
        applyFilter()
    }

    func applyFilter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = q.isEmpty ? matches : matches.filter { $0.name.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter(); layoutPanel() }

    @objc func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < filtered.count else { return }
        let t = filtered[row]
        let text = t.artist.isEmpty ? t.name : "\(t.artist) \(t.name)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedUntil = Date().addingTimeInterval(2.5)
        updateMatchHeader()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.updateMatchHeader() }
    }

    func updateMatchHeader() {
        matchHeader.font = NSFont.systemFont(ofSize: 11.5 * scale, weight: .medium)
        if Date() < copiedUntil {
            matchHeader.stringValue = "Kopieret – sæt ind i Seratos søgefelt"
            matchHeader.textColor = DeckRow.matchGreen
            return
        }
        matchHeader.textColor = NSColor(white: 1, alpha: 0.6)
        let crate = crateId == 0 ? "hele biblioteket" : (crateNames[crateId] ?? "crate")
        let ref = referenceDeck(in: currentDecks)
        let bpm = bpmTolerance == 0 ? "alle BPM" : String(format: "±%g %%", bpmTolerance)
        if let r = ref {
            matchHeader.stringValue = "Passer til deck \(r.number) · \(bpm) · \(crate) · \(filtered.count) numre"
        } else {
            matchHeader.stringValue = "Load et nummer, så vises det, der passer · \(crate)"
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 * scale }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? MatchCellView) ?? { let c = MatchCellView(); c.identifier = id; return c }()
        cell.track = filtered[row]
        cell.notation = notation
        cell.scale = scale
        cell.needsDisplay = true
        return cell
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

        let signature = (decks ?? []).map { "\($0.number)|\($0.name)|\($0.key)|\($0.bpm)" }.joined(separator: ";")
            + "|\(running)|\(notation.rawValue)|\(scale)|\(showMatches)|\(crateId)|\(bpmTolerance)|\(referenceMode)"
        if !force && signature == lastSignature { return }
        lastSignature = signature

        let shown = (decks ?? []).filter { !$0.name.isEmpty }
        currentDecks = shown
        while rows.count < shown.count { rows.append(DeckRow(scale: scale)) }
        while rows.count > shown.count { rows.removeLast().remove() }

        // A deck number turns green when its key fits at least one other loaded deck.
        let keys = shown.map { Camelot.parse($0.key) }
        let fits: [Bool] = keys.indices.map { i in
            guard let a = keys[i] else { return false }
            return keys.indices.contains { j in j != i && keys[j].map { a.compatible.contains($0) } == true }
        }
        let ref = referenceDeck(in: shown)
        for (i, (row, deck)) in zip(rows, shown).enumerated() {
            row.show(deck, notation: notation, fits: fits[i], isReference: showMatches && ref?.number == deck.number && shown.count > 1)
        }
        computeMatches(reference: ref, loaded: shown)
        status.font = NSFont.systemFont(ofSize: 13 * scale, weight: .medium)
        status.stringValue = decks == nil ? "Serato-bibliotek ikke fundet" : (running ? "Intet nummer på decks" : "Serato kører ikke")
        status.isHidden = !shown.isEmpty
        layoutPanel()
    }

    /// Size the panel to its content (growing downwards from the top edge the user chose)
    /// and place every piece.
    func layoutPanel() {
        let shown = currentDecks
        let rowH = 92 * scale
        let statusHeight: CGFloat = shown.isEmpty ? 40 * scale : 0
        let listRowH = 26 * scale
        var listRows = 0
        var listHeight: CGFloat = 0
        if showMatches {
            let maxByScreen = Int(((NSScreen.main?.visibleFrame.height ?? 900) * 0.55) / listRowH)
            listRows = max(3, min(12, maxByScreen, max(filtered.count, 1)))
            listHeight = 24 * scale + 30 * scale + CGFloat(listRows) * listRowH + 10 * scale
        }
        let height = CGFloat(shown.count) * rowH + statusHeight + listHeight + 12 * scale
        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = topEdge - height
        panel.setFrame(frame, display: true)

        var top = height - 8 * scale
        for row in rows {
            row.layout(in: content, top: top, width: width)
            top -= rowH
        }
        if !shown.isEmpty { status.isHidden = true } else {
            status.frame = NSRect(x: 16 * scale, y: height - 34 * scale, width: width - 32 * scale, height: 20 * scale)
            top -= statusHeight
        }
        matchHeader.isHidden = !showMatches
        search.isHidden = !showMatches
        scroll.isHidden = !showMatches
        if showMatches {
            let x = 16 * scale
            updateMatchHeader()
            matchHeader.frame = NSRect(x: x, y: top - 22 * scale, width: width - 2 * x, height: 18 * scale)
            search.frame = NSRect(x: x, y: top - 50 * scale, width: width - 2 * x, height: 24 * scale)
            search.font = NSFont.systemFont(ofSize: 12 * scale)
            scroll.frame = NSRect(x: x - 4 * scale, y: top - 54 * scale - CGFloat(listRows) * listRowH, width: width - 2 * x + 8 * scale, height: CGFloat(listRows) * listRowH)
            table.rowHeight = 24 * scale
            table.tableColumns.first?.width = scroll.frame.width - 4
            table.reloadData()
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
