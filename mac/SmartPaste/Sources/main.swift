import Foundation
import AppKit
import Carbon
import ApplicationServices
import CoreGraphics

// MARK: - Models

enum ContentType: String {
    case url
    case html
    case table
    case code
    case plain
}

struct DestinationContext {
    let bundleId: String
}

struct ClipboardData {
    let plain: String?
    let html: String?
}

// MARK: - Utilities

func frontmostAppBundleID() -> String {
    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown.app"
}

func readClipboard() -> ClipboardData {
    let pb = NSPasteboard.general
    let plain = pb.string(forType: .string)
    let html = pb.string(forType: .html)
    return ClipboardData(plain: plain, html: html)
}

// MARK: - Classification

func isLikelyURL(_ text: String) -> Bool {
    let pattern = "^(https?|ftp)://[\\w.-]+(?:\\.[\\w.-]+)+(?:[/?#][^\\s]*)?$"
    if let _ = text.range(of: pattern, options: .regularExpression) {
        return true
    }
    // Also catch bare domains with optional path
    let bare = "^[\\w.-]+\\.[a-zA-Z]{2,}(?:/[^\\s]*)?$"
    return text.range(of: bare, options: .regularExpression) != nil
}

func detectTable(inPlain text: String) -> Bool {
    let lines = text.split(separator: "\n").map(String.init)
    guard lines.count >= 2 else { return false }
    // Heuristics: tab/comma/pipe separated with consistent column count
    let delimiters: [Character] = ["\t", ",", "|"]
    for delim in delimiters {
        let counts = lines.map { $0.split(separator: delim).count }
        if let first = counts.first, first > 1, counts.allSatisfy({ $0 == first }) {
            return true
        }
    }
    return false
}

func classifyClipboard(_ clip: ClipboardData) -> ContentType {
    if let html = clip.html, html.lowercased().contains("<table") {
        return .table
    }
    if let plain = clip.plain?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
        if isLikelyURL(plain) { return .url }
        if detectTable(inPlain: plain) { return .table }
        if looksLikeCode(plain) { return .code }
        if clip.html != nil { return .html }
        return .plain
    }
    if clip.html != nil { return .html }
    return .plain
}

func looksLikeCode(_ text: String) -> Bool {
    let hasBraces = text.contains("{") || text.contains("}")
    let hasSemicolons = text.contains(";")
    let hasKeywords = [
        "func ", "class ", "struct ", "import ", "public ", "private ",
        "def ", "for ", "if ", "var ", "let ", "const ", "#include"
    ].contains(where: { text.contains($0) })
    let hasIndent = text.split(separator: "\n").contains(where: { $0.hasPrefix("  ") || $0.hasPrefix("\t") })
    let hasMultiline = text.contains("\n")
    return (hasBraces || hasSemicolons || hasKeywords || hasIndent) && hasMultiline
}

// MARK: - Transforms

func stripURLTrackers(_ raw: String) -> String {
    guard var components = URLComponents(string: raw) else { return raw }
    let blacklist: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "gclid", "fbclid", "mc_cid", "mc_eid", "igshid", "si"
    ]
    if let queryItems = components.queryItems {
        components.queryItems = queryItems.filter { !blacklist.contains($0.name.lowercased()) && !($0.value ?? "").isEmpty }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
    }
    return components.string ?? raw
}

func htmlToPlainText(_ html: String) -> String {
    // Very basic HTML→text: remove tags, collapse whitespace, decode a few entities
    var s = html
    s = s.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "(?i)</p>", with: "\n\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "
    ]
    for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
    let components = s.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
    return components.joined(separator: " ")
}

func detectLanguage(forCode text: String) -> String {
    if text.contains("#!/usr/bin/env python") || (text.contains("def ") && text.contains(":\n")) { return "python" }
    if text.contains("import ") && text.contains(" from ") { return "python" }
    if text.contains("console.log") || text.contains("function ") || text.contains("=>") { return "javascript" }
    if text.contains("#include") || text.contains("int main") { return "c" }
    if text.contains("public static void main") { return "java" }
    if text.contains("struct ") && text.contains("{") { return "swift" }
    return ""
}

func toFencedCodeBlock(_ text: String) -> String {
    let lang = detectLanguage(forCode: text)
    let fence = lang.isEmpty ? "```\n" : "```\(lang)\n"
    var body = text
    // Normalize indentation lightly: replace tabs with two spaces
    body = body.replacingOccurrences(of: "\t", with: "  ")
    // Ensure trailing newline
    if !body.hasSuffix("\n") { body += "\n" }
    return fence + body + "```"
}

