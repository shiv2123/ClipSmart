import Foundation
import AppKit
import Carbon
import ApplicationServices
import CoreGraphics
// Notifications temporarily disabled for CLI-run; no import of UserNotifications

// MARK: - Models

enum ContentType: String {
    case url
    case html
    case table
    case code
    case plain
}

// MARK: - Suggestions

@MainActor
final class SuggestionCenter: NSObject /*, UNUserNotificationCenterDelegate*/ {
    static let shared = SuggestionCenter()
    private override init() { super.init() }

    func requestAuthorization() {
        // Temporarily disabled for CLI-run to avoid UNUserNotificationCenter crash outside .app bundles
        fputs("SmartPaste: notifications disabled in this build.\n", stderr)
    }

    func notifySuggestion(_ message: String) {
        // Temporarily disabled; show in status menu only
        guard UserDefaults.standard.bool(forKey: "suggestionsEnabled") else { return }
        fputs("SmartPaste suggestion: \(message)\n", stderr)
    }
}

@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastNotificationAt: Date = .distantPast

    func start() {
        timer = Timer.scheduledTimer(timeInterval: 0.8, target: self, selector: #selector(handleTimer(_:)), userInfo: nil, repeats: true)
    }

    @objc private func handleTimer(_ timer: Timer) {
        tick()
    }

    private func tick() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        let clip = readClipboard()
        let cType = classifyClipboard(clip)
        let ctx = DestinationContext(bundleId: frontmostAppBundleID())
        let recipe = chooseTransform(content: cType, ctx: ctx)

        statusController?.updateSuggestion("Suggestion: ⌘⇧V → " + humanReadableTransform(recipe))

        // Notify sparingly (no more than once every 15s)
        let shouldNotify = UserDefaults.standard.bool(forKey: "suggestionsEnabled") && recipe != "plain" && Date().timeIntervalSince(lastNotificationAt) > 15
        if shouldNotify {
            lastNotificationAt = Date()
            SuggestionCenter.shared.notifySuggestion("Press ⌘⇧V to paste as " + humanReadableTransform(recipe))
        }
    }
}

