import AppKit
import Foundation

/// One installed extension, read from its extension.json (docs/extensions.md).
struct ExtensionManifest {
    enum Effect: String { case read, local, write, external }
    struct Tool {
        let name: String          // short name in the manifest ("search")
        let fullName: String      // what the model sees ("music_search")
        let description: String
        let effect: Effect
        let timeoutMs: Int
        let input: [String: Any]
        let output: [String: Any]?
        let examples: [[String: Any]]
    }

    let id: String, name: String, version: String, description: String, when: String
    let cues: [String]
    let hosts: Set<String>, applescriptApps: Set<String>, secrets: Set<String>
    let main: String
    let always: Bool          // core extensions that are on every turn (web search), not picked
    let tools: [Tool]
    let dir: URL
    let core: Bool

    var native: Bool { main == "native" }
    var cueRegex: String? { cues.isEmpty ? nil : #"\b("# + cues.joined(separator: "|") + #")\b"# }

    struct Invalid: Error, CustomStringConvertible { let description: String }

    static func load(_ dir: URL, core: Bool) throws -> ExtensionManifest {
        let file = dir.appendingPathComponent("extension.json")
        guard let data = try? Data(contentsOf: file) else { throw Invalid(description: "no extension.json in \(dir.path)") }
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Invalid(description: "extension.json is not a JSON object") }
        func str(_ k: String, required: Bool = true) throws -> String {
            let v = (j[k] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if required && v.isEmpty { throw Invalid(description: "\"\(k)\" is missing") }
            return v
        }
        let id = try str("id")
        guard id.range(of: #"^[a-z][a-z0-9-]{1,30}$"#, options: .regularExpression) != nil else {
            throw Invalid(description: "id \"\(id)\" must be lowercase letters, digits and -, 2-31 characters")
        }
        let perms = j["permissions"] as? [String: Any] ?? [:]
        var tools: [Tool] = []
        guard let toolDict = j["tools"] as? [String: Any], !toolDict.isEmpty else { throw Invalid(description: "\"tools\" is missing or empty") }
        for (name, raw) in toolDict.sorted(by: { $0.key < $1.key }) {
            guard let t = raw as? [String: Any] else { throw Invalid(description: "tool \(name) is not an object") }
            guard name.range(of: #"^[a-z][a-z0-9_]{0,40}$"#, options: .regularExpression) != nil else {
                throw Invalid(description: "tool name \"\(name)\" must be lowercase letters, digits and _")
            }
            guard let effect = Effect(rawValue: t["effect"] as? String ?? "") else {
                throw Invalid(description: "tool \(name): \"effect\" must be read, local, write or external")
            }
            guard let desc = t["description"] as? String, !desc.isEmpty else { throw Invalid(description: "tool \(name): \"description\" is missing") }
            guard let input = t["input"] as? [String: Any], input["type"] as? String == "object" else {
                throw Invalid(description: "tool \(name): \"input\" must be a JSON Schema object")
            }
            let full = "\(id.replacingOccurrences(of: "-", with: "_"))_\(name)"
            tools.append(Tool(name: name, fullName: full, description: desc, effect: effect,
                              timeoutMs: (t["timeoutMs"] as? NSNumber)?.intValue ?? 5000, input: input,
                              output: t["output"] as? [String: Any], examples: t["examples"] as? [[String: Any]] ?? []))
        }
        return ExtensionManifest(
            id: id, name: try str("name"), version: try str("version"), description: try str("description"),
            when: try str("when", required: !(j["always"] as? Bool ?? false)),
            cues: j["cues"] as? [String] ?? [],
            hosts: Set(perms["hosts"] as? [String] ?? []), applescriptApps: Set(perms["applescript"] as? [String] ?? []),
            secrets: Set(perms["secrets"] as? [String] ?? []),
            main: try str("main"), always: core && (j["always"] as? Bool ?? false), tools: tools, dir: dir, core: core)
    }

    /// The declaration the model gets: the input schema as parameters, the output shape in the description.
    func declaration(_ t: Tool) -> [String: Any] {
        var desc = t.description
        if let out = t.output { desc += " Returns \(ExtensionHost.shape(out))." }
        if t.effect == .write || t.effect == .external { desc += " Asks the user to confirm." }
        return ["type": "function", "function": ["name": t.fullName, "description": desc, "parameters": t.input]]
    }
}

/// Finds, loads and runs extensions. Core ones ship inside the app; the rest are installed per user.
enum ExtensionHost {
    private static let loaded = Locked<[ExtensionManifest]>([])
    private static let runtimes = Locked<[String: JSExtension]>([:])

