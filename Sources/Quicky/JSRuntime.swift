import AppKit
import CryptoKit
import Foundation
import JavaScriptCore

struct JSError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Resumes a continuation exactly once: whichever of result, error or timeout comes first wins.
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { self.c = c }
    func finish(_ r: Result<T, Error>) {
        lock.lock(); let k = c; c = nil; lock.unlock()
        k?.resume(with: r)
    }
}

/// One extension's code, loaded once into its own JavaScript context (docs/extensions.md). Every touch of
/// the context happens on `queue`, so an extension never runs two pieces of JS at once, while different
/// extensions run in parallel.
final class JSExtension: @unchecked Sendable {
    let manifest: ExtensionManifest
    private let queue: DispatchQueue
    private let ctx: JSContext

    init(_ m: ExtensionManifest) throws {
        manifest = m
        let queue = DispatchQueue(label: "quicky.ext.\(m.id)")
        self.queue = queue
        let file = m.dir.appendingPathComponent(m.main)
        guard let code = try? String(contentsOf: file, encoding: .utf8) else { throw JSError("can't read \(m.main)") }
        var made: JSContext?
        var failure: String?
        queue.sync {
            let ctx = JSContext(virtualMachine: JSVirtualMachine())!
            ctx.name = "Quicky · \(m.id)"
            ctx.exceptionHandler = { _, e in failure = failure ?? e.map(JSBridge.describe) }
            JSBridge.install(in: ctx, queue: queue, scope: .extension(m))
            ctx.evaluateScript("var module = { exports: {} }; var exports = module.exports;")
            ctx.evaluateScript(code, withSourceURL: file)
            ctx.evaluateScript(JSBridge.invokePrelude)
            made = ctx
        }
        if let failure { throw JSError(failure) }
        ctx = made!
        ctx.exceptionHandler = { _, e in Log.error("ext \(m.id): \(e.map(JSBridge.describe) ?? "exception")") }
    }

    /// Names of the functions index.js exports.
    func exportedNames() -> [String] {
        queue.sync {
            let v = ctx.evaluateScript("JSON.stringify(Object.keys(module.exports).filter(k => typeof module.exports[k] === 'function'))")
            return (try? JSONSerialization.jsonObject(with: Data((v?.toString() ?? "[]").utf8))) as? [String] ?? []
        }
    }

    /// Calls `exports[tool](input, q)` and waits for its promise. The output comes back through
    /// JSON.stringify, so it is always plain JSON (undefined becomes null).
    func call(_ tool: String, input: [String: Any], timeoutMs: Int) async throws -> Any {
        let inputJSON = ExtensionHost.json(input)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
            let once = Once(c)
            // The timer runs off the extension's queue, so a call that blocks that queue still times out.
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { once.finish(.failure(JSError("timed out after \(timeoutMs) ms"))) }
            queue.async { [ctx] in
                let ok: @convention(block) (JSValue) -> Void = { v in once.finish(.success(JSBridge.parse(v.toString()))) }
                let fail: @convention(block) (JSValue) -> Void = { e in once.finish(.failure(JSError(e.toString()))) }
                ctx.objectForKeyedSubscript("__invoke").call(withArguments: [tool, inputJSON, JSBridge.fn(ok, ctx), JSBridge.fn(fail, ctx)])
            }
        }
    }

    /// For tests: evaluates an expression in the extension's context and returns it as JSON.
    func evaluate(_ expression: String) -> Any {
        queue.sync { JSBridge.parse(ctx.evaluateScript("JSON.stringify(\(expression))")?.toString() ?? "null") }
    }
}

/// The native side of `q` (and of `run` programs): fetch, cache, secrets, AppleScript, timers.
enum JSBridge {
    enum Scope {
        case `extension`(ExtensionManifest)
        case program(Composer.Budget)
    }

    static let invokePrelude = """
    globalThis.__invoke = function (name, inputJSON, ok, fail) {
      const msg = e => String((e && e.message) || e)
      try {
        const fn = module.exports[name]
        if (typeof fn !== 'function') return fail('no exported function ' + name)
        Promise.resolve(fn(JSON.parse(inputJSON), q)).then(v => ok(JSON.stringify(v === undefined ? null : v)), e => fail(msg(e)))
      } catch (e) { fail(msg(e)) }
    }
    """

