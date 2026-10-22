import Foundation

/// Web search for the web_search tool. Uses whichever provider has a key, fastest first:
/// Parallel (PARALLEL_API_KEY, turbo ~200-350 ms), Exa (EXA_API_KEY), Brave (BRAVE_API_KEY).
/// Keys come from the same places as the others (environment or ~/.zshrc).
enum WebSearch {
    enum Provider: String { case parallel, exa, brave }

    static var provider: (Provider, String)? {
        if let k = Keys.lookup(["PARALLEL_API_KEY"]) { return (.parallel, k) }
        if let k = Keys.lookup(["EXA_API_KEY"]) { return (.exa, k) }
        if let k = Keys.lookup(["BRAVE_API_KEY", "BRAVE_SEARCH_API_KEY"]) { return (.brave, k) }
        return nil
    }

    static var available: Bool { provider != nil }

    struct Hit { let title: String; let url: String; let date: String?; let text: String }

    /// Compact text for the model: a few results with dates and short excerpts, so the second model trip stays fast.
    static func run(query: String, objective: String? = nil) async -> String {
        guard let found = provider else { return "error: web search isn't set up (no search API key); say so in one short sentence" }
        let (p, key) = found
        let t0 = Date()
        do {
            let hits = try await search(p, key: key, query: query, objective: objective ?? query)
            Log.time("search \(p.rawValue) \(hits.count) hits", since: t0)
            if hits.isEmpty { return "no results for \"\(query)\"" }
            let df = ISO8601DateFormatter(); df.formatOptions = [.withFullDate]
            return "TODAY: \(df.string(from: Date()))\n" + hits.prefix(5).enumerated().map { i, h in
                let host = URL(string: h.url)?.host ?? h.url
                let text = h.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                return "[\(i + 1)] \(h.title) (\(host)\(h.date.map { ", \($0.prefix(10))" } ?? ""))\n\(String(text.prefix(700)))"
            }.joined(separator: "\n\n")
        } catch {
            Log.error("search \(p.rawValue) failed: \(error)")
            return "error: search failed; answer from what you know and say you couldn't check"
        }
    }

    private static func search(_ p: Provider, key: String, query: String, objective: String) async throws -> [Hit] {
        var req: URLRequest
        switch p {
        case .parallel:
            req = URLRequest(url: URL(string: "https://api.parallel.ai/v1/search")!)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let mode = Keys.setting("ASSISTANT_SEARCH_MODE", default: "turbo")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["objective": objective, "search_queries": [query], "mode": mode])
        case .exa:
            req = URLRequest(url: URL(string: "https://api.exa.ai/search")!)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let type = Keys.setting("ASSISTANT_SEARCH_MODE", default: "fast")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": query, "type": type, "numResults": 5,
                "contents": ["highlights": ["numSentences": 3, "highlightsPerUrl": 2]],
            ] as [String: Any])
        case .brave:
            var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            c.queryItems = [.init(name: "q", value: query), .init(name: "count", value: "5"), .init(name: "extra_snippets", value: "true")]
            req = URLRequest(url: c.url!)
            req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        req.timeoutInterval = 6
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "WebSearch", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return parse(p, json)
    }

    static func parse(_ p: Provider, _ json: [String: Any]) -> [Hit] {
        switch p {
        case .parallel:
            return (json["results"] as? [[String: Any]] ?? []).map {
                Hit(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", date: $0["publish_date"] as? String,
                    text: ($0["excerpts"] as? [String] ?? []).joined(separator: " … "))
            }
        case .exa:
            return (json["results"] as? [[String: Any]] ?? []).map {
                Hit(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", date: $0["publishedDate"] as? String,
                    text: ($0["highlights"] as? [String] ?? [$0["text"] as? String ?? ""]).joined(separator: " … "))
            }
        case .brave:
            let results = (json["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            return results.map {
                let extra = $0["extra_snippets"] as? [String] ?? []
                return Hit(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", date: $0["age"] as? String,
                           text: ([$0["description"] as? String ?? ""] + extra).joined(separator: " … "))
            }
        }
    }
}
