# Quicky vs Raycast AI

Raycast AI as of its September 2026 releases (Quick AI, AI Chat, AI Commands, AI Extensions, MCP,
Screen Awareness, agentic AI Chat). Sources at the end.

## Short version

Raycast AI is a broad, typed AI layer for the whole Mac: many models, an extension store, MCP, saved
commands, agents and automations. Quicky is narrower and voice-first: you hold fn (or double-tap
Control), say what you want about the window you're in, hear the answer in your language, and it can act
on the Mac for you. Raycast wins on breadth; Quicky wins on speaking, Indian languages, and doing things
on screen.

## Side by side

| | Quicky | Raycast AI |
|---|---|---|
| Summon | Hold fn to talk, double-tap Control for hands-free, shift+fn to type; panel at the cursor | Hotkey or Tab from the Raycast launcher; Quick AI and AI Chat windows |
| Input | Voice first (Saaras STT, local speech gate), typing too | Typing first; built-in dictation (⌃M in the composer) |
| Spoken answers | Yes: Bulbul TTS, streamed sentence by sentence, barge-in with fn or Esc | No spoken replies |
| Languages | 11 Indian languages plus English, Hinglish in and out | Whatever the chosen model handles; typed |
| Screen context | Every turn: screenshot of the front window, accessibility text, what's under the pointer, the selection, Finder selection paths, the browser URL | Screen Awareness (Aug 2026): context from the focused app or window |
| Conversation | Threaded chats; continues within 2 minutes, ⌘[ / ⌘] between chats | Quick AI for one-offs, AI Chat for threads; Projects with memory |
| Acting on the Mac | Native tools (shortcuts like ⌘W, open apps and links, calendar, reminders, move files, Shortcuts, trim and join videos) plus computer use with its own cursor that clicks for you | AI Extensions (Linear, Slack, Notion, GitHub…), MCP servers, agentic AI Chat that plans and runs code |
| Clicking in arbitrary apps | Yes (OpenAI computer use; accessibility first, your cursor never moves) | Not a built-in feature; through extensions or MCP |
| Models | Sarvam (sarvam-105b, gemma4), OpenAI for computer use | Many: OpenAI, Anthropic, Google, Perplexity, local via Ollama, bring your own key or subscription |
| Extensibility | Add tools in code | Store of AI Extensions, custom agents, automations, MCP |
| Saved prompts | No | AI Commands with hotkeys |
| Platforms | macOS 14+ | macOS and Windows |
| Price | Free, open source; you pay Sarvam (and optionally OpenAI) per use | Pro $8/month with 500 AI credits; Pro+, Max, Teams, Enterprise |
| Privacy | Chats saved locally, no screenshots stored; keys in your Keychain | Local by default; Cloud Sync encrypted; providers don't train on data |

## Where Quicky should go next

1. Saved voice commands (Raycast's AI Commands, but spoken): "fix my grammar", "reply politely".
2. Selected text in, rewritten text out, in place, without opening the panel.
3. MCP client, so Raycast-style integrations work without writing Swift.
4. A model picker for the typed path (keep Sarvam for voice and Indian languages).
5. Notarized builds, so it installs without right-click → Open.

## Sources

- [Raycast AI](https://www.raycast.com/core-features/ai)
- [Raycast manual: AI](https://manual.raycast.com/v1/ai)
- [Changelog: Quick AI redesign (May 2026)](https://www.raycast.com/changelog/macos-beta/0-56)
- [Changelog: AI Chat on Windows (June 2026)](https://www.raycast.com/changelog/windows/0-65)
- [Changelog: Screen Awareness (Aug 2026)](https://www.raycast.com/changelog/1.104.0)
- [Changelog: agentic AI Chat, usage-based plans (Sept 2026)](https://www.raycast.com/changelog/macos-beta/2-3)
- [Changelog: extension-provided models (Sept 2026)](https://www.raycast.com/changelog/macos-beta/2-5)