    static let qPrelude = """
    var q = {
      country: __country,
      fetch: (url, o) => new Promise((res, rej) => __fetch(String(url), JSON.stringify(o || {}),
        (status, headers, body) => res({ status, ok: status >= 200 && status < 300, headers: JSON.parse(headers),
                                         text: async () => body, json: async () => JSON.parse(body) }),
        e => rej(new Error(e)))),
      cache: {
        get: k => { const v = __cacheGet(String(k)); return v === undefined || v === null ? undefined : JSON.parse(v) },
        set: (k, v, ttl) => __cacheSet(String(k), JSON.stringify(v === undefined ? null : v), Number(ttl) || 86400),
      },
      secret: n => __secret(String(n)),
      applescript: s => new Promise((res, rej) => __applescript(String(s), res, e => rej(new Error(e)))),
      match: (a, b) => __match(String(a || ''), String(b || '')),
      log: (...a) => __log(a.map(x => typeof x === 'string' ? x : JSON.stringify(x)).join(' ')),
      call: (tool, input) => new Promise((res, rej) => __call(String(tool), JSON.stringify(input || {}), v => res(JSON.parse(v)), e => rej(new Error(e)))),
      sleep: ms => new Promise(r => setTimeout(r, ms)),
    };
    var console = { log: q.log, warn: q.log, error: q.log };
    """

    static func fn<T>(_ block: T, _ ctx: JSContext) -> JSValue { JSValue(object: unsafeBitCast(block, to: AnyObject.self), in: ctx) }

