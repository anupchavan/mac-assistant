import Foundation

/// Picks the control an ask names, in code. "Join the subreddit" → the button labelled Join; "unfollow
/// them" → "Following ▾" (the state button that holds the undo), then Unfollow in the menu it opens.
/// The model is only asked when no single control clearly matches; guessing from forty labels is where
/// it went wrong (it pressed a selected tab, "More options", and then Block).
enum ControlPick {
    static let filler: Set<String> = ["the", "this", "that", "them", "him", "her", "it", "its", "their", "his", "a", "an",
                                      "please", "pls", "can", "could", "you", "just", "on", "to", "for", "me", "my", "now",
                                      "button", "page", "account", "profile", "channel", "subreddit", "post", "video", "user",
                                      "hey", "quicky", "and", "of", "in", "karo", "kar", "do", "isko", "ise", "ye", "yeh"]
    static let verbs: [String: String] = [  // spoken → label word
        "subscribe": "subscribe", "join": "join", "follow": "follow", "like": "like", "save": "save", "star": "star",
        "share": "share", "mute": "mute", "unmute": "unmute", "play": "play", "pause": "pause", "skip": "skip",
        "reply": "reply", "retweet": "repost", "repost": "repost", "bookmark": "bookmark", "upvote": "upvote", "downvote": "downvote",
        "accept": "accept", "decline": "decline", "dismiss": "dismiss", "close": "close", "expand": "expand", "collapse": "collapse",
    ]
    /// Undo verbs and the word the "already done" button shows: unfollow ↔ Following, leave ↔ Joined.
    static let undo: [String: (state: [String], item: [String])] = [
        "unfollow": (["following"], ["unfollow"]), "unsubscribe": (["subscribed"], ["unsubscribe"]),
        "leave": (["joined"], ["leave"]), "unlike": (["liked", "unlike"], ["unlike"]), "unsave": (["saved"], ["unsave", "remove"]),
        "unstar": (["starred"], ["unstar"]),
    ]

    struct Pick { let control: Control; let then: [String] }   // `then`: label words to press in what it opens

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// One clear target for the ask, or nil (the model decides). Only short asks that start with a known verb.
    static func pick(_ ask: String, in controls: [Control]) -> Pick? {
        let w = words(Reflex.normalize(ask)).filter { !filler.contains($0) }
        guard let verb = w.first, w.count <= 4 else { return nil }
        let rest = Set(w.dropFirst())
        let pageControls = controls.filter { !["radio", "tab"].contains($0.role) && !Controls.textRoles.contains($0.role) }
        func first(_ c: Control) -> String { words(c.label).first ?? "" }
        func best(_ cands: [Control]) -> Control? {
            // More of the ask's other words in the label wins ("save post" over "save draft"); a tie is ambiguous.
            let scored = cands.map { c in (c, Set(words(c.label)).intersection(rest).count) }
            guard let top = scored.max(by: { $0.1 < $1.1 }) else { return nil }
            return scored.filter { $0.1 == top.1 }.count == 1 ? top.0 : nil
        }
        if let u = undo[verb] {
            let cands = pageControls.filter { u.state.contains(first($0)) || u.item.contains(first($0)) }
            guard let c = best(cands) else { return nil }
            return Pick(control: c, then: u.item.contains(first(c)) ? [] : u.item)
        }
        guard let labelWord = verbs[verb] else { return nil }
        let cands = pageControls.filter { first($0) == labelWord && $0.state != "on" }
        guard let c = best(cands) else { return nil }
        return Pick(control: c, then: [])
    }

    /// In what a press opened, the item whose first word is one of `wanted`.
    static func item(_ wanted: [String], in opened: [Control]) -> Control? {
        let hits = opened.filter { wanted.contains(words($0.label).first ?? "") }
        return hits.count == 1 ? hits[0] : nil
    }
}
