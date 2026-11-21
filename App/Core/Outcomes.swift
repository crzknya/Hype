import Foundation
import HyperCore

/// HIP-4 outcome markets (app.hyperliquid.xyz "Outcomes"): binary Yes/No tokens priced 0…1 USDC that
/// settle to 1 or 0. Side coin "#N" with N = outcome × 10 + side (0 = first side, 1 = second side),
/// held as "+N" in spot balances, traded on asset 100 000 000 + N.
struct OutcomeTemplate: Hashable {
    let id: String
    let name: String
    let description: String
    let sideNames: [String]
}

struct OutcomeSpec: Identifiable, Hashable {
    let id: Int                    // outcome id
    let template: String
    let fields: [String: String]   // description "key:value|key:value"
    let sideSpecs: [String]
    let quoteToken: String
    let deployerFeeScale: Double

    func coin(_ side: Int) -> String { "#\(id * 10 + side)" }
    func asset(_ side: Int) -> Int { 100_000_000 + id * 10 + side }
}

struct OutcomeQuestion: Identifiable, Hashable {
    let id: Int
    let template: String
    let fields: [String: String]
    let fallback: Int?
    let named: [Int]
    let settled: [Int]
}

enum OutcomeText {
    static func fields(_ description: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in description.split(separator: "|") {
            guard let i = part.firstIndex(of: ":") else { continue }
            out[String(part[..<i])] = String(part[part.index(after: i)...])
        }
        return out
    }

    /// Replaces {key} placeholders; dates like 20261121-2100 become readable.
    static func render(_ template: String, _ fields: [String: String]) -> String {
        var s = template
        for (k, v) in fields { s = s.replacingOccurrences(of: "{\(k)}", with: pretty(v)) }
        if let r = s.range(of: " metadata=") { s = String(s[..<r.lowerBound]) }
        return s
    }

    static func pretty(_ v: String) -> String {
        // yyyyMMdd-HHmm (UTC)
        let parts = v.split(separator: "-")
        if parts.count == 2, parts[0].count == 8, parts[1].count == 4, Int(parts[0]) != nil, Int(parts[1]) != nil {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd-HHmm"
            if let d = f.date(from: v) {
                let o = DateFormatter()
                o.dateStyle = .medium
                o.timeStyle = .short
                return o.string(from: d)
            }
        }
        if v.hasPrefix("perp:") { return String(v.dropFirst(5)) }
        return v
    }
}

extension AppModel {
    func loadOutcomes() async {
        async let metaReq = tryOutcomeInfo("outcomeMeta")
        async let tmplReq = tryOutcomeInfo("outcomeTemplates")
        let (meta, tmpl) = await (metaReq, tmplReq)
        if let tmpl {
            var map: [String: OutcomeTemplate] = [:]
            for t in tmpl.array {
                let id = t["id"].str
                let sides = t["role"]["standaloneOutcome"]["sideNames"].array.map(\.str)
                map[id] = OutcomeTemplate(id: id, name: t["name"].str, description: t["description"].str, sideNames: sides)
            }
            outcomeTemplates = map
        }
        guard let meta else { return }
        outcomeSpecs = meta["outcomes"].array.compactMap { o in
            guard let id = o["outcome"].int else { return nil }
            return OutcomeSpec(id: id, template: o["name"].str, fields: OutcomeText.fields(o["description"].str),
                               sideSpecs: o["sideSpecs"].array.map { $0["name"].str }, quoteToken: o["quoteToken"].str,
                               deployerFeeScale: o["deployerFeeScale"].dbl)
        }
        outcomeQuestions = meta["questions"].array.compactMap { q in
            guard let id = q["question"].int else { return nil }
            return OutcomeQuestion(id: id, template: q["name"].str, fields: OutcomeText.fields(q["description"].str),
                                   fallback: q["fallbackOutcome"].int, named: q["namedOutcomes"].array.compactMap(\.int),
                                   settled: q["settledNamedOutcomes"].array.compactMap(\.int))
        }
        // Register side markets so prices, order books and orders work like other spot markets.
        for o in outcomeSpecs {
            for side in 0..<max(o.sideSpecs.count, 2) {
                let coin = o.coin(side)
                var m = marketById[coin] ?? Market(id: coin, name: outcomeSideTitle(o, side), base: "+\(o.id * 10 + side)", quote: o.quoteToken.isEmpty ? "USDC" : o.quoteToken,
                                                   asset: o.asset(side), isSpot: true, szDecimals: 0, maxLeverage: 1, onlyIsolated: false)
                if let c = outcomeCtx[coin] { m.midPx = c.mid; m.markPx = c.mark; m.dayNtlVlm = c.volume }
                marketById[coin] = m
            }
        }
    }