    static var installDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quicky/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Core extensions: inside the app bundle, or the repo's extensions/core when run from a build folder.
    static var coreDirs: [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Extensions") { dirs.append(r) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("extensions/core")
        dirs.append(repo)
        return dirs
    }

    /// `extra`: single extension folders to load as if installed (tests, probes).
    static func load(extra: [URL] = []) {
        var found: [String: ExtensionManifest] = [:]
        let fm = FileManager.default
        var dirs: [(URL, Bool)] = []
        for (base, core) in coreDirs.map({ ($0, true) }) + [(installDir, false)] {
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where !name.hasPrefix(".") {
                dirs.append((base.appendingPathComponent(name).resolvingSymlinksInPath(), core))
            }
        }
        dirs += extra.map { ($0, false) }
        for (dir, core) in dirs {
            let name = dir.lastPathComponent
            do {
                let m = try ExtensionManifest.load(dir, core: core)
                if found[m.id] == nil { found[m.id] = m }   // the bundle copy wins over the repo copy
            } catch { Log.error("extension \(name): \(error)") }
        }
        loaded.value = found.values.sorted { $0.id < $1.id }
        runtimes.value = [:]
        Log.info("extensions loaded: " + loaded.value.map { "\($0.id)\($0.core ? " (core)" : "")\(isEnabled($0.id) ? "" : " off")" }.joined(separator: ", "))
    }

    static var all: [ExtensionManifest] {
        if loaded.value.isEmpty { load() }
        return loaded.value
    }
    static var enabled: [ExtensionManifest] { all.filter { isEnabled($0.id) } }
    /// Extensions the picker chooses between (core "always" ones are on regardless).
    static var pickable: [ExtensionManifest] { enabled.filter { !$0.always } }