func humanReadableTransform(_ name: String) -> String {
    switch name {
    case "smart-link": return "clean link"
    case "table-csv": return "CSV table"
    case "table-md": return "Markdown table"
    case "code-fence": return "code block"
    case "plain": return "plain text"
    case "bullets": return "bulleted list"
    case "one-line": return "one line"
    case "json-pretty": return "pretty JSON"
    default: return name
    }
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

func isRunningInAppBundle() -> Bool {
    let url = Bundle.main.bundleURL
    if url.pathExtension.lowercased() == "app" { return true }
    let infoPlist = url.appendingPathComponent("Contents/Info.plist")
    return FileManager.default.fileExists(atPath: infoPlist.path)
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

func isLikelyJSON(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else {
        return false
    }
    let data = Data(trimmed.utf8)
    return (try? JSONSerialization.jsonObject(with: data)) != nil
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

func toBulletedList(_ text: String) -> String {
    let lines = text.split(separator: "\n").map(String.init)
    let bullets = lines
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { "- \($0)" }
    return bullets.joined(separator: "\n")
}

func toOneLine(_ text: String) -> String {
    let components = text.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
    return components.joined(separator: " ")
}

func prettyPrintJSON(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
    guard let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return nil }
    return String(data: pretty, encoding: .utf8)
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

func htmlTableToRows(_ html: String) -> [[String]]? {
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
            cellHTML = cellHTML.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            let entities: [String: String] = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
            for (k, v) in entities { cellHTML = cellHTML.replacingOccurrences(of: k, with: v) }
            let cleaned = cellHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            cells.append(cleaned)
        }
        if !cells.isEmpty { rows.append(cells) }
    }
    return rows.isEmpty ? nil : rows
}

func extractTableRows(fromPlain text: String) -> [[String]]? {
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2 else { return nil }
    let delimiters: [Character] = ["\t", ",", "|"]
    for delim in delimiters {
        let split = lines.map { $0.split(separator: delim).map(String.init) }
        let counts = split.map { $0.count }
        if let first = counts.first, first > 1, counts.allSatisfy({ $0 == first }) {
            return split.map { row in row.map { $0.trimmingCharacters(in: .whitespaces) } }
        }
    }
    return nil
}

func parseCSV(_ csv: String) -> [[String]] {
    var rows: [[String]] = []
    var currentRow: [String] = []
    var currentField = ""
    var inQuotes = false
    var iterator = csv.makeIterator()
    while let ch = iterator.next() {
        if ch == "\"" {
            if inQuotes {
                if let peek = iterator.next() {
                    if peek == "\"" {
                        currentField.append("\"")
                    } else if peek == "," {
                        inQuotes = false
                        currentRow.append(currentField)
                        currentField = ""
                    } else if peek == "\n" { // end of field and row
                        inQuotes = false
                        currentRow.append(currentField)
                        rows.append(currentRow)
                        currentRow = []
                        currentField = ""
                    } else {
                        inQuotes = false
                        currentField.append(peek)
                    }
                } else {
                    inQuotes = false
                }
            } else {
                inQuotes = true
            }
        } else if ch == "," && !inQuotes {
            currentRow.append(currentField)
            currentField = ""
        } else if ch == "\n" && !inQuotes {
            currentRow.append(currentField)
            rows.append(currentRow)
            currentRow = []
            currentField = ""
        } else {
            currentField.append(ch)
        }
    }
    // Flush
    currentRow.append(currentField)
    if !currentRow.isEmpty { rows.append(currentRow) }
    // Trim possible trailing empty row
    if rows.last?.count == 1, rows.last?.first == "" { _ = rows.popLast() }
    return rows
}

func rowsToMarkdownTable(_ rows: [[String]]) -> String {
    guard !rows.isEmpty else { return "" }
    let columnCount = rows.first!.count
    var widths = Array(repeating: 3, count: columnCount)
    for row in rows {
        for (i, cell) in row.enumerated() {
            if i < widths.count { widths[i] = max(widths[i], cell.count) }
        }
    }
    func pad(_ s: String, to n: Int) -> String {
        if s.count >= n { return s }
        return s + String(repeating: " ", count: n - s.count)
    }
    let header = rows[0]
    let headerLine = "| " + header.enumerated().map { pad($0.element, to: widths[$0.offset]) }.joined(separator: " | ") + " |"
    let sepLine = "| " + widths.map { String(repeating: "-", count: max(3, $0)) }.joined(separator: " | ") + " |"
    let bodyLines: [String] = rows.dropFirst().map { row in
        let cells = (0..<columnCount).map { idx in idx < row.count ? row[idx] : "" }
        return "| " + cells.enumerated().map { pad($0.element, to: widths[$0.offset]) }.joined(separator: " | ") + " |"
    }
    return ([headerLine, sepLine] + bodyLines).joined(separator: "\n")
}

func tableToMarkdown(_ clip: ClipboardData) -> String? {
    if let h = clip.html, let rows = htmlTableToRows(h) { return rowsToMarkdownTable(rows) }
    if let p = clip.plain, let rows = extractTableRows(fromPlain: p) { return rowsToMarkdownTable(rows) }
    if let p = clip.plain, let csv = plainTableToCSV(p) { return rowsToMarkdownTable(parseCSV(csv)) }
    if let h = clip.html, let csv = htmlTableToCSV(h) { return rowsToMarkdownTable(parseCSV(csv)) }
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
        // Prefer Markdown for Markdown-first apps; CSV for spreadsheets; default CSV
        let b = ctx.bundleId.lowercased()
        if b.contains("excel") || b.contains("numbers") { return "table-csv" }
        if b.contains("notion") || b.contains("obsidian") || b.contains("bear") || b.contains("typora") || b.contains("markdown") || b.contains("notes") {
            return "table-md"
        }
        return "table-csv"
    case .code:
        return "code-fence"
    case .html:
        return "plain"
    case .plain:
        // Pretty print JSON if it looks like JSON
        if let p = readClipboard().plain, isLikelyJSON(p) { return "json-pretty" }
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
    case "table-md":
        if let md = tableToMarkdown(clip) { return md }
        return clip.plain
    case "code-fence":
        if let p = clip.plain { return toFencedCodeBlock(p) }
        if let h = clip.html { return toFencedCodeBlock(htmlToPlainText(h)) }
        return nil
    case "plain":
        if let h = clip.html { return htmlToPlainText(h) }
        return clip.plain
    case "bullets":
        if let p = clip.plain { return toBulletedList(p) }
        if let h = clip.html { return toBulletedList(htmlToPlainText(h)) }
        return nil
    case "one-line":
        if let p = clip.plain { return toOneLine(p) }
        if let h = clip.html { return toOneLine(htmlToPlainText(h)) }
        return nil
    case "json-pretty":
        if let p = clip.plain, let pretty = prettyPrintJSON(p) { return pretty }
        if let h = clip.html, let pretty = prettyPrintJSON(htmlToPlainText(h)) { return pretty }
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
            } else if hotKeyID.id == 2 {
                onQuickActionsHotkey()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        let keyCode: UInt32 = 9 // 'v'
        // Primary hotkey: ⌘⇧V
        let modifiers1: UInt32 = UInt32(cmdKey | shiftKey)
        let hotKeyID1 = EventHotKeyID(signature: OSType(UInt32(bigEndian: 0x53504B31)), id: 1) // 'SPK1'
        RegisterEventHotKey(keyCode, modifiers1, hotKeyID1, GetApplicationEventTarget(), 0, &hotKeyRef)
        // Secondary hotkey: ⌥⌘⇧V for Quick Actions
        let modifiers2: UInt32 = UInt32(cmdKey | shiftKey | optionKey)
        var hotKeyRef2: EventHotKeyRef?
        let hotKeyID2 = EventHotKeyID(signature: OSType(UInt32(bigEndian: 0x53504B32)), id: 2) // 'SPK2'
        RegisterEventHotKey(keyCode, modifiers2, hotKeyID2, GetApplicationEventTarget(), 0, &hotKeyRef2)
        print("SmartPaste hotkeys: ⌘⇧V (paste), ⌥⌘⇧V (quick actions)")
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

    // Always paste via Cmd+V (slight delay so hotkey modifiers are released)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        sendCmdV()
    }
    delivered = true
    deliveryNote = "CGEvent Cmd+V (delayed)"

    // Restore pasteboard shortly after to avoid clobbering user's clipboard
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
        restorePasteboard(backup)
    }

    print("SmartPaste: \(cType.rawValue) → \(recipe) · \(out.count) chars · Delivered: \(delivered ? deliveryNote : "failed")")
}

