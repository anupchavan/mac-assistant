import Foundation

/// Checks a tool call's arguments against the declaration the model was given, before anything runs.
/// The model gets the exact problem back as the tool result and may try again (twice per turn, see
/// AppModel.maxRepairs). Shape comes from the schema; a few values we can verify (URLs) are checked too.
enum ToolSchema {
    /// nil when the call is fine to run, else one line for the model saying exactly what to fix.
    static func problem(_ call: ToolCall, tools: [[String: Any]]) -> String? {
        let decls = tools.compactMap { $0["function"] as? [String: Any] }
        guard let decl = decls.first(where: { $0["name"] as? String == call.name }) else {
            let names = decls.compactMap { $0["name"] as? String }.joined(separator: ", ")
            return "error: there is no tool named \"\(call.name)\". Tools: \(names)"
        }
        let raw = call.rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = raw.isEmpty ? [String: Any]() : (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        guard var args = parsed else {
            return "error: \(call.name) arguments are not a JSON object: \(raw.prefix(120))"
        }
        // open_url and close_tabs also take a single "url" (ToolCall.urlList merges them).
        if ["open_url", "close_tabs"].contains(call.name), args["urls"] == nil, let one = args["url"] as? String { args["urls"] = [one] }
        let schema = decl["parameters"] as? [String: Any] ?? ["type": "object"]
        if let p = check(args, schema: schema, path: "") { return "error: \(call.name): \(p)" }
        if let p = valueProblem(call.name, args) { return "error: \(call.name): \(p)" }
        return nil
    }

    /// The first mismatch between a value and its JSON Schema, as "path: what's wrong".
    static func check(_ value: Any, schema: [String: Any], path: String) -> String? {
        let at = path.isEmpty ? "arguments" : path
        if let type = schema["type"] as? String, !matches(value, type) {
            return "\(at) should be \(article(type)), got \(describe(value))"
        }
        if let options = schema["enum"] as? [Any], !options.contains(where: { "\($0)" == "\(value)" }) {
            return "\(at) must be one of \(options.map { "\"\($0)\"" }.joined(separator: ", ")), got \(describe(value))"
        }
        if let obj = value as? [String: Any] {
            let props = schema["properties"] as? [String: Any] ?? [:]
            for key in (schema["required"] as? [String]) ?? [] where obj[key] == nil || obj[key] is NSNull {
                return "missing required \"\(join(path, key))\""
            }
            // Extra keys are ignored: the tool never reads them, and a repair round costs a whole model call.
            for key in obj.keys.sorted() {
                if let sub = props[key] as? [String: Any], let v = obj[key], !(v is NSNull),
                   let p = check(v, schema: sub, path: join(path, key)) { return p }
            }
        }
        if let arr = value as? [Any] {
            if let max = schema["maxItems"] as? Int, arr.count > max { return "\(at) has \(arr.count) items, at most \(max) allowed" }
            if let min = schema["minItems"] as? Int, arr.count < min { return "\(at) has \(arr.count) items, at least \(min) needed" }
            if let items = schema["items"] as? [String: Any] {
                for (i, v) in arr.enumerated() { if let p = check(v, schema: items, path: "\(at)[\(i)]") { return p } }
            }
        }
        return nil
    }

    /// Checks the schema can't express. Kept to values we can verify for certain.
    static func valueProblem(_ tool: String, _ args: [String: Any]) -> String? {
        if tool == "open_url" || tool == "close_tabs" {
            let urls = (args["urls"] as? [String] ?? []) + [args["url"] as? String].compactMap { $0 }
            if urls.isEmpty { return "\"urls\" is empty" }
            if tool == "open_url", let bad = urls.first(where: { !isWebURL($0) }) {
                return "\"\(bad)\" is not a full URL; pass complete https:// URLs"
            }
        }
        return nil
    }

    static func isWebURL(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased() else { return false }
        if ["http", "https"].contains(scheme) { return (u.host ?? "").contains(".") || u.host == "localhost" }
        return !["javascript", "file", "data"].contains(scheme)   // app links like spotify: or mailto: are fine
    }

    private static func matches(_ v: Any, _ type: String) -> Bool {
        switch type {
        case "string": return v is String
        // JSONSerialization gives NSNumber for numbers and booleans; tell them apart by objCType.
        case "integer": guard let n = v as? NSNumber, !isBool(n) else { return false }; return n.doubleValue.rounded() == n.doubleValue
        case "number": guard let n = v as? NSNumber else { return false }; return !isBool(n)
        case "boolean": guard let n = v as? NSNumber else { return false }; return isBool(n)
        case "array": return v is [Any]
        case "object": return v is [String: Any]
        default: return true
        }
    }

    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    private static func describe(_ v: Any) -> String {
        if let s = v as? String { return "the string \"\(s.prefix(60))\"" }
        if let n = v as? NSNumber { return isBool(n) ? "a boolean" : "the number \(n)" }
        if v is [Any] { return "an array" }
        if v is [String: Any] { return "an object" }
        return "null"
    }

    private static func article(_ type: String) -> String { type == "array" || type == "object" || type == "integer" ? "an \(type)" : "a \(type)" }
    private static func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
}