    static func isEnabled(_ id: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: "disabledExtensions") ?? []).contains(id)
    }
    static func setEnabled(_ id: String, _ on: Bool) {
        var off = Set(UserDefaults.standard.stringArray(forKey: "disabledExtensions") ?? [])
        if on { off.remove(id) } else { off.insert(id) }
        UserDefaults.standard.set(Array(off).sorted(), forKey: "disabledExtensions")
    }

    static func tool(_ fullName: String) -> (ExtensionManifest, ExtensionManifest.Tool)? {
        for m in enabled { if let t = m.tools.first(where: { $0.fullName == fullName }) { return (m, t) } }
        return nil
    }
    static func owner(of fullName: String) -> String? { tool(fullName)?.0.id }
    static func effect(of fullName: String) -> ExtensionManifest.Effect? { tool(fullName)?.1.effect }

    /// Declarations for this turn: always-on core extensions, the picked ones, and `run` when there's
    /// anything to combine.
    static func declarations(for picked: Set<String>) -> [[String: Any]] {
        let on = enabled.filter { $0.always || picked.contains($0.id) }
        var decls = on.flatMap { m in m.tools.map { m.declaration($0) } }
        if on.contains(where: { !$0.always }) { decls.append(Composer.declaration) }
        return decls
    }

    // MARK: Running

    /// Runs an extension tool (not `run`, not native ones). Returns JSON text for the model, or nil if
    /// the call isn't an extension tool.
    static func run(_ call: ToolCall) async -> String? {
        guard case let (m, t)? = tool(call.name), !m.native else { return nil }
        let r = await invoke(m, t, call.arguments)
        return r.text
    }

    struct Outcome {
        var value: Any?, error: String?
        var text: String {
            if let error { return "error: \(error)" }
            return ExtensionHost.json(value ?? NSNull())
        }
    }

    static func invoke(_ m: ExtensionManifest, _ t: ExtensionManifest.Tool, _ input: [String: Any]) async -> Outcome {
        let t0 = Date()
        if let p = ToolSchema.check(input, schema: t.input, path: "") { return Outcome(error: "\(t.fullName): \(p)") }
        do {
            let rt = try runtime(m)
            let v = try await rt.call(t.name, input: input, timeoutMs: t.timeoutMs)
            Log.time("ext \(t.fullName) ok", since: t0)
            return Outcome(value: v)
        } catch {
            Log.time("ext \(t.fullName) failed: \(error)", since: t0)
            return Outcome(error: "\(error)")
        }
    }

    static func runtime(_ m: ExtensionManifest) throws -> JSExtension {
        if let r = runtimes.value[m.id] { return r }
        let r = try JSExtension(m)
        runtimes.value[m.id] = r
        return r
    }

    /// Loads every enabled JS extension's code ahead of the first ask, so the first call doesn't pay for it.
    static func warm() {
        for m in enabled where !m.native { _ = try? runtime(m) }
    }

    // MARK: Helpers

    static func json(_ v: Any) -> String {
        if let s = v as? String { return s }
        guard JSONSerialization.isValidJSONObject(v) || v is NSNull || v is NSNumber,
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "\(v)" }
        return s
    }

    static func pretty(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Always valid JSON, strings quoted (json() passes a string through as text for the model).
    static func jsonValue(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    /// The user's store region, e.g. "in".
    static var country: String { (Locale.current.region?.identifier ?? "IN").lowercased() }

    /// A compact type for the model: {results: [{title, artists, match}]}.
    static func shape(_ schema: [String: Any], depth: Int = 0) -> String {
        switch schema["type"] as? String {
        case "object":
            let props = (schema["properties"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }
            if props.isEmpty || depth > 3 { return "object" }
            return "{" + props.map { k, v in
                guard let sub = v as? [String: Any] else { return k }
                let inner = shape(sub, depth: depth + 1)
                return ["string", "number", "integer", "boolean"].contains(inner) ? k : "\(k): \(inner)"
            }.joined(separator: ", ") + "}"
        case "array":
            return "[" + shape(schema["items"] as? [String: Any] ?? [:], depth: depth + 1) + "]"
        case let t?: return t
        default: return "any"
        }
    }

    /// 0-1: how much of `query` is in `text`. Case- and accent-blind, word-based.
    static func match(_ query: String, _ text: String) -> Double {
        func words(_ s: String) -> [String] {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 || $0.first?.isNumber == true }
        }
        let q = Set(words(query)), t = Set(words(text))
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        let hit = Double(q.intersection(t).count)
        let coverage = hit / Double(q.count)          // did we find what was asked
        let focus = hit / Double(t.count)              // and not much else
        return (coverage * 0.85 + focus * 0.15).rounded(toPlaces: 2)
    }

    // MARK: Install and check (Quicky --extension …)

    static func cli(_ args: [String]) -> Int32 {
        let cmd = args.first ?? "list"
        let path = args.dropFirst().first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        switch cmd {
        case "list":
            for m in all { print("\(m.id) \(m.version)\(m.core ? " core" : "")\(isEnabled(m.id) ? "" : " (off)") · \(m.tools.map(\.fullName).joined(separator: ", ")) · \(m.dir.path)") }
            return 0
        case "check":
            guard let path else { print("usage: Quicky --extension check <folder>"); return 2 }
            let problems = Checker.check(path)
            print(problems.isEmpty ? "ok" : problems.map { "✗ \($0)" }.joined(separator: "\n"))
            return problems.isEmpty ? 0 : 1
        case "install":
            guard let path else { print("usage: Quicky --extension install <folder>"); return 2 }
            let problems = Checker.check(path, runExamples: false)
            guard problems.isEmpty else { print(problems.map { "✗ \($0)" }.joined(separator: "\n")); return 1 }
            guard let m = try? ExtensionManifest.load(path, core: false) else { return 1 }
            let link = installDir.appendingPathComponent(m.id)
            try? FileManager.default.removeItem(at: link)
            do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path) } catch { print("✗ \(error)"); return 1 }
            print("installed \(m.id) → \(link.path) (linked; edits apply on the next turn)")
            return 0
        case "remove":
            guard let id = args.dropFirst().first else { return 2 }
            try? FileManager.default.removeItem(at: installDir.appendingPathComponent(id))
            print("removed \(id)")
            return 0
        case "enable", "disable":
            guard let id = args.dropFirst().first else { return 2 }
            setEnabled(id, cmd == "enable"); print("\(id) \(cmd)d"); return 0
        default:
            print("usage: Quicky --extension list | check <folder> | install <folder> | remove <id> | enable <id> | disable <id>")
            return 2
        }
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double { let f = pow(10.0, Double(p)); return (self * f).rounded() / f }
}