func htmlTableToCSV(_ html: String) -> String? {
    // Extremely small HTML table walker using regex; handles <tr><td>/<th>
    let lower = html.replacingOccurrences(of: "\n", with: " ").lowercased()
    guard lower.contains("<table") else { return nil }
    let rowRegex = try! NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: [.dotMatchesLineSeparators, .caseInsensitive])
    let cellRegex = try! NSRegularExpression(pattern: "<(td|th)[^>]*>(.*?)</(td|th)>", options: [.dotMatchesLineSeparators, .caseInsensitive])
    let ns = lower as NSString
    let rowMatches = rowRegex.matches(in: lower, range: NSRange(location: 0, length: ns.length))
    var rows: [[String]] = []
    for row in rowMatches {
        let rowContentRange = row.range(at: 1)
        guard rowContentRange.location != NSNotFound else { continue }
        let rowContent = ns.substring(with: rowContentRange)
        let rowNS = rowContent as NSString
        let cellMatches = cellRegex.matches(in: rowContent, range: NSRange(location: 0, length: rowNS.length))
        var cells: [String] = []
        for cell in cellMatches {
            let cellRange = cell.range(at: 2)
            if cellRange.location == NSNotFound { continue }
            var cellHTML = rowNS.substring(with: cellRange)
            // Strip any remaining tags and decode a few entities
            cellHTML = cellHTML.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let entities: [String: String] = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
            for (k, v) in entities { cellHTML = cellHTML.replacingOccurrences(of: k, with: v) }
            let cleaned = cellHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            cells.append(cleanCSVField(cleaned))
        }
        if !cells.isEmpty { rows.append(cells) }
    }
    guard !rows.isEmpty else { return nil }
    return rows.map { $0.joined(separator: ",") }.joined(separator: "\n")
}

func cleanCSVField(_ s: String) -> String {
    if s.contains(",") || s.contains("\n") || s.contains("\"") {
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
    return s
}

func plainTableToCSV(_ text: String) -> String? {
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2 else { return nil }
    let delimiters: [Character] = ["\t", ",", "|"]
    for delim in delimiters {
        let split = lines.map { $0.split(separator: delim).map(String.init) }
        let counts = split.map { $0.count }
        if let first = counts.first, first > 1, counts.allSatisfy({ $0 == first }) {
            // Normalize and escape fields
            let rows = split.map { row in row.map { cleanCSVField($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ",") }
            return rows.joined(separator: "\n")
        }
    }
    return nil
}

// MARK: - Paste Injection

struct PasteboardBackup {
    let plain: String?
    let html: String?
}

func backupPasteboard() -> PasteboardBackup {
    let pb = NSPasteboard.general
    return PasteboardBackup(plain: pb.string(forType: .string), html: pb.string(forType: .html))
}

func restorePasteboard(_ backup: PasteboardBackup) {
    let pb = NSPasteboard.general
    pb.clearContents()
    if let h = backup.html {
        pb.setString(h, forType: .html)
    }
    if let s = backup.plain {
        pb.setString(s, forType: .string)
    }
}

func setPasteboardString(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
}

func sendCmdV() {
    let vKey: CGKeyCode = 9 // 'v'
    guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false) else {
        fputs("Failed to create CGEvent for Cmd+V\n", stderr)
        return
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    usleep(10_000) // 10ms
    keyUp.post(tap: .cghidEventTap)
}

// MARK: - Accessibility (AX) Helpers

func isAccessibilityTrusted() -> Bool {
    return AXIsProcessTrusted()
}

func axFocusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
    if err != .success { return nil }
    guard let ref = focusedRef else { return nil }
    return unsafeDowncast(ref as AnyObject, to: AXUIElement.self)
}

func axTryInsertText(_ text: String) -> (ok: Bool, message: String) {
    guard isAccessibilityTrusted() else { return (false, "AX not trusted") }
    guard let element = axFocusedElement() else { return (false, "No focused element") }

    // Try setting AXValue first (replaces field contents)
    let setErr = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
    if setErr == .success {
        return (true, "AX set value")
    }

    // If set fails, try fetching current value and append
    var existingValueRef: CFTypeRef?
    let getErr = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &existingValueRef)
    if getErr == .success, let existing = existingValueRef as? String {
        let setErr2 = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, (existing + text) as CFTypeRef)
        if setErr2 == .success {
            return (true, "AX append value")
        } else {
            return (false, "AX set/append failed: \(setErr2.rawValue)")
        }
    }

    return (false, "AX get/set failed: \(setErr.rawValue)")
}

func ensureAccessibilityPermission() {
    // Use literal key to avoid concurrency-unsafe global var in Swift 6
    let promptKey: CFString = "AXTrustedCheckOptionPrompt" as CFString
    let options: CFDictionary = [promptKey: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    if !trusted {
        fputs("SmartPaste requires Accessibility permission to send Cmd+V. Grant it in System Settings → Privacy & Security → Accessibility.\n", stderr)
    }
}

// MARK: - Recipe Selection

func chooseTransform(content: ContentType, ctx: DestinationContext) -> String {
    switch content {
    case .url:
        return "smart-link"
    case .table:
        // Prefer CSV for spreadsheet apps
        if ctx.bundleId == "com.microsoft.Excel" { return "table-csv" }
        return "table-csv"
    case .code:
        return "code-fence"
    case .html:
        return "plain"
    case .plain:
        return "plain"
    }
}

func runTransform(named: String, clip: ClipboardData) -> String? {
    switch named {
    case "smart-link":
        if let p = clip.plain?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return stripURLTrackers(p)
        }
        if let h = clip.html {
            let text = htmlToPlainText(h)
            if isLikelyURL(text) { return stripURLTrackers(text) }
        }
        return clip.plain
    case "table-csv":
        if let h = clip.html, let csv = htmlTableToCSV(h) { return csv }
        if let p = clip.plain, let csv = plainTableToCSV(p) { return csv }
        return clip.plain
    case "code-fence":
        if let p = clip.plain { return toFencedCodeBlock(p) }
        if let h = clip.html { return toFencedCodeBlock(htmlToPlainText(h)) }
        return nil
    case "plain":
        if let h = clip.html { return htmlToPlainText(h) }
        return clip.plain
    default:
        return clip.plain
    }
}

