import AppKit
import Foundation

/// A group of tools that joins a turn only when the ask needs it. Core tools are always there; an
/// extension's tools are added per turn, so the model never has to "search for tools" first and the
/// prompt doesn't grow with every extension added.
///
/// To add one: write an enum that conforms, list it in `Extensions.all`. `when` is the one line the picker
/// judges each ask against, so make it describe asks, not features.
protocol QuickyExtension {
    static var id: String { get }
    /// A yes/no statement about the ask: "The user wants to know about a song, album, artist or lyrics".
    static var when: String { get }
    /// A regex that picks it locally when the picker hasn't answered in time.
    static var cues: String { get }
    static var tools: [[String: Any]] { get }
    /// Tools that only read (lookups), so they may start while the model is still streaming.
    static var readOnly: Set<String> { get }
    /// Runs one of its tools, or nil when the call isn't one of them.
    static func run(_ call: ToolCall) async -> String?
}

extension QuickyExtension {
    static var names: Set<String> {
        Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
    }
}

enum Extensions {
    static let all: [any QuickyExtension.Type] = [Music.self]

    static func tools(for ids: Set<String>) -> [[String: Any]] {
        all.filter { ids.contains($0.id) }.flatMap { $0.tools }
    }

    static func run(_ call: ToolCall) async -> String? {
        for e in all { if let r = await e.run(call) { return r } }
        return nil
    }

    static func owner(of tool: String) -> String? { all.first { $0.names.contains(tool) }?.id }
    static func readOnly(_ tool: String) -> Bool { all.contains { $0.readOnly.contains(tool) } }

    static func cueMatch(_ text: String) -> Set<String> {
        Set(all.filter { text.range(of: $0.cues, options: [.regularExpression, .caseInsensitive]) != nil }.map { $0.id })
    }

    /// Helper for extensions: a function declaration in the same shape as Tools.declarations.
    static func fn(_ name: String, _ desc: String, _ props: [String: Any], _ req: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": desc,
                                          "parameters": ["type": "object", "properties": props, "required": req]]]
    }
}

/// Decides which extensions a turn gets, mostly while the user is still talking.
/// Jev (TypeSafe) answers one yes/no question per extension in a single request; the questions run in
/// parallel there, so 3 extensions or 40 cost about the same ~300 ms. It's asked on the live transcript,
/// so by the time the final words arrive the answer is usually waiting. Typed asks wait for it briefly;
/// without a key, or when it's late, the extensions' cue words decide.
@MainActor
final class ExtensionPicker {
    private struct Verdict { let text: String; let ids: Set<String>; let ms: Int; let scores: [String: Double] }
    private var latest: Verdict?
    private var inFlight: (text: String, task: Task<Verdict?, Never>)?
    private var lastAsked = Date.distantPast
    private var generation = 0   // a reply that lands after its turn was decided is dropped
    /// Extensions used in recent turns stay on for follow-ups ("and the lyrics?").
    private var recent: [String: Date] = [:]
    var previousAsk = ""

    static var key: String? { Keys.lookup(["TYPESAFE_API_KEY"]) }
    static let threshold = 0.5

    /// Live transcript text. Asks at most every 350 ms and only when a few new words have arrived.
    func hear(_ partial: String, app: String) {
        guard Self.key != nil, !Extensions.all.isEmpty else { return }
        let words = partial.split(separator: " ").count
        guard words >= 2, Date().timeIntervalSince(lastAsked) > 0.35 else { return }
        if let f = inFlight, f.text.split(separator: " ").count >= words - 1 { return }
        ask(partial, app: app)
    }

    /// The final set for this turn. Waits up to `wait` for an answer on (nearly) the final text.
    func pick(final ask: String, app: String, url: String, wait: TimeInterval) async -> Set<String> {
        let t0 = Date()
        var verdict = latest.flatMap { Self.close($0.text, ask) ? $0 : nil }
        let cued = Extensions.cueMatch(ask)
        // A cue word ("lyrics", "song") is enough: don't wait on Jev for what the words already say.
        if verdict == nil, cued.isEmpty, Self.key != nil {
            if inFlight == nil || !Self.close(inFlight!.text, ask) { self.ask(ask, app: app, url: url) }
            if let f = inFlight { verdict = await Self.value(of: f.task, within: wait) }
        }
        var ids = (verdict?.ids ?? []).union(cued)
        let sticky = recent.filter { Date().timeIntervalSince($0.value) < 120 }.map(\.key)
        ids.formUnion(sticky)
        let how = verdict.map { "jev \($0.ms) ms, " + $0.scores.map { "\($0.key) \(String(format: "%.2f", $0.value))" }.sorted().joined(separator: " ") }
            ?? (Self.key == nil ? "cues (no TYPESAFE_API_KEY)" : cued.isEmpty ? "cues (jev late)" : "cues")
        Log.info("extensions: \(ids.isEmpty ? "none" : ids.sorted().joined(separator: ", ")) · \(how)\(sticky.isEmpty ? "" : " · kept \(sticky.joined(separator: ", "))") · waited \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        latest = nil; inFlight = nil; generation += 1
        previousAsk = ask
        return ids
    }

    func used(_ id: String) { recent[id] = Date() }

    private func ask(_ text: String, app: String, url: String = "") {
        lastAsked = Date()
        let prev = previousAsk, gen = generation
        let task = Task<Verdict?, Never> { [weak self] in
            let v = await Self.request(text: text, app: app, url: url, previous: prev)
            if let v, let self, self.generation == gen, self.latest == nil || v.text.count >= self.latest!.text.count { self.latest = v }
            return v
        }
        inFlight = (text, task)
    }

    /// Same ask if the shorter is most of the longer (a partial and the final usually differ by a word or two).
    static func close(_ a: String, _ b: String) -> Bool {
        let wa = a.lowercased().split { !$0.isLetter && !$0.isNumber }, wb = b.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let common = Set(wa).intersection(Set(wb)).count
        return Double(common) / Double(max(Set(wa).count, Set(wb).count)) >= 0.75
    }

    private static func value(of task: Task<Verdict?, Never>, within wait: TimeInterval) async -> Verdict? {
        await withTaskGroup(of: Verdict?.self) { g in
            g.addTask { await task.value }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }

    private static func request(text: String, app: String, url: String, previous: String) async -> Verdict? {
        guard let key else { return nil }
        let t0 = Date()
        var state: [String: Any] = ["ask": text, "app": app]
        if !url.isEmpty { state["page"] = url }
        if !previous.isEmpty { state["previous_ask"] = previous }
        var questions: [String: Any] = [:]
        for e in Extensions.all { questions[e.id] = ["type": "noul", "instructions": e.when] }
        let body: [String: Any] = ["model": "jev-latest", "questions": questions,
                                   "state": String(data: try! JSONSerialization.data(withJSONObject: state), encoding: .utf8)!]
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = j["answers"] as? [String: Any] else {
            Log.info("extensions: jev request failed after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            return nil
        }
        var scores: [String: Double] = [:]
        for (id, a) in answers { if let n = (a as? [String: Any])?["noul"] as? NSNumber { scores[id] = n.doubleValue } }
        let ids = Set(scores.filter { $0.value >= threshold }.map(\.key))
        return Verdict(text: text, ids: ids, ms: Int(Date().timeIntervalSince(t0) * 1000), scores: scores)
    }

    /// Opens the connection to TypeSafe so the first decision doesn't pay for TLS.
    static func warm() {
        guard key != nil else { return }
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/")!)
        req.httpMethod = "HEAD"; req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req).resume()
    }
}
