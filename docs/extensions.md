# Quicky extensions

An extension gives Quicky new abilities (music, Telegram, a company's API) without making every turn slower or every prompt longer. This is the standard for writing one, and for how Quicky runs, combines and distributes them.

Three goals, in order: **speed** (no extra model round trips, nothing spawned per call), **accuracy** (a chain never acts on the wrong item), **flow** (one ask can search, check and act in one go).

## Why not MCP as the runtime

MCP is a fine wire protocol, and the slowness people feel isn't the protocol. Measured on Anup's Mac (stdio JSON-RPC, 500 calls): a Python server starts in 137 ms, a Node one in 221 ms, and each call then takes about 0.01 ms (p99 0.04 ms). Starting the same server with `npx -y` takes 2.2 s. What makes MCP setups slow is everything around it:

- **Model round trips.** Every tool call is a trip back to the model (0.5–1 s on Gemini Flash from India). "Search then download" is two or three trips, plus the wrong pick when the model has to guess between them. That cost is the same whether the tool is MCP or ours.
- **Cold processes.** Servers are separate processes, often `npx`/`uvx`, which start in 0.3–2 s and sometimes download first.
- **Tool lists.** Clients send every tool of every server on every turn, so prompts grow with each install. Raycast-style "search for tools" trades that for another round trip.

So Quicky runs extensions in-process (JavaScriptCore, built into macOS), shows the model only the extensions an ask needs (picked while the user is still speaking), and lets the model chain tools in **one** call (`run`, below). MCP stays possible later as an adapter: an extension whose manifest points at an MCP server, kept warm, its tools mapped to ours.

## What an extension is

A folder:

```
music/
  extension.json    the manifest: what it does, its tools, what it may touch
  index.js          the code (one file; bundle with esbuild if you use modules)
  README.md         for the directory listing
```

### extension.json

```json
{
  "id": "music",
  "name": "Music",
  "version": "0.1.0",
  "description": "Songs, albums, lyrics and credits, including soundtracks and songs not on Apple Music here.",
  "when": "The user wants to know something about a song, album, artist or soundtrack, wants lyrics, or asks what's playing.",
  "cues": ["song", "lyrics?", "album", "soundtrack", "ost", "singer", "sang"],
  "permissions": {
    "hosts": ["music.youtube.com", "itunes.apple.com", "lrclib.net", "musicbrainz.org"],
    "applescript": ["Music", "Spotify"],
    "secrets": []
  },
  "main": "index.js",
  "tools": {
    "search": {
      "description": "Find songs, albums or artists, including OSTs and songs not on Apple Music here.",
      "effect": "read",
      "timeoutMs": 4000,
      "input": { "type": "object", "properties": { "query": { "type": "string" }, "kind": { "type": "string", "enum": ["song", "album", "artist"] } }, "required": ["query"] },
      "output": { "type": "object", "properties": { "results": { "type": "array", "items": { "type": "object", "properties": {
        "title": { "type": "string" }, "artists": { "type": "string" }, "album": { "type": "string" }, "year": { "type": "string" },
        "seconds": { "type": "number" }, "apple": { "type": "string" }, "youtube": { "type": "string" }, "match": { "type": "number" } } } } } },
      "examples": [{ "input": { "query": "kun faya kun" }, "expect": "results[0].artists contains Rahman" }]
    }
  }
}
```

| Field | Meaning |
|---|---|
| `id` | Lowercase letters, digits and `-`. Tools reach the model as `<id>_<tool>` (`music_search`). |
| `when` | One sentence the picker judges each ask against. Describe **asks**, not features. |
| `cues` | Words (regex) that pick the extension instantly, without waiting for the picker. Keep them specific: "song" yes, "play" no. |
| `permissions.hosts` | The only hosts `fetch` may reach. Subdomains must be listed. |
| `permissions.applescript` | Apps the extension may script. Quicky never launches them; scripts run only if the app is open. |
| `permissions.secrets` | Names of keys it reads (set in Quicky's Settings or `~/.zshrc`). Never shipped in the extension. |
| `tools.*.effect` | `read`: looks things up, may run early and in parallel. `local`: creates files on this Mac, nothing else. `write`: changes the user's data or accounts; Quicky shows a confirm card. `external`: others will see it (sends, posts); always confirmed. |
| `tools.*.input` / `output` | JSON Schema. Inputs are checked before your code runs; a bad call goes back to the model with the exact error. Outputs are what other tools and programs pipe on, so they are part of your API. |
| `tools.*.examples` | Real calls with an expectation. `quicky --extension check` runs them; the directory runs them again on every version. |

### index.js

```js
exports.search = async (input, q) => {
  const res = await q.fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(input.query)}&entity=song&country=${q.country}`)
  const { results } = await res.json()
  return {
    results: results.map(r => ({
      title: r.trackName, artists: r.artistName, album: r.collectionName,
      year: (r.releaseDate || "").slice(0, 4), seconds: r.trackTimeMillis / 1000,
      apple: r.trackViewUrl, match: q.match(input.query, `${r.trackName} ${r.artistName}`),
    })),
  }
}
```

Each export is a tool: `async (input, q) => output`. Throw an `Error` to fail. The message goes back to the model as `error: …`.

The code runs in JavaScriptCore, not Node or a browser: modern JavaScript (async/await, classes, `\p{L}` regexes) works, but there is no `URL`, `TextDecoder`, `setInterval` or DOM. `setTimeout` and `q.sleep(ms)` exist. Top-level functions stay private; only `exports` are tools.

### The `q` object (all an extension can touch)

| | |
|---|---|
| `q.fetch(url, {method, headers, body, timeoutMs})` | Like `fetch`, limited to `permissions.hosts`. Returns `{status, headers, text(), json()}`. Connections are pooled and kept warm. |
| `q.cache.get(key)` / `q.cache.set(key, value, ttlSeconds)` | Per-extension disk cache. Use it for anything rate-limited. |
| `q.secret(name)` | A key named in `permissions.secrets`, or `null`. |
| `q.applescript(source)` | Runs AppleScript for the apps in `permissions.applescript`. Returns the result as text. |
| `q.match(query, text)` | 0–1 similarity score: word overlap, accent- and case-blind, title-aware. Use it for `match` fields. |
| `q.country` | The user's store region, e.g. `in`. |
| `q.log(...)` | Goes to Quicky's log, prefixed with the extension id. |
| `q.call(tool, input)` | Calls another installed tool, e.g. `q.call("music_search", {query})`, with that tool's own permissions and confirm rules. |

There is no filesystem, `eval`, `Function` or `require`. Files come only from a `local` tool's own helpers, added to `q` as needed.

## Combining tools: `run`

Every turn with an extension also gets one core tool, `run`. With it, the model writes a short JavaScript program instead of making several calls:

```js
const { results } = await music_search({ query: "nanchaku seedhe maut" })
const song = pick(results, { title: "nanchaku", artists: "seedhe maut" })   // asks the user if nothing clearly wins
if (song.apple) return open_url({ urls: [song.apple] })
return telegram_download({ query: `${song.title} ${song.artists}`, seconds: song.seconds })
```

- **One model trip.** The program runs in Quicky, so search, choose, download is one call. The model sees each tool's input schema in its declaration, and each output shape as a "Returns …" line generated from `output`, so it can pipe without guessing.
- **Inside a program** every tool is an async function named as the model sees it (`music_search`), along with the core `open_url`, `copy_to_clipboard` and `web_search`. `Promise.all` runs calls in parallel.
- **Picking without guessing.** `pick(items, {title, artists, seconds})` returns the one item that clearly wins: `match` at least 0.8, a lead of at least 0.15 over the next, and `seconds` within 5 if given. If none wins, it stops the program and Quicky asks the user, showing the top three. `ask(question, options)` does the same directly. Anything a program downloads, sends or changes should come out of a `pick`, not `results[0]`.
- **Confirms still apply.** A `write` or `external` call inside a program pauses it on the confirm card, showing the exact input (the resolved item, not the program). Declining ends the program.
- **Limits.** 15 s wall clock, 20 tool calls and 64 KB of returned JSON per program. A program can't touch anything a tool couldn't.
- The program's return value is the tool result. A string is spoken as is, with no second model trip. An object with a `say` string is spoken the same way, and one with `done: true` (what `open_url` returns inside a program) says nothing, because the screen already shows it. Any other object goes back to the model to phrase.
- Tools follow the same rule outside programs: a `local`/`write` tool that returns `{ say: "Downloaded 3 songs to Music." }` needs no second model trip either.

Single lookups don't need `run`; the model calls `music_search` directly, and read tools still start while the model is streaming.

## Accuracy rules for authors

A chain is only as good as its weakest pick, so:

1. **Return candidates with `match`.** Any tool that takes a query returns a list ranked by your best judgement, each with a 0–1 `match`. Never hide the list behind the "first result".
2. **Return identity, not prose.** Ids, URLs, durations and years are what the next tool needs to pick the same thing. A sentence only goes in `summary`, if anywhere.
3. **Accept identity back.** If the next step (a download, a lyric fetch) can take `seconds`, `album` or an id from a previous result, accept it and use it to verify. Example: `telegram_download` rejects a file whose length differs by more than 5 s from `seconds`.
4. **Say "not found" plainly.** Return an empty list or `null`, never the nearest thing, unless it's marked with a low `match`.
5. **Be quick.** Aim for under 1 s on `read` tools. Cache what you can, and race sources rather than chaining them.

## Discovery: how an extension reaches a turn

Only the extensions an ask needs are sent to the model:

1. While the user speaks, the picker asks Jev one yes/no question per installed extension (its `when`), all in one request. Cost doesn't grow with the number of extensions, at about 250–450 ms, and the answer is usually ready before the user stops.
2. A `cues` word in the ask picks the extension at once.
3. An extension used in the last two minutes stays on for follow-ups ("and the lyrics?").
4. Typed asks wait at most 0.4 s for the picker, then fall back to cues.

## Where extensions live

| | Path | |
|---|---|---|
| Core | `extensions/core/<id>` in this repo, built into the app | Ships with Quicky. Can be turned off in Settings, never removed. May be native Swift (`"main": "native"`). Web search is core. |
| Directory | `extensions/directory/<id>` in this repo for now; later each in its own repo, submitted on the website | Installed per user into `~/Library/Application Support/Quicky/Extensions/<id>`. |
| Personal | Any folder | `Quicky --extension install <folder>` symlinks it, so edits apply on the next turn. |

`Quicky --extension check <folder>` runs the checks the directory will run:
- The manifest is valid, ids and names follow the rules, and every tool has `input`, `output` and `effect`.
- The code exports exactly the declared tools, with no `eval`, `Function` or dynamic `import`.
- Every `fetch` host is declared, and every example passes live within its `timeoutMs`.
- Write and external tools give their reason in the description.
- The folder is under 1 MB.

## Versioning

`version` is semver. Changing a tool's `input` or `output` in a breaking way is a major version, because other extensions and saved programs pipe on it.