/// The checks the directory runs before listing an extension (docs/extensions.md, "Where extensions live").
enum Checker {
    static func check(_ dir: URL, runExamples: Bool = true) -> [String] {
        var out: [String] = []
        let m: ExtensionManifest
        do { m = try ExtensionManifest.load(dir, core: false) } catch { return ["\(error)"] }
        for t in m.tools where t.output == nil { out.append("tool \(t.name) has no \"output\" schema") }
        for t in m.tools where (t.effect == .write || t.effect == .external) && t.description.count < 20 {
            out.append("tool \(t.name) changes things; its description must say what")
        }
        let size = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        if size > 1_000_000 { out.append("folder is \(size / 1000) KB; the limit is 1 MB") }
        if m.native { out.append("\"main\": \"native\" is only for core extensions") ; return out }
        guard let code = try? String(contentsOf: dir.appendingPathComponent(m.main), encoding: .utf8) else {
            return out + ["main file \(m.main) is missing"]
        }
        for bad in [#"\beval\s*\("#, #"\bnew\s+Function\b"#, #"\bFunction\s*\("#, #"\bimport\s*\("#, #"\brequire\s*\("#]
        where code.range(of: bad, options: .regularExpression) != nil {
            out.append("code uses \(bad.replacingOccurrences(of: #"\b"#, with: "").replacingOccurrences(of: #"\s*\("#, with: "(")), which extensions can't")
        }
        // Every literal https host in the code must be declared.
        let hostRe = try! NSRegularExpression(pattern: #"https?://([a-zA-Z0-9.-]+)"#)
        for r in hostRe.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            if let rr = Range(r.range(at: 1), in: code), !m.hosts.contains(String(code[rr])) {
                out.append("fetches \(code[rr]) but permissions.hosts doesn't list it")
            }
        }
        do {
            let rt = try JSExtension(m)
            let exported = Set(rt.exportedNames())
            for t in m.tools where !exported.contains(t.name) { out.append("tool \(t.name) is declared but index.js doesn't export it") }
            for e in exported.subtracting(m.tools.map(\.name)) { out.append("index.js exports \(e), which isn't declared") }
            guard runExamples else { return Array(Set(out)).sorted() }
            for t in m.tools {
                for ex in t.examples {
                    guard let input = ex["input"] as? [String: Any] else { continue }
                    let sem = DispatchSemaphore(value: 0)
                    var result: Result<Any, Error> = .failure(ExtensionManifest.Invalid(description: "no result"))
                    let t0 = Date()
                    Task.detached { do { result = .success(try await rt.call(t.name, input: input, timeoutMs: t.timeoutMs)) } catch { result = .failure(error) }; sem.signal() }
                    while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    switch result {
                    case .failure(let e): out.append("example \(t.name)(\(ExtensionHost.json(input))) failed: \(e)")
                    case .success(let v):
                        if let o = t.output, let p = ToolSchema.check(v, schema: o, path: "output") { out.append("example \(t.name): \(p)") }
                        if let expect = ex["expect"] as? String, !Expect.holds(expect, on: v) { out.append("example \(t.name): expected \(expect)") }
                        print("  \(t.name) example ok in \(ms) ms")
                    }
                }
            }
        } catch { out.append("index.js failed to load: \(error)") }
        return Array(Set(out)).sorted()
    }
}

/// Tiny expectations for examples: "results[0].artists contains Rahman", "results.length > 0", "title == X".
enum Expect {
    static func holds(_ e: String, on v: Any) -> Bool {
        let ops = [" contains ", " == ", " > ", " >= "]
        guard let op = ops.first(where: { e.contains($0) }) else { return true }
        let parts = e.components(separatedBy: op)
        guard parts.count == 2 else { return true }
        let lhs = value(at: parts[0].trimmingCharacters(in: .whitespaces), in: v)
        let rhs = parts[1].trimmingCharacters(in: .whitespaces)
        switch op {
        case " contains ": return "\(lhs ?? "")".localizedCaseInsensitiveContains(rhs)
        case " == ": return "\(lhs ?? "")" == rhs
        case " > ": return (Double("\(lhs ?? "")") ?? -.infinity) > (Double(rhs) ?? .infinity)
        default: return (Double("\(lhs ?? "")") ?? -.infinity) >= (Double(rhs) ?? .infinity)
        }
    }

    /// "results[0].title" → value; "results.length" → count.
    static func value(at path: String, in root: Any) -> Any? {
        var cur: Any? = root
        for part in path.split(separator: ".") {
            var key = String(part)
            var index: Int?
            if let b = key.firstIndex(of: "["), key.hasSuffix("]") {
                index = Int(key[key.index(after: b)..<key.index(before: key.endIndex)])
                key = String(key[..<b])
            }
            if key == "length" { return (cur as? [Any])?.count ?? (cur as? String)?.count }
            if !key.isEmpty { cur = (cur as? [String: Any])?[key] }
            if let index { cur = (cur as? [Any]).flatMap { index < $0.count ? $0[index] : nil } }
        }
        return cur
    }
}
