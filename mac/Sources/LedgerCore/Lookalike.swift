import Foundation

/// Spots domains that imitate a well-known one: `paypa1.com`, `chase-secure-login.com`,
/// `paypal.account-verify.net`. It works on the name alone, on this Mac, so it will sometimes
/// be wrong; it only ever raises an alert.
public enum Lookalike {
    public struct Match: Equatable, Sendable {
        /// The real site this one resembles, e.g. `paypal.com`.
        public var real: String
        /// Why, in a few words.
        public var reason: String
    }

    struct Brand { let name: String; let real: [String] }

    /// Names that are imitated often and are distinctive enough to match on. Common words
    /// (target, discover, chase as a verb is kept: it is the most imitated bank) are left out.
    static let brands: [Brand] = [
        Brand(name: "paypal", real: ["paypal.com", "paypal.me", "paypalobjects.com"]),
        Brand(name: "chase", real: ["chase.com"]),
        Brand(name: "bankofamerica", real: ["bankofamerica.com", "bofa.com"]),
        Brand(name: "wellsfargo", real: ["wellsfargo.com"]),
        Brand(name: "capitalone", real: ["capitalone.com"]),
        Brand(name: "americanexpress", real: ["americanexpress.com", "aexp-static.com"]),
        Brand(name: "citibank", real: ["citi.com", "citibank.com", "citibankonline.com"]),
        Brand(name: "usbank", real: ["usbank.com"]),
        Brand(name: "navyfederal", real: ["navyfederal.org"]),
        Brand(name: "schwab", real: ["schwab.com", "schwabcdn.com"]),
        Brand(name: "fidelity", real: ["fidelity.com", "fidelityinvestments.com", "fidelity.co.uk"]),
        Brand(name: "vanguard", real: ["vanguard.com"]),
        Brand(name: "robinhood", real: ["robinhood.com"]),
        Brand(name: "coinbase", real: ["coinbase.com"]),
        Brand(name: "binance", real: ["binance.com", "binance.us"]),
        Brand(name: "metamask", real: ["metamask.io"]),
        Brand(name: "venmo", real: ["venmo.com"]),
        Brand(name: "zelle", real: ["zellepay.com", "zelle.com"]),
        Brand(name: "stripe", real: ["stripe.com", "stripe.network", "stripecdn.com"]),
        Brand(name: "quickbooks", real: ["quickbooks.com", "intuit.com"]),
        Brand(name: "turbotax", real: ["turbotax.com", "intuit.com"]),
        Brand(name: "experian", real: ["experian.com"]),
        Brand(name: "equifax", real: ["equifax.com"]),
        Brand(name: "transunion", real: ["transunion.com"]),
        Brand(name: "google", real: ["google.com", "googleusercontent.com", "googleapis.com", "google-analytics.com", "googlesyndication.com", "googletagmanager.com", "withgoogle.com", "google.dev"]),
        Brand(name: "gmail", real: ["gmail.com", "google.com"]),
        Brand(name: "microsoft", real: ["microsoft.com", "microsoftonline.com", "microsoft365.com", "microsoftedge.com"]),
        Brand(name: "outlook", real: ["outlook.com", "live.com", "office.com", "office365.com"]),
        Brand(name: "office365", real: ["office365.com", "office.com"]),
        Brand(name: "apple", real: ["apple.com", "apple-cloudkit.com", "apple-mapkit.com", "apple.news"]),
        Brand(name: "icloud", real: ["icloud.com", "icloud-content.com"]),
        Brand(name: "amazon", real: ["amazon.com", "amazonaws.com", "amazon-adsystem.com", "media-amazon.com", "ssl-images-amazon.com", "amazon.jobs", "amazon.dev"]),
        Brand(name: "facebook", real: ["facebook.com", "fb.com", "fbcdn.net"]),
        Brand(name: "instagram", real: ["instagram.com", "cdninstagram.com"]),
        Brand(name: "linkedin", real: ["linkedin.com", "licdn.com"]),
        Brand(name: "twitter", real: ["twitter.com", "x.com", "twimg.com"]),
        Brand(name: "github", real: ["github.com", "githubusercontent.com", "githubassets.com", "github.dev", "github.blog"]),
        Brand(name: "gitlab", real: ["gitlab.com", "gitlab.io"]),
        Brand(name: "cloudflare", real: ["cloudflare.com", "cloudflareinsights.com", "cloudflare-dns.com"]),
        Brand(name: "vercel", real: ["vercel.com", "vercel.app", "vercel-storage.com", "vercel-insights.com", "vercel.sh"]),
        Brand(name: "netlify", real: ["netlify.com", "netlify.app"]),
        Brand(name: "namecheap", real: ["namecheap.com"]),
        Brand(name: "godaddy", real: ["godaddy.com", "secureserver.net"]),
        Brand(name: "openai", real: ["openai.com", "chatgpt.com", "oaistatic.com"]),
        Brand(name: "anthropic", real: ["anthropic.com", "claude.ai", "claude.com"]),
        Brand(name: "1password", real: ["1password.com", "1password.eu", "1password.ca", "1passwordusercontent.com"]),
        Brand(name: "lastpass", real: ["lastpass.com"]),
        Brand(name: "bitwarden", real: ["bitwarden.com", "bitwarden.eu", "bitwarden.net"]),
        Brand(name: "dashlane", real: ["dashlane.com"]),
        Brand(name: "okta", real: ["okta.com", "oktacdn.com", "okta-emea.com", "oktapreview.com"]),
        Brand(name: "dropbox", real: ["dropbox.com", "dropboxusercontent.com", "dropboxstatic.com"]),
        Brand(name: "docusign", real: ["docusign.com", "docusign.net"]),
        Brand(name: "walmart", real: ["walmart.com", "walmartimages.com"]),
        Brand(name: "ebay", real: ["ebay.com", "ebaystatic.com", "ebayimg.com"]),
        Brand(name: "shopify", real: ["shopify.com", "myshopify.com", "shopifycdn.com"]),
        Brand(name: "airbnb", real: ["airbnb.com", "muscache.com"]),
        Brand(name: "netflix", real: ["netflix.com", "nflxext.com"]),
        Brand(name: "usps", real: ["usps.com"]),
        Brand(name: "fedex", real: ["fedex.com"]),
    ]

