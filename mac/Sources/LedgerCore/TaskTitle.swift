import Foundation

/// Turns the prompt that started a session into text fit for a title. Prompts are stored as
/// the agent sent them, which can be a whole Markdown document with HTML character codes
/// (Codex sends `&#x20;` for a space); only the display is cleaned.
public enum TaskTitle {
    static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
    static let entity = try! NSRegularExpression(pattern: "&(#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]{2,6});")

    /// `&#x20;`, `&#32;`, `&amp;` and the like as the characters they stand for.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#") {
                let hex = body.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                if let code = UInt32(body.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    replacement = String(Character(scalar))
                }
            } else {
                replacement = named[body.lowercased()]
            }
            guard let replacement else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + replacement
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// One line without Markdown marks: heading signs, list bullets, quote marks, bold and code marks.
    static func plainLine(_ line: String) -> (text: String, heading: Bool) {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        var heading = false
        while let c = s.first, "#>*-\"'“”`".contains(c) || c == " " {
            // A dash or star is a bullet only when a space follows; "-5" and "*args" are words.
            if (c == "-" || c == "*"), let next = s.dropFirst().first, next != " ", next != "*" { break }
            if c == "#" { heading = true }
            s = s.dropFirst()
        }
        var text = String(s).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        while let c = text.last, "\"“”".contains(c) { text.removeLast() }
        return (text.trimmingCharacters(in: .whitespaces), heading)
    }

    /// Lines that introduce the real request and say nothing themselves.
    static let wrappers = ["files pasted by the user:", "files mentioned by the user:"]

    /// The whole prompt as plain text on one line.
    public static func plain(_ label: String) -> String {
        lines(label).map(\.text).joined(separator: " ")
    }

    /// A short title: the prompt's first heading when it opens with one, otherwise the whole prompt on one line.
    public static func short(_ label: String) -> String {
        let all = lines(label)
        guard let first = all.first else { return "" }
        return first.heading ? first.text : all.map(\.text).joined(separator: " ")
    }

    static func lines(_ label: String) -> [(text: String, heading: Bool)] {
        var out: [(text: String, heading: Bool)] = []
        for raw in decodeEntities(label).split(whereSeparator: \.isNewline) {
            var (text, heading) = plainLine(String(raw))
            for w in wrappers where text.lowercased().hasPrefix(w) {
                // "# Files pasted by the user: ## "# Build a library…" keeps only what follows.
                (text, heading) = plainLine(String(text.dropFirst(w.count)))
            }
            // A pasted document squeezed onto one line ("# Title ## Objective …"): the title ends at the next heading sign.
            if heading, let next = text.range(of: #"\s#{1,6}\s"#, options: .regularExpression) {
                text = String(text[..<next.lowerBound])
            }
            text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { out.append((text, heading)) }
        }
        return out
    }
}
