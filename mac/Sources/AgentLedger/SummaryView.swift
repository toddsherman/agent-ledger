import SwiftUI
import LedgerCore

/// The first screen of a session: result, where, read, ran, changed, trust.
struct SummaryView: View {
    @EnvironmentObject var model: AppModel
    let detail: AppModel.SessionDetail
    @State private var note = ""
    @State private var showAllScripts = false

    var r: SessionReport { detail.report }
    var review: Correction? { detail.corrections.last { $0.action == "reviewed" || $0.action == "unreviewed" } }
    var reviewed: Bool { review?.action == "reviewed" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(r.oneLine).font(.title3.weight(.semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                reviewBar
                if !r.alerts.isEmpty { section("Alerts", "bell.badge") { alertRows } }
                section("What it changed", "pencil.and.list.clipboard") { changed }
                section("Where it worked", "globe") { whereRows }
                section("What it read", "doc.text.magnifyingglass") { read }
                section("Scripts it ran", "curlybraces") { ran }
                section("How complete this record is", "checkmark.shield") { trust }
            }
            .padding(18)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private func section<C: View>(_ title: String, _ icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.headline)
            VStack(alignment: .leading, spacing: 4) { content() }.font(.callout).padding(.leading, 4)
        }
    }

    private var reviewBar: some View {
        HStack(spacing: 8) {
            if reviewed, let c = review {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Reviewed \(Fmt.day(c.createdAt))" + (c.note.map { " · \($0)" } ?? "")).foregroundStyle(.secondary)
                Button("Undo") { model.setReviewed(session: detail.session.id, reviewed: false, note: nil) }.buttonStyle(.borderless)
            } else if detail.session.state == "ended" {
                TextField("Note (optional)", text: $note).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Button("Mark reviewed") { model.setReviewed(session: detail.session.id, reviewed: true, note: note); note = "" }
                    .keyboardShortcut("r", modifiers: .command)
            } else {
                Text("This session is still going. You can mark it reviewed when it ends.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var alertRows: some View {
        ForEach(r.alerts) { a in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.clock(a.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(a.text).fontWeight(.medium).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(a.details.enumerated()), id: \.offset) { _, d in
                    Text(d).font(.caption).foregroundStyle(.secondary).padding(.leading, Fmt.detailIndent).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var changed: some View {
        if r.changes.isEmpty {
            Text(r.unseenBrowser == nil ? "No changes seen." : "No changes reported.")
        }
        ForEach(r.changes) { c in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.clock(c.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let tag = c.tag { Chip(text: tag, color: tag == "Change" ? .secondary : .red) }
                    Chip(text: c.actor + (c.reported ? " (reported)" : ""), color: c.actor.contains("You") ? .blue : .purple)
                    Text(c.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(c.details.enumerated()), id: \.offset) { _, d in
                    Text(d).font(.caption).foregroundStyle(.secondary).padding(.leading, Fmt.detailIndent).textSelection(.enabled)
                }
            }
        }
        Text((r.changes.isEmpty ? "Based on: " : "Also: ") + r.changeBasis + ".").font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if !r.statusMessages.isEmpty {
            Text("Status messages after an action").font(.caption.weight(.semibold)).padding(.top, 4)
            ForEach(r.statusMessages) { m in
                Text("\(Fmt.clock(m.t)) · \(m.text)").font(.caption).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var whereRows: some View {
        if r.sites.isEmpty { Text("No pages were recorded.").foregroundStyle(.secondary) }
        ForEach(Array(r.workedSites.enumerated()), id: \.offset) { _, site in
            HStack {
                Text(site.host).fontWeight(.medium)
                Text(site.reportedOnly ? "\(site.pages) page\(site.pages == 1 ? "" : "s") opened (reported by the agent, not observed)"
                     : "\(SessionReport.minutes(site.ms)) in the tab, \(site.pages) page\(site.pages == 1 ? "" : "s") opened")
                    .foregroundStyle(.secondary)
            }
        }
        let ui = r.sites.filter(\.agentUI).map(\.host)
        Text("\(r.prompts) prompt\(r.prompts == 1 ? "" : "s"), \(r.tabs) tab\(r.tabs == 1 ? "" : "s")" +
             (ui.isEmpty ? "" : ". The agent's own pages (\(ui.joined(separator: ", "))) are left out."))
            .font(.caption).foregroundStyle(.secondary)
        if let b = r.unseenBrowser {
            Label("The agent used \(b), which the recorder can't see. Everything here is the agent's own report.", systemImage: "eye.slash")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var read: some View {
        if r.opened.isEmpty && r.fetched.isEmpty && r.readTools.isEmpty { Text("Nothing was read.").foregroundStyle(.secondary) }
        groups("Opened", r.opened)
        groups("Fetched", r.fetched)
        if !r.readTools.isEmpty {
            Text("Read calls: " + r.readTools.map { "\($0.count) × \($0.pattern)" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func groups(_ verb: String, _ list: [SessionReport.Group]) -> some View {
        ForEach(Array(list.prefix(8).enumerated()), id: \.offset) { _, g in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(verb) \(g.count) ×").foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                Text(g.pattern).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
        if list.count > 8 {
            Text("…and \(list.dropFirst(8).reduce(0) { $0 + $1.count }) more across \(list.count - 8) patterns")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 116)
        }
    }

    @ViewBuilder private var ran: some View {
        if r.scripts.isEmpty { Text("No scripts were run.").foregroundStyle(.secondary) }
        else {
            let risky = r.scripts.filter(\.couldChange)
            Text("\(r.scripts.count) script\(r.scripts.count == 1 ? "" : "s"): \(r.scripts.count - risky.count) look read-only, \(risky.count) could have changed something.")
            // Scripts that could have changed something come first; the rest stay folded.
            let shown = showAllScripts ? r.scripts : (risky.isEmpty ? Array(r.scripts.prefix(3)) : risky)
            ForEach(shown) { ScriptRow(script: $0) }
            if shown.count < r.scripts.count || showAllScripts {
                Button(showAllScripts ? "Show fewer" : "Show all \(r.scripts.count) scripts") { showAllScripts.toggle() }
                    .buttonStyle(.borderless).font(.caption)
            }
            Text("Labels come from reading the code. \"Looks read-only\" is not proof: code built at run time can hide an action.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trust: some View {
        Text(r.trustLine).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        HStack {
            Text(r.logCheck.map { AgentLogs.resultText($0) + "." } ?? "Not yet checked against the agent's own log.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button(r.logCheck == nil ? "Check now" : "Check again") { model.reconcileNow(session: detail.session.id) }
                .buttonStyle(.borderless).font(.caption)
        }
        if let cmd = r.resumeCommand {
            HStack {
                Text("Back to the conversation:").foregroundStyle(.secondary)
                Text(cmd).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy the command")
            }
        } else if let cwd = r.cwd {
            Text("Project folder: \(cwd)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct ScriptRow: View {
    let script: SessionReport.Script
    @State private var open = false

    var firstLine: String {
        script.code.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { open.toggle() } label: { Image(systemName: open ? "chevron.down" : "chevron.right") }.buttonStyle(.borderless)
                    .help(open ? "Hide the script" : "Show the script").accessibilityLabel(open ? "Hide the script" : "Show the script")
                Text(Fmt.clock(script.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Chip(text: script.couldChange ? "could change" : "looks read-only", color: script.couldChange ? .orange : .green)
                if script.failed { Chip(text: "failed", color: .red) }
                Text(firstLine).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text(meta).font(.caption2).foregroundStyle(.secondary)
            }
            if open {
                if script.couldChange {
                    Text("Why: " + (script.signals + (script.nonGetRequests > 0 ? ["\(script.nonGetRequests) non-GET requests"] : [])).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(script.code).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                if !script.fetched.isEmpty {
                    Text("Fetched: " + script.fetched.prefix(4).map { "\($0.count) × \($0.pattern)" }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let p = script.resultPreview {
                    Text("Returned: " + p).font(.caption).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                }
            }
        }
    }

    private var meta: String {
        var bits: [String] = []
        if let d = script.durationMs { bits.append(String(format: "%.1f s", d / 1000)) }
        if script.requests > 0 { bits.append("\(script.requests) request\(script.requests == 1 ? "" : "s")") }
        return bits.joined(separator: " · ")
    }
}