    /// Real names one typo away from a brand.
    static let notTypos: Set<String> = ["strike", "paypay", "stripes", "googl", "apples", "amazons", "fidelis", "vanguards"]

    static let secondLevels: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu"]

    /// The part of a host you register (`paypal` in `www.paypal.co.uk`) and the domain it sits in.
    static func registrable(_ host: String) -> (label: String, domain: String)? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        var take = 2
        if labels.count >= 3, labels[labels.count - 1].count == 2, secondLevels.contains(labels[labels.count - 2]) { take = 3 }
        let tail = labels.suffix(take)
        return (tail.first!, tail.joined(separator: "."))
    }

    /// Letters and digits that pass for each other folded together: `paypa1` and `paypal` come out the same.
    static func fold(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "rn", with: "m").replacingOccurrences(of: "vv", with: "w")
        for (a, b) in [("0", "o"), ("1", "l"), ("i", "l"), ("3", "e"), ("4", "a"), ("5", "s"), ("7", "t"), ("8", "b")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        return out
    }

    /// True when the strings differ by one typed mistake: a letter added, dropped, changed, or two swapped.
    static func oneTypoApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x == y || abs(x.count - y.count) > 1 { return false }
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        if x.count == y.count {
            if Array(x[(i + 1)...]) == Array(y[(i + 1)...]) { return true }
            return i + 1 < x.count && x[i] == y[i + 1] && x[i + 1] == y[i] && Array(x[(i + 2)...]) == Array(y[(i + 2)...])
        }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    static func isReal(_ host: String, _ brand: Brand) -> Bool {
        brand.real.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public static func match(host: String?) -> Match? {
        guard let host = host?.lowercased(), host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              let reg = registrable(host) else { return nil }
        // A site on the built-in lists is the real thing.
        if SiteGroups.match(host: host) != nil { return nil }
        let tokens = Set(host.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init))
        for brand in brands {
            if isReal(host, brand) { continue }
            // The brand's own name under another ending (amazon.fr, google.dev) is usually theirs.
            if reg.label == brand.name { continue }
            let real = brand.real[0]
            if fold(reg.label) == fold(brand.name) {
                return Match(real: real, reason: "its name swaps look-alike characters")
            }
            if brand.name.count >= 6, !notTypos.contains(reg.label), oneTypoApart(reg.label, brand.name) {
                return Match(real: real, reason: "its name is one letter away")
            }
            if tokens.contains(brand.name) {
                return Match(real: real, reason: "it uses the name \"\(brand.name)\" inside another domain")
            }
        }
        // irs-gov.com, irs.gov.refund-status.com: "gov" as a word in a site that isn't a government domain.
        let labels = host.split(separator: ".").map(String.init)
        let isGovDomain = labels.last == "gov" || (labels.count >= 2 && labels.last!.count == 2 && ["gov", "gouv", "gob", "go"].contains(labels[labels.count - 2]))
        if !isGovDomain, tokens.contains("gov") {
            return Match(real: "a .gov site", reason: "it uses \"gov\" in a name that isn't a government domain")
        }
        return nil
    }
}