// MARK: - Hotkey Registration (⌘⇧V)

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_: EventHandlerCallRef?, eventRef: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus in
            guard let eventRef = eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.id == 1 {
                onSmartPaste()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        let keyCode: UInt32 = 9 // 'v'
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let hotKeyID = EventHotKeyID(signature: OSType(UInt32(bigEndian: 0x53504B31)), id: 1) // 'SPK1'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        print("SmartPaste hotkey registered: ⌘⇧V")
    }

    deinit {
        if let hk = hotKeyRef { UnregisterEventHotKey(hk) }
        if let eh = eventHandler { RemoveEventHandler(eh) }
    }
}

// MARK: - Core Flow

func onSmartPaste() {
    let ctx = DestinationContext(bundleId: frontmostAppBundleID())
    let clip = readClipboard()
    let cType = classifyClipboard(clip)
    let recipe = chooseTransform(content: cType, ctx: ctx)
    guard let out = runTransform(named: recipe, clip: clip), !out.isEmpty else {
        print("SmartPaste: nothing to do (empty transform)")
        return
    }

    let backup = backupPasteboard()
    setPasteboardString(out)

    var delivered = false
    var deliveryNote = ""

    // Try AX injection first for reliability
    let axResult = axTryInsertText(out)
    if axResult.ok {
        delivered = true
        deliveryNote = axResult.message
    } else if isAccessibilityTrusted() {
        sendCmdV()
        delivered = true
        deliveryNote = "CGEvent Cmd+V"
    } else {
        deliveryNote = "No Accessibility permission (AX: \(axResult.message))"
        print("SmartPaste: Accessibility not granted; unable to send Cmd+V · AX: \(axResult.message)")
    }

    // Restore pasteboard shortly after to avoid clobbering user's clipboard
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
        restorePasteboard(backup)
    }

    print("SmartPaste: \(cType.rawValue) → \(recipe) · \(out.count) chars · Delivered: \(delivered ? deliveryNote : "failed")")
}

// MARK: - Menu Bar Status Item

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let accessibilityStatusItem: NSMenuItem

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        self.menu.autoenablesItems = false
        self.accessibilityStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "SmartPaste")
            } else {
                button.title = "SP"
            }
            button.toolTip = "SmartPaste — ⌘⇧V"
        }

        let header = NSMenuItem(title: "SmartPaste Running (⌘⇧V)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        accessibilityStatusItem.isEnabled = false
        menu.addItem(accessibilityStatusItem)
        menu.addItem(NSMenuItem.separator())
        let openAccessibility = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        openAccessibility.target = self
        openAccessibility.isEnabled = true
        menu.addItem(openAccessibility)
        let openInputMonitoring = NSMenuItem(title: "Open Input Monitoring…", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        openInputMonitoring.target = self
        openInputMonitoring.isEnabled = true
        menu.addItem(openInputMonitoring)
        let copyDebug = NSMenuItem(title: "Copy Debug Info", action: #selector(copyDebugInfo), keyEquivalent: "d")
        copyDebug.target = self
        copyDebug.isEnabled = true
        menu.addItem(copyDebug)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit SmartPaste", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem.menu = menu
        refreshAccessibilityStatus()
        // Periodically refresh AX status (toggling often requires a moment)
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if let s = self {
                Task { @MainActor in
                    s.refreshAccessibilityStatus()
                }
            }
        }
    }

    private func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        accessibilityStatusItem.title = trusted ? "Accessibility: Granted" : "Accessibility: Not Granted"
    }

    @MainActor @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @MainActor @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor @objc private func copyDebugInfo() {
        var lines: [String] = []
        lines.append("AXIsProcessTrusted: \(isAccessibilityTrusted())")
        lines.append("Frontmost bundle: \(frontmostAppBundleID())")
        if let el = axFocusedElement() {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef)
            let role = (roleRef as? String) ?? "(unknown)"
            let subrole = (subroleRef as? String) ?? "(none)"
            lines.append("Focused role: \(role) subrole: \(subrole)")
        } else {
            lines.append("Focused element: (none)")
        }
        let debug = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(debug, forType: .string)
    }
}

// MARK: - Entry

ensureAccessibilityPermission()

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // hide dock icon, show only status item

let hk = HotKeyManager()
hk.register()

// Keep a strong reference so menu items remain enabled
var statusController: StatusItemController? = StatusItemController()
app.run()
