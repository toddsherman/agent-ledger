import Foundation

/// Built-in lists of sites where any change an agent makes is worth an alert.
/// These are starter lists, mostly US. They ship with the app; your own list in Settings covers the rest.
public struct SiteGroup: Sendable, Identifiable {
    public var id: String
    public var name: String
    /// What an alert from this group is about, for Settings.
    public var detail: String
    public var defaultOn: Bool
    /// Domains (subdomains included) or single hosts such as `mail.google.com`.
    public var hosts: [String]
}

public enum SiteGroups {
    public static let customName = "Your list"

    public static let all: [SiteGroup] = [financial, email, passwords, identity, developer, shopping, government, social, storage, chat]

    public static func group(_ id: String) -> SiteGroup? { all.first { $0.id == id } }

    /// The longest entry that covers the host, with its group. Longest wins so that
    /// `console.aws.amazon.com` is Developer, not Shopping.
    public static func match(host: String?) -> (group: SiteGroup, entry: String)? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        var best: (group: SiteGroup, entry: String)?
        for (entry, gid) in index(for: host) where entry.count > (best?.entry.count ?? 0) {
            if let g = group(gid) { best = (g, entry) }
        }
        return best
    }

    private static let byEntry: [String: String] = {
        var out: [String: String] = [:]
        for g in all { for h in g.hosts { out[h.lowercased()] = g.id } }
        return out
    }()

    /// Every suffix of the host on a dot boundary that is a listed entry.
    private static func index(for host: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var rest = Substring(host)
        while true {
            if let gid = byEntry[String(rest)] { out.append((String(rest), gid)) }
            guard let dot = rest.firstIndex(of: ".") else { break }
            rest = rest[rest.index(after: dot)...]
        }
        return out
    }

    static let financial = SiteGroup(
        id: "financial", name: "Financial",
        detail: "Banks, brokerages, card issuers, payment services, crypto exchanges, payroll and tax software",
        defaultOn: true,
        hosts: [
            // Banks and credit unions
            "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "usbank.com", "pnc.com", "truist.com",
            "capitalone.com", "tdbank.com", "td.com", "bmo.com", "citizensbank.com", "53.com", "key.com", "huntington.com",
            "regions.com", "mtb.com", "ally.com", "discover.com", "americanexpress.com", "synchrony.com", "synchronybank.com",
            "navyfederal.org", "usaa.com", "penfed.org", "firstcitizens.com", "santanderbank.com", "hsbc.com", "barclaysus.com",
            "comerica.com", "zionsbank.com", "websterbank.com", "flagstar.com", "becu.org", "alliantcreditunion.org",
            "golden1.com", "schoolsfirstfcu.org", "sofi.com", "chime.com", "varomoney.com", "current.com", "marcus.com",
            "goldmansachs.com", "morganstanley.com", "axosbank.com", "mercury.com", "brex.com", "ramp.com", "novo.co",
            "bluevine.com", "relayfi.com", "wise.com", "revolut.com", "monzo.com", "n26.com", "royalbank.com",
            "rbcroyalbank.com", "scotiabank.com", "cibc.com", "barclays.co.uk", "lloydsbank.com", "natwest.com",
            "santander.co.uk", "hsbc.co.uk",
            // Brokerages and retirement
            "schwab.com", "fidelity.com", "netbenefits.com", "vanguard.com", "etrade.com", "robinhood.com", "webull.com",
            "interactivebrokers.com", "ml.com", "merrilledge.com", "tiaa.org", "troweprice.com", "empower.com", "principal.com",
            "betterment.com", "wealthfront.com", "public.com", "m1.com", "acorns.com", "stash.com", "tastytrade.com",
            "tradestation.com", "ameriprise.com", "edwardjones.com", "raymondjames.com", "voya.com",
            // Credit, loans, pay later
            "creditkarma.com", "experian.com", "equifax.com", "transunion.com", "annualcreditreport.com", "navient.com",
            "mohela.com", "aidvantage.com", "nelnet.com", "rocketmortgage.com", "mrcooper.com", "affirm.com", "klarna.com",
            "afterpay.com", "upstart.com", "lendingclub.com",
            // Payments and transfers
            "paypal.com", "venmo.com", "cash.app", "zellepay.com", "squareup.com", "stripe.com", "payoneer.com",
            "westernunion.com", "remitly.com", "moneygram.com", "xoom.com", "plaid.com",
            // Crypto
            "coinbase.com", "kraken.com", "gemini.com", "binance.com", "binance.us", "crypto.com", "bitstamp.net", "okx.com",
            "bybit.com", "kucoin.com", "blockchain.com", "metamask.io", "ledger.com", "uniswap.org",
            // Accounting, payroll, tax
            "intuit.com", "quickbooks.com", "xero.com", "freshbooks.com", "waveapps.com", "gusto.com", "adp.com",
            "paychex.com", "rippling.com", "bill.com", "expensify.com", "hrblock.com", "taxact.com", "freetaxusa.com",
        ])

    static let email = SiteGroup(
        id: "email", name: "Email",
        detail: "Webmail in Chrome. Mail an agent sends through a connector never reaches Chrome and isn't covered",
        defaultOn: true,
        hosts: [
            "mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "mail.yahoo.com",
            "mail.aol.com", "mail.proton.me", "fastmail.com", "mail.zoho.com", "hey.com", "tuta.com", "tutanota.com",
            "mail.com", "gmx.com", "gmx.net", "mail.yandex.com", "superhuman.com",
        ])

    static let passwords = SiteGroup(
        id: "passwords", name: "Password managers",
        detail: "Vaults and authenticators",
        defaultOn: true,
        hosts: [
            "1password.com", "1password.eu", "1password.ca", "bitwarden.com", "bitwarden.eu", "lastpass.com", "dashlane.com",
            "keepersecurity.com", "nordpass.com", "pass.proton.me", "roboform.com", "enpass.io", "passwords.google.com",
            "vault.zoho.com", "stickypassword.com", "logmeonce.com", "passbolt.com", "authy.com",
        ])

    static let identity = SiteGroup(
        id: "identity", name: "Accounts and identity",
        detail: "Google, Apple and Microsoft account pages, single sign-on and identity providers",
        defaultOn: true,
        hosts: [
            "accounts.google.com", "myaccount.google.com", "admin.google.com", "appleid.apple.com", "account.apple.com",
            "icloud.com", "account.microsoft.com", "account.live.com", "login.live.com", "login.microsoftonline.com",
            "myaccount.microsoft.com", "mysignins.microsoft.com", "entra.microsoft.com", "admin.microsoft.com",
            "account.proton.me", "okta.com", "auth0.com", "onelogin.com", "duosecurity.com", "duo.com", "jumpcloud.com",
            "pingidentity.com", "id.me", "accountscenter.facebook.com", "accountscenter.instagram.com",
        ])

    static let developer = SiteGroup(
        id: "developer", name: "Developer and infrastructure",
        detail: "Code hosts, cloud consoles, package registries, domain registrars and DNS, API key consoles",
        defaultOn: true,
        hosts: [
            "github.com", "gitlab.com", "bitbucket.org", "aws.amazon.com", "cloud.google.com", "firebase.google.com",
            "portal.azure.com", "dev.azure.com", "cloudflare.com", "vercel.com", "netlify.com", "heroku.com",
            "digitalocean.com", "linode.com", "vultr.com", "hetzner.com", "render.com", "fly.io", "railway.app", "railway.com",
            "supabase.com", "mongodb.com", "planetscale.com", "neon.tech", "upstash.com", "twilio.com", "sendgrid.com",
            "npmjs.com", "pypi.org", "hub.docker.com", "rubygems.org", "crates.io", "circleci.com", "app.terraform.io",
            "tailscale.com", "developer.apple.com", "appstoreconnect.apple.com", "platform.openai.com",
            "console.anthropic.com", "platform.claude.com",
            "namecheap.com", "godaddy.com", "porkbun.com", "squarespace.com", "hover.com", "gandi.net", "dynadot.com",
            "name.com", "dnsimple.com", "ns1.com",
        ])

    static let shopping = SiteGroup(
        id: "shopping", name: "Shopping and travel",
        detail: "Stores, delivery, rides, tickets and bookings, where an agent could place an order",
        defaultOn: true,
        hosts: [
            "amazon.com", "amazon.co.uk", "amazon.ca", "amazon.de", "ebay.com", "walmart.com", "target.com", "bestbuy.com",
            "costco.com", "etsy.com", "homedepot.com", "lowes.com", "wayfair.com", "ikea.com", "macys.com", "nordstrom.com",
            "nike.com", "zappos.com", "sephora.com", "chewy.com", "newegg.com", "bhphotovideo.com", "temu.com", "shein.com",
            "aliexpress.com", "alibaba.com", "kroger.com", "walgreens.com", "cvs.com", "shopify.com", "myshopify.com",
            "shop.app", "pay.google.com", "wallet.google.com", "instacart.com", "doordash.com", "ubereats.com", "grubhub.com",
            "uber.com", "lyft.com", "airbnb.com", "vrbo.com", "booking.com", "expedia.com", "hotels.com", "delta.com",
            "united.com", "aa.com", "southwest.com", "ticketmaster.com", "stubhub.com",
        ])

    static let government = SiteGroup(
        id: "government", name: "Government, tax and health",
        detail: "Every .gov site, other national government sites, patient portals, insurers and labs",
        defaultOn: true,
        hosts: [
            "gov", "mil", "gov.uk", "canada.ca", "gc.ca", "gov.au",
            "mychart.com", "mychart.org", "followmyhealth.com", "athenahealth.com", "uhc.com", "myuhc.com", "anthem.com",
            "aetna.com", "cigna.com", "mycigna.com", "humana.com", "bcbs.com", "kaiserpermanente.org", "kp.org", "optum.com",
            "optumrx.com", "express-scripts.com", "labcorp.com", "questdiagnostics.com", "onemedical.com", "zocdoc.com",
            "teladoc.com", "healthequity.com", "hsabank.com", "23andme.com",
        ])

    static let social = SiteGroup(
        id: "social", name: "Social and publishing",
        detail: "Places where an agent could post or message publicly as you",
        defaultOn: true,
        hosts: [
            "x.com", "twitter.com", "linkedin.com", "facebook.com", "instagram.com", "threads.net", "threads.com", "reddit.com",
            "youtube.com", "tiktok.com", "bsky.app", "mastodon.social", "pinterest.com", "tumblr.com", "snapchat.com",
            "twitch.tv", "quora.com", "nextdoor.com", "news.ycombinator.com", "stackoverflow.com", "producthunt.com",
            "substack.com", "medium.com", "wordpress.com", "ghost.io", "dev.to",
        ])

    static let storage = SiteGroup(
        id: "storage", name: "File storage and sharing",
        detail: "Drives and shared documents. Off at first because agents often work here",
        defaultOn: false,
        hosts: [
            "drive.google.com", "docs.google.com", "photos.google.com", "dropbox.com", "onedrive.live.com", "sharepoint.com",
            "box.com", "mega.nz", "pcloud.com", "sync.com", "wetransfer.com",
        ])

    static let chat = SiteGroup(
        id: "chat", name: "Work chat and messaging",
        detail: "Messages sent as you. Off at first because agents often work here",
        defaultOn: false,
        hosts: [
            "slack.com", "teams.microsoft.com", "teams.live.com", "discord.com", "chat.google.com", "messages.google.com",
            "web.whatsapp.com", "messenger.com", "web.telegram.org",
        ])
}