func onSmartPasteWithTransform(_ transform: String) {
    let clip = readClipboard()
    guard let out = runTransform(named: transform, clip: clip), !out.isEmpty else {
        print("SmartPaste: nothing to do (empty transform \(transform))")
        return
    }
    let backup = backupPasteboard()
    setPasteboardString(out)
    var delivered = false
    var deliveryNote = ""
    // Always paste via Cmd+V (slight delay so hotkey modifiers are released)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        sendCmdV()
    }
    delivered = true
    deliveryNote = "CGEvent Cmd+V (delayed)"
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
        restorePasteboard(backup)
    }
    print("SmartPaste: forced transform → \(transform) · \(out.count) chars · Delivered: \(delivered ? deliveryNote : "failed")")
}

func onQuickActionsHotkey() {
    let ctx = DestinationContext(bundleId: frontmostAppBundleID())
    let clip = readClipboard()
    let cType = classifyClipboard(clip)
    let recipe = chooseTransform(content: cType, ctx: ctx)
    DispatchQueue.main.async {
        statusController?.presentQuickActionsMenu(clip: clip, ctx: ctx, contentType: cType, recommended: recipe)
    }
}

// MARK: - Menu Bar Status Item

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let accessibilityStatusItem: NSMenuItem
    private let suggestionItem: NSMenuItem
    private let suggestionsToggleItem: NSMenuItem

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        self.menu.autoenablesItems = false
        self.accessibilityStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        self.suggestionItem = NSMenuItem(title: "Suggestion: (none)", action: nil, keyEquivalent: "")
        self.suggestionsToggleItem = NSMenuItem(title: "Show suggestions", action: #selector(toggleSuggestions), keyEquivalent: "")
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
        suggestionItem.isEnabled = false
        menu.addItem(suggestionItem)
        menu.addItem(NSMenuItem.separator())
        
        // Quick actions
        let pasteNow = NSMenuItem(title: "Smart Paste Now", action: #selector(smartPasteNow), keyEquivalent: "v")
        pasteNow.keyEquivalentModifierMask = [.command, .shift]
        pasteNow.target = self
        pasteNow.isEnabled = true
        menu.addItem(pasteNow)

        let showQuick = NSMenuItem(title: "Show Quick Actions", action: #selector(showQuickActionsFromMenu), keyEquivalent: "v")
        showQuick.keyEquivalentModifierMask = [.command, .shift, .option]
        showQuick.target = self
        showQuick.isEnabled = true
        menu.addItem(showQuick)

        // Suggestions toggle
        suggestionsToggleItem.target = self
        suggestionsToggleItem.state = UserDefaults.standard.bool(forKey: "suggestionsEnabled") ? .on : .off
        menu.addItem(suggestionsToggleItem)
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

    @MainActor func updateSuggestion(_ text: String) {
        suggestionItem.title = text
    }

    @MainActor @objc private func smartPasteNow() {
        onSmartPaste()
    }

    @MainActor @objc private func showQuickActionsFromMenu() {
        let ctx = DestinationContext(bundleId: frontmostAppBundleID())
        let clip = readClipboard()
        let cType = classifyClipboard(clip)
        let recipe = chooseTransform(content: cType, ctx: ctx)
        presentQuickActionsMenu(clip: clip, ctx: ctx, contentType: cType, recommended: recipe)
    }

    @MainActor @objc private func toggleSuggestions() {
        let enabled = !(UserDefaults.standard.bool(forKey: "suggestionsEnabled"))
        UserDefaults.standard.set(enabled, forKey: "suggestionsEnabled")
        suggestionsToggleItem.state = enabled ? .on : .off
        if enabled {
            SuggestionCenter.shared.requestAuthorization()
        }
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

    @MainActor func presentQuickActionsMenu(clip: ClipboardData, ctx: DestinationContext, contentType: ContentType, recommended: String) {
        let qaMenu = NSMenu()
        qaMenu.autoenablesItems = false
        let titleItem = NSMenuItem(title: "Paste as…", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        qaMenu.addItem(titleItem)
        let recTitle = "Recommended: " + humanReadableTransform(recommended)
        let recItem = NSMenuItem(title: recTitle, action: nil, keyEquivalent: "")
        recItem.isEnabled = false
        qaMenu.addItem(recItem)
        qaMenu.addItem(NSMenuItem.separator())

        func addAction(title: String, transform: String, key: String = "") {
            let item = NSMenuItem(title: title, action: #selector(quickActionSelected(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = transform as NSString
            qaMenu.addItem(item)
        }

        addAction(title: humanReadableTransform(recommended) + " (recommended)", transform: recommended)
        addAction(title: humanReadableTransform("plain"), transform: "plain")
        addAction(title: humanReadableTransform("table-csv"), transform: "table-csv")
        addAction(title: humanReadableTransform("table-md"), transform: "table-md")
        addAction(title: humanReadableTransform("code-fence"), transform: "code-fence")
        addAction(title: humanReadableTransform("bullets"), transform: "bullets")
        addAction(title: humanReadableTransform("one-line"), transform: "one-line")
        addAction(title: humanReadableTransform("json-pretty"), transform: "json-pretty")
        addAction(title: humanReadableTransform("smart-link"), transform: "smart-link")
        qaMenu.addItem(NSMenuItem.separator())
        let cancel = NSMenuItem(title: "Cancel", action: nil, keyEquivalent: "")
        cancel.isEnabled = false
        qaMenu.addItem(cancel)

        statusItem.popUpMenu(qaMenu)
    }

    @MainActor @objc private func quickActionSelected(_ sender: NSMenuItem) {
        guard let transform = sender.representedObject as? NSString else { return }
        onSmartPasteWithTransform(transform as String)
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
// Start clipboard monitoring and suggestions
if isRunningInAppBundle() {
    SuggestionCenter.shared.requestAuthorization()
}
let clipboardMonitor = ClipboardMonitor()
clipboardMonitor.start()
app.run()