    private func tryOutcomeInfo(_ type: String) async -> JSON? { try? await api.info(type: type) }

    private func templateId(_ name: String) -> String? {
        name.hasPrefix("template:") ? String(name.dropFirst("template:".count)) : nil
    }

    func outcomeTitle(_ o: OutcomeSpec) -> String {
        if let t = templateId(o.template), let tpl = outcomeTemplates[t] { return OutcomeText.render(tpl.name, o.fields) }
        if o.template == "template fallback" || o.template.hasSuffix("Fallback") { return L("Other") }
        return o.template
    }

    func outcomeDescription(_ o: OutcomeSpec) -> String {
        if let t = templateId(o.template), let tpl = outcomeTemplates[t] { return OutcomeText.render(tpl.description, o.fields) }
        return o.fields.map { "\($0.key): \(OutcomeText.pretty($0.value))" }.sorted().joined(separator: "\n")
    }

    func questionTitle(_ q: OutcomeQuestion) -> String {
        if let t = templateId(q.template), let tpl = outcomeTemplates[t] { return OutcomeText.render(tpl.name, q.fields) }
        return q.template
    }

    func questionDescription(_ q: OutcomeQuestion) -> String {
        if let t = templateId(q.template), let tpl = outcomeTemplates[t] { return OutcomeText.render(tpl.description, q.fields) }
        return ""
    }

    func outcomeSideName(_ o: OutcomeSpec, _ side: Int) -> String {
        let raw = side < o.sideSpecs.count ? o.sideSpecs[side] : (side == 0 ? "Yes" : "No")
        if raw.hasPrefix("template:") {
            let name = String(raw.dropFirst("template:".count))
            if let t = templateId(o.template), let tpl = outcomeTemplates[t], side < tpl.sideNames.count {
                return OutcomeText.render(tpl.sideNames[side], o.fields)
            }
            return name
        }
        return raw
    }

    func outcomeSideTitle(_ o: OutcomeSpec, _ side: Int) -> String {
        "\(outcomeTitle(o)) · \(outcomeSideName(o, side))"
    }

    func outcome(_ id: Int) -> OutcomeSpec? { outcomeSpecs.first { $0.id == id } }

    /// Outcome spec and side for a coin "#N" or a balance token "+N".
    func outcomeSide(of coin: String) -> (spec: OutcomeSpec, side: Int)? {
        guard coin.hasPrefix("#") || coin.hasPrefix("+"), let n = Int(coin.dropFirst()) else { return nil }
        guard let o = outcome(n / 10) else { return nil }
        return (o, n % 10)
    }

    /// Probability-style price of a side (mid of "#N").
    func outcomePrice(_ o: OutcomeSpec, _ side: Int) -> Double { mid(o.coin(side)) }

    /// Outcomes not grouped into a question.
    var standaloneOutcomes: [OutcomeSpec] {
        let grouped = Set(outcomeQuestions.flatMap { $0.named + ($0.fallback.map { [$0] } ?? []) })
        return outcomeSpecs.filter { !grouped.contains($0.id) }
    }
}
