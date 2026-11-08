import Foundation

/// Redaction rules shared with `extension/lib/redact.js`. Both implementations are tested
/// against `Tests/LedgerCoreTests/Fixtures/redaction.json`.
public enum Redactor {
    public static let maxValueLength = 2048

    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants; a failure is a programming error.
        try! NSRegularExpression(pattern: p, options: opts)
    }

    private static let privateKey = re("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----")
    private static let jwt = re("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}")
    private static let tokenPrefixes = re("\\b(?:sk-[A-Za-z0-9_-]{16,}|sk_live_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{20,})")
    private static let bearer = re("\\b([Bb]earer)\\s+[A-Za-z0-9._~+/=-]{16,}")
    private static let card = re("\\b(?:\\d[ -]?){12,18}\\d\\b")
    private static let ssn = re("\\b\\d{3}-\\d{2}-\\d{4}\\b")
    private static let longSecret = re("[A-Za-z0-9+/_-]{40,}={0,2}")

    private static let sensitiveKeyExact: Set<String> = [
        "code", "state", "nonce", "sig", "signature", "key", "apikey", "api_key", "auth", "authorization",
        "otp", "jwt", "ticket", "sid", "pwd", "passwd", "password", "pass", "secret", "client_secret",
        "credential", "credentials", "samlresponse", "samlrequest", "relaystate",
    ]
    private static let sensitiveKeyContains = ["token", "secret", "password", "session", "apikey", "api_key",
                                               "signature", "credential", "x-amz-"]

    public static func isSensitiveKey(_ key: String) -> Bool {
        let k = (key.removingPercentEncoding ?? key).lowercased()
        if sensitiveKeyExact.contains(k) { return true }
        return sensitiveKeyContains.contains { k.contains($0) }
    }

    /// Narrower than `isSensitiveKey`: object fields in tool input such as `code` (JavaScript)
    /// or `key` (a key press) are legitimate content, not secrets.
    public static func isSensitiveField(_ key: String) -> Bool {
        let k = key.lowercased()
        let exact: Set<String> = ["password", "pass", "pwd", "passwd", "secret", "client_secret", "otp", "jwt",
                                  "authorization", "apikey", "api_key", "cookie", "set-cookie"]
        if exact.contains(k) { return true }
        return ["token", "secret", "password", "apikey", "api_key", "credential"].contains { k.contains($0) }
    }

    static func luhn(_ digits: [Int]) -> Bool {
        guard digits.count >= 13 && digits.count <= 19 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    private static func replace(_ regex: NSRegularExpression, in s: String,
                                with transform: (String, NSTextCheckingResult) -> String?) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let match = ns.substring(with: m.range)
            guard let rep = transform(match, m) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += rep
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Replaces secret-looking substrings. Does not truncate.
    public static func scrub(_ input: String) -> String {
        var s = input
        s = replace(privateKey, in: s) { _, _ in "[redacted:private-key]" }
        s = replace(jwt, in: s) { _, _ in "[redacted:jwt]" }
        s = replace(tokenPrefixes, in: s) { _, _ in "[redacted:token]" }
        s = replace(bearer, in: s) { _, _ in "Bearer [redacted:token]" }
        s = replace(card, in: s) { match, _ in
            let digits = match.compactMap { $0.wholeNumberValue }
            return luhn(digits) ? "[redacted:card]" : nil
        }
        s = replace(ssn, in: s) { _, _ in "[redacted:ssn]" }
        s = replace(longSecret, in: s) { match, _ in
            if match.hasPrefix("[redacted") { return nil }
            let hasDigit = match.contains { $0.isNumber }
            let hasLetter = match.contains { $0.isLetter }
            return hasDigit && hasLetter ? "[redacted:secret]" : nil
        }
        return s
    }

    public static func truncate(_ s: String, max: Int = maxValueLength) -> String {
        guard s.count > max else { return s }
        let head = String(s.prefix(max))
        return head + "…[+\(s.count - max) chars]"
    }

    /// Scrubs and truncates a captured value.
    public static func value(_ s: String, max: Int = maxValueLength) -> String {
        truncate(scrub(s), max: max)
    }

    private static func redactParams(_ part: String) -> String {
        part.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            guard let eq = pair.firstIndex(of: "=") else { return String(pair) }
            let k = String(pair[pair.startIndex..<eq])
            let v = String(pair[pair.index(after: eq)...])
            if isSensitiveKey(k) { return "\(k)=[redacted]" }
            let decoded = v.removingPercentEncoding ?? v
            if scrub(decoded) != decoded { return "\(k)=[redacted]" }
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    private static let userInfo = re("^([A-Za-z][A-Za-z0-9+.-]*://)[^/@?#]*@")

    /// Redacts credentials and sensitive query/fragment parameters from a URL string.
    public static func url(_ raw: String) -> String {
        var base = raw
        var fragment: String?
        if let hash = base.firstIndex(of: "#") {
            fragment = String(base[base.index(after: hash)...])
            base = String(base[base.startIndex..<hash])
        }
        var query: String?
        if let q = base.firstIndex(of: "?") {
            query = String(base[base.index(after: q)...])
            base = String(base[base.startIndex..<q])
        }
        base = userInfo.stringByReplacingMatches(in: base, range: NSRange(location: 0, length: (base as NSString).length),
                                                 withTemplate: "$1[redacted]@")
        var out = base
        if let query { out += "?" + redactParams(query) }
        if let fragment {
            out += "#" + (fragment.contains("=") ? redactParams(fragment) : fragment)
        }
        return truncate(out)
    }

    /// Deep-sanitizes hook tool input: scrubs strings, truncates long ones, and replaces
    /// binary-looking blobs (base64 images) with a size marker.
    public static func sanitize(_ v: JSONValue, maxString: Int = 4096, depth: Int = 0) -> JSONValue {
        if depth > 12 { return .string("[truncated: too deep]") }
        switch v {
        case .string(let s):
            if s.count > 1024, looksBinary(s) { return .string("[binary \(s.count) chars]") }
            return .string(truncate(scrub(s), max: maxString))
        case .array(let a):
            let head = a.prefix(200).map { sanitize($0, maxString: maxString, depth: depth + 1) }
            return .array(a.count > 200 ? head + [.string("[+\(a.count - 200) items]")] : Array(head))
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, val) in o {
                if isSensitiveField(k), case .string = val { out[k] = .string("[redacted]"); continue }
                out[k] = sanitize(val, maxString: maxString, depth: depth + 1)
            }
            return .object(out)
        default:
            return v
        }
    }

    static func looksBinary(_ s: String) -> Bool {
        if s.hasPrefix("data:") { return true }
        let sample = s.prefix(512)
        let b64 = sample.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
        return b64.count == sample.count && !sample.contains(" ")
    }
}