    static func parse(_ s: String?) -> Any {
        guard let s, let v = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed) else { return NSNull() }
        return v
    }

    static func describe(_ e: JSValue) -> String {
        let line = e.objectForKeyedSubscript("line").map { $0.isUndefined ? "" : " (line \($0.toInt32()))" } ?? ""
        return (e.toString() ?? "exception") + line
    }

    static func install(in ctx: JSContext, queue: DispatchQueue, scope: Scope) {
        func set<T>(_ name: String, _ block: T) { ctx.setObject(unsafeBitCast(block, to: AnyObject.self), forKeyedSubscript: name as NSString) }
        let label: String
        switch scope { case .extension(let m): label = m.id; case .program: label = "run" }

        let log: @convention(block) (String) -> Void = { Log.info("[\(label)] \($0.prefix(500))") }
        set("__log", log)
        let match: @convention(block) (String, String) -> Double = { ExtensionHost.match($0, $1) }
        set("__match", match)
        let timeout: @convention(block) (JSValue, Double) -> Void = { f, ms in
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(max(0, ms)))) { f.call(withArguments: []) }
        }
        set("setTimeout", timeout)
        // Any tool, from a program or another extension, with that tool's own confirm rules.
        let budget: Composer.Budget? = { if case .program(let b) = scope { return b }; return nil }()
        let callTool: @convention(block) (String, String, JSValue, JSValue) -> Void = { name, inputJSON, ok, fail in
            let input = parse(inputJSON) as? [String: Any] ?? [:]
            Task.detached {
                let r = await Composer.callTool(name, input, budget: budget)
                queue.async {
                    switch r {
                    case .success(let json): ok.call(withArguments: [json])
                    case .failure(let e): fail.call(withArguments: [e.description])
                    }
                }
            }
        }
        set(budget == nil ? "__call" : "__tool", callTool)

        guard case .extension(let m) = scope else { return }
        ctx.setObject(ExtensionHost.country, forKeyedSubscript: "__country" as NSString)

        let fetch: @convention(block) (String, String, JSValue, JSValue) -> Void = { url, optsJSON, ok, failJS in
            let fail = { (s: String) in queue.async { failJS.call(withArguments: [s]) } }
            guard let u = URL(string: url), let host = u.host, u.scheme == "https" || u.scheme == "http" else { return fail("bad url \(url)") }
            guard m.hosts.contains(host) else { return fail("\(host) isn't in permissions.hosts") }
            let o = parse(optsJSON) as? [String: Any] ?? [:]
            var req = URLRequest(url: u)
            req.httpMethod = (o["method"] as? String)?.uppercased() ?? "GET"
            req.timeoutInterval = ((o["timeoutMs"] as? NSNumber)?.doubleValue ?? 8000) / 1000
            req.setValue("Quicky/0.2 (https://github.com/anupchavan/quicky; extension \(m.id))", forHTTPHeaderField: "User-Agent")
            for (k, v) in o["headers"] as? [String: Any] ?? [:] { req.setValue("\(v)", forHTTPHeaderField: k) }
            if let b = o["body"] {
                req.httpBody = (b as? String).map { Data($0.utf8) } ?? (try? JSONSerialization.data(withJSONObject: b))
                if b is [String: Any] || b is [Any], req.value(forHTTPHeaderField: "Content-Type") == nil {
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                if req.httpMethod == "GET" { req.httpMethod = "POST" }
            }
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err { return fail(err.localizedDescription) }
                let http = resp as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)".lowercased()] = "\(v)" }
                let body = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
                if let code = http?.statusCode, !(200..<300).contains(code) { Log.info("[\(m.id)] http \(code) \(host)\(u.path)") }
                queue.async { ok.call(withArguments: [http?.statusCode ?? 0, ExtensionHost.json(headers), body]) }
            }.resume()
        }
        set("__fetch", fetch)

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quicky/extensions/\(m.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        func cacheFile(_ key: String) -> URL {
            cacheDir.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".json")
        }
        let cacheGet: @convention(block) (String) -> String? = { key in
            guard let d = try? Data(contentsOf: cacheFile(key)), let e = parse(String(data: d, encoding: .utf8)) as? [String: Any],
                  let exp = (e["exp"] as? NSNumber)?.doubleValue, exp > Date().timeIntervalSince1970 else { return nil }
            return e["v"].map { ExtensionHost.jsonValue($0) }
        }
        set("__cacheGet", cacheGet)
        let cacheSet: @convention(block) (String, String, Double) -> Void = { key, json, ttl in
            let e: [String: Any] = ["exp": Date().timeIntervalSince1970 + ttl, "v": parse(json)]
            try? JSONSerialization.data(withJSONObject: e, options: .fragmentsAllowed).write(to: cacheFile(key))
        }
        set("__cacheSet", cacheSet)

        let secret: @convention(block) (String) -> String? = { name in
            guard m.secrets.contains(name) else { Log.error("[\(m.id)] asked for undeclared secret \(name)"); return nil }
            return Keychain.get(name).flatMap { $0.isEmpty ? nil : $0 } ?? Keys.lookup([name])
        }
        set("__secret", secret)

        let script: @convention(block) (String, JSValue, JSValue) -> Void = { src, ok, fail in
            let apps = appNames(in: src)
            if let bad = apps.first(where: { !m.applescriptApps.contains($0) }) {
                queue.async { fail.call(withArguments: ["\(bad) isn't in permissions.applescript"]) }; return
            }
            // One answer per call: the script's, or a timeout (an Automation prompt or a hung app can block for minutes).
            let answered = Locked(false)
            func answer(_ f: @escaping () -> Void) { if !answered.swap(true) { queue.async(execute: f) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { answer { fail.call(withArguments: ["AppleScript took over 3 s (is Automation allowed for Quicky?)"]) } }
            scriptQueue.async {
                // Never launch an app just to ask it something.
                let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
                guard apps.allSatisfy(running.contains) else { return answer { ok.call(withArguments: [""]) } }
                var err: NSDictionary?
                let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
                answer {
                    if let err { fail.call(withArguments: [err[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"]) }
                    else { ok.call(withArguments: [out ?? ""]) }
                }
            }
        }
        set("__applescript", script)

        ctx.evaluateScript(qPrelude)
    }

    static let scriptQueue = DispatchQueue(label: "quicky.applescript")

    /// The apps an AppleScript talks to: `tell application "Music"`, `application id …` isn't allowed.
    static func appNames(in src: String) -> Set<String> {
        let re = try! NSRegularExpression(pattern: #"application\s+"([^"]+)""#, options: .caseInsensitive)
        var out = Set(re.matches(in: src, range: NSRange(src.startIndex..., in: src)).compactMap { Range($0.range(at: 1), in: src).map { String(src[$0]) } })
        if src.range(of: #"application\s+id\b"#, options: [.regularExpression, .caseInsensitive]) != nil { out.insert("application id") }
        return out
    }
}

/// The `run` tool: the model writes one short program that calls several tools and pipes one's output
/// into the next, so "find it and download it" is one model trip, and `pick` keeps a chain from acting on
/// the wrong item.
enum Composer {
    static let timeout: TimeInterval = 15
    static let maxCalls = 20
    static let maxBytes = 64_000

    /// Core tools a program may call besides the extensions' (native core extensions, like web search, too).
    static let coreTools: Set<String> = ["open_url", "copy_to_clipboard"]

    /// Shows the confirm card for a write/external call; set by AppModel. Without it, such calls are refused.
    static let confirm = Locked<(@Sendable (ToolCall) async -> Bool)?>(nil)

    static let declaration: [String: Any] = [
        "type": "function",
        "function": [
            "name": "run",
            "description": """
            Run a short JavaScript program that calls several tools in one go, when one tool's output feeds another \
            (find a song, then open or download it). Every tool you have is an async function taking its usual \
            arguments: `const { results } = await music_search({ query: "…" })`; open_url and copy_to_clipboard \
            too. Before acting on a found item, choose it with `pick(items, { title, artists, seconds })`: it \
            returns the item that clearly matches, or stops and asks the user. `ask(question, options)` asks \
            directly. Return a short sentence to have it said as is, or data for you to phrase. Limits: 15 s, \
            20 tool calls. For a single lookup, call the tool directly instead.
            """,
            "parameters": ["type": "object",
                           "properties": ["program": ["type": "string", "description": "The body of an async function; use await and return"]],
                           "required": ["program"]],
        ] as [String: Any],
    ]

    final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0, bytes = 0
        func spend(_ result: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            calls += 1; bytes += result.utf8.count
            if calls > Composer.maxCalls { return "more than \(Composer.maxCalls) tool calls in one program" }
            if bytes > Composer.maxBytes { return "tools returned more than \(Composer.maxBytes / 1000) KB in one program" }
            return nil
        }
    }

    static let declined = "__declined__"

    static let programPrelude = """
    class __Ask extends Error { constructor(question, options) { super('ask'); this.question = question; this.options = options } }
    function ask(question, options) { throw new __Ask(String(question), (options || []).map(String)) }
    function __label(x) {
      if (typeof x !== 'object' || !x) return String(x)
      const who = x.artists || x.artist || x.channel || x.author
      return [x.title || x.name || x.query, who ? 'by ' + who : '', x.year ? '(' + x.year + ')' : ''].filter(Boolean).join(' ')
    }
    function pick(items, want) {
      items = Array.isArray(items) ? items.filter(x => x && typeof x === 'object') : []
      want = want || {}
      if (!items.length) throw new __Ask("I couldn't find it. What exactly should I look for?", [])
      const keys = Object.keys(want).filter(k => k !== 'seconds' && typeof want[k] === 'string' && want[k])
      const near = (a, b) => typeof a !== 'number' || typeof b !== 'number' || Math.abs(a - b) <= 5
      const scored = items.map(it => {
        let s = keys.length ? keys.reduce((a, k) => a + __match(want[k], String(it[k] || '')), 0) / keys.length
                            : (typeof it.match === 'number' ? it.match : 0)
        if (typeof want.seconds === 'number' && !near(want.seconds, it.seconds)) s = 0
        return { it, s }
      }).sort((a, b) => b.s - a.s)
      const fields = [...new Set(keys.concat(['title', 'artists']))]   // same recording: same names and length
      const same = (a, b) => fields.every(k => String(a[k] || '').toLowerCase() === String(b[k] || '').toLowerCase()) && near(a.seconds, b.seconds)
      const top = scored[0], rival = scored.slice(1).find(x => !same(x.it, top.it))
      if (top.s >= 0.8 && (!rival || top.s - rival.s >= 0.15)) return top.it
      throw new __Ask('Which one', scored.slice(0, 3).map(x => __label(x.it)))
    }
    """

    /// Runs one program. Returns text for the model and for AppModel.localReply:
    /// "say: …" (speak as is), "ask: …" (a question for the user), "error: …", or the returned JSON.
    static func run(_ program: String) async -> String {
        let t0 = Date()
        let names = ExtensionHost.enabled.flatMap { $0.tools.map(\.fullName) } + Array(coreTools)
        let budget = Budget()
        let queue = DispatchQueue(label: "quicky.run")
        let out: String
        do {
            out = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                let once = Once(c)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(.failure(JSError("the program ran over \(Int(timeout)) s"))) }
                queue.async {
                    let ctx = JSContext(virtualMachine: JSVirtualMachine())!
                    ctx.name = "Quicky · run"
                    ctx.exceptionHandler = { _, e in once.finish(.failure(JSError(e.map(JSBridge.describe) ?? "exception"))) }
                    JSBridge.install(in: ctx, queue: queue, scope: .program(budget))
                    let done: @convention(block) (String) -> Void = { once.finish(.success(result(fromJSON: $0))) }
                    let asked: @convention(block) (String) -> Void = { once.finish(.success("ask: " + question(fromJSON: $0))) }
                    let fail: @convention(block) (String) -> Void = { once.finish($0 == declined ? .success("say: Cancelled.") : .failure(JSError($0))) }
                    ctx.setObject(unsafeBitCast(done, to: AnyObject.self), forKeyedSubscript: "__done" as NSString)
                    ctx.setObject(unsafeBitCast(asked, to: AnyObject.self), forKeyedSubscript: "__asked" as NSString)
                    ctx.setObject(unsafeBitCast(fail, to: AnyObject.self), forKeyedSubscript: "__fail" as NSString)
                    ctx.evaluateScript(programPrelude)
                    ctx.evaluateScript("""
                    for (const n of \(ExtensionHost.json(names))) globalThis[n] = input => new Promise((res, rej) =>
                      __tool(n, JSON.stringify(input || {}), v => res(JSON.parse(v)), e => rej(new Error(e))))
                    """)
                    ctx.evaluateScript("""
                    (async function () {
                    \(program)
                    })().then(v => __done(JSON.stringify(v === undefined ? null : v)),
                              e => e instanceof __Ask ? __asked(JSON.stringify({ question: e.question, options: e.options }))
                                                      : __fail(String((e && e.message) || e)))
                    """, withSourceURL: URL(string: "quicky://run.js"))
                }
            }
        } catch {
            Log.time("run failed: \(error)", since: t0)
            return "error: \(error)"
        }
        Log.time("run → \(out.prefix(160))", since: t0)
        return out
    }

    private static func result(fromJSON s: String) -> String {
        let v = JSBridge.parse(s)
        if let text = v as? String { return "say: " + text }
        return ExtensionHost.json(v)
    }

    /// {question, options} → "Which one: Nanchaku by Seedhe Maut (2019), or Nanchaku (Remix) by …?"
    static func question(fromJSON s: String) -> String {
        let j = JSBridge.parse(s) as? [String: Any] ?? [:]
        let q = (j["question"] as? String ?? "Which one").trimmingCharacters(in: CharacterSet(charactersIn: "?: "))
        let opts = (j["options"] as? [String] ?? []).filter { !$0.isEmpty }
        switch opts.count {
        case 0: return q + "?"
        case 1: return "\(q): \(opts[0])?"
        default: return "\(q): " + opts.dropLast().joined(separator: ", ") + ", or \(opts.last!)?"
        }
    }

    /// One tool call from a program (or from an extension's q.call). Returns the result as JSON text.
    static func callTool(_ name: String, _ input: [String: Any], budget: Budget?) async -> Result<String, JSError> {
        let call = ToolCall(id: "run", name: name, arguments: input, rawArguments: ExtensionHost.json(input))
        let found = ExtensionHost.tool(name)
        guard found != nil || coreTools.contains(name) else { return .failure(JSError("no tool named \(name)")) }
        if case let (m, t)? = found, t.effect == .write || t.effect == .external {
            guard let confirm = confirm.value else { return .failure(JSError("\(name) needs the user's confirmation, which isn't available here")) }
            guard await confirm(call) else { return .failure(JSError(declined)) }
            Log.info("run: \(m.id) \(t.name) confirmed")
        }
        let text: String
        if case let (m, t)? = found, !m.native {
            let r = await ExtensionHost.invoke(m, t, input)
            if let e = r.error { return .failure(JSError("\(name): \(e)")) }
            text = ExtensionHost.jsonValue(r.value ?? NSNull())
        } else {
            if let p = ToolSchema.problem(call, tools: Tools.declarations) { return .failure(JSError(p)) }
            let r = await Tools.run(call, insertInto: nil)
            if r.hasPrefix("error") { return .failure(JSError(r)) }
            // Actions the user sees happen report "done", so a program that ends on one needs no words.
            switch name {
            case "open_url": text = ExtensionHost.jsonValue(["done": true, "opened": call.urlList])
            case "copy_to_clipboard": text = ExtensionHost.jsonValue(["done": true, "say": "Copied."])
            default: text = ExtensionHost.jsonValue(r)
            }
        }
        if let budget, let over = budget.spend(text) { return .failure(JSError(over)) }
        return .success(text)
    }

    /// What to say for a finished `run` (or an extension tool's JSON result) without another model trip,
    /// or nil to let the model phrase it.
    static func spoken(_ result: String) -> String? {
        if result.hasPrefix("say: ") || result.hasPrefix("ask: ") { return String(result.dropFirst(5)) }
        guard result.hasPrefix("{"), let j = JSBridge.parse(result) as? [String: Any] else { return nil }
        if let s = j["say"] as? String { return s }
        if j["done"] as? Bool == true { return "" }
        return nil
    }
}
