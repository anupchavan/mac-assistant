import Foundation

enum Route: String, Codable { case fast, deep, agent, computer }

/// Pure-code rule pass (prompts.md §3 and §11.1). Runs in well under a millisecond.
enum Router {
    static let computerVerbs = #"(?i)\b(block|unblock|mute|unmute|unfollow|follow|report|unsubscribe|archive|like|retweet|repost|star|pin|turn (on|off)|enable|disable|click|toggle|go to settings)\b"#
    static let computerHi = #"(?i)((block|mute|unfollow|unsubscribe) kar(o|do)|chalu kar(o|do))"#
    static let agentVerbs = #"(?i)\b(open|launch|send|email|reply to|schedule|add (this|it)? ?to (my )?(calendar|reminders?)|remind me|create|make a (note|reminder|event)|move|rename|copy (these|this) to|copy|insert|type (this|it)|paste|save|search for|google|play|set (a )?timer|run)\b"#
    /// Things a shortcut or a click does in the front app (press_shortcut / use_computer).
    static let actionVerbs = #"(?i)\b(close|quit|exit|minimi[sz]e|hide|maximi[sz]e|full ?screen|reload|refresh|go (back|forward)|new (tab|window)|reopen|scroll|zoom( in| out)?|pause|resume|bookmark|find|select all|undo|redo|switch to|go to)\b"#
    static let agentHi = #"(?i)(kholo|khol do|bhejo|bana do|add karo|yaad dila|move karo|save karo|chalao|copy karo|likh do|band? ?kar(o|do| do)|bandh? kar|peeche jao|piche jao|wapas jao|aage jao|refresh karo|reload karo|scroll karo|zoom karo|chhota karo|bada karo|pause karo|play karo|undo karo|hata do|naya tab)"#
    /// "can you …", "please …": an ask to do something, so give it tools.
    static let request = #"(?i)^\s*(hey\s+)?((can|could|will|would) you|please|pls|kya tum|kya aap)\b"#
    static let deepCues = #"(?i)\b(why|prove|compare|debug|explain (in detail|step by step)|what'?s wrong|optimi[sz]e|plan|analy[sz]e|review)\b"#
    /// Things our native tools already do; those never go to computer use.
    static let nativeCovers = #"(?i)\b(calendar|reminder|remind|open (the )?(url|link|app|file)|move (these|this|the) files?|clipboard|copy)\b"#

    static func matches(_ t: String, _ pattern: String) -> Bool {
        t.range(of: pattern, options: .regularExpression) != nil
    }

    static func route(_ ask: String, app: String, computerUseAvailable: Bool) -> Route {
        // One word ("Click.", "Block") never names a target, so it never goes straight to computer use.
        let words = ask.split(whereSeparator: { $0.isWhitespace }).count
        if computerUseAvailable, words >= 2, matches(ask, computerVerbs) || matches(ask, computerHi), !matches(ask, nativeCovers) {
            return .computer
        }
        if matches(ask, agentVerbs) || matches(ask, agentHi) || matches(ask, actionVerbs) || matches(ask, request) { return .agent }
        let codeApp = app.contains("Xcode") || app.contains("Code") || app.contains("Cursor") || app.contains("Terminal") || app.contains("iTerm")
        if codeApp, matches(ask, deepCues) { return .deep }
        if ask.count > 280 { return .deep }
        return .fast
    }
}
