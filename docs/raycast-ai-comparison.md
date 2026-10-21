# Quicky vs Raycast AI

Compared against **Raycast 2.8.2** (`com.raycast.macos`) as installed in `/Applications/Raycast.app`,
read from its bundle: the frontend and backend JavaScript in
`Contents/Resources/macos-app_RaycastDesktopApp.bundle/Contents/Resources/`, the native binary and its
Accessibility XPC service. Nothing here comes from marketing pages or leaks. File names below are the
bundle's own.

## What the bundle shows Raycast AI does

- **Surfaces.** Quick AI (`command-ai-quick-ai`), the AI Chat window (`ai-chat-window.html`), AI Commands
  with built-ins like Fix Spelling, Improve Writing, Change Tone, Explain in Simple Terms, Find Bugs,
  Summarize Website and Ask About Website (`command-ai-command-*`), plus Agents, Automations, Projects,
  Skills and memory (`ai-agents-settings-view`, `ai-automations-settings-view`, `ai-projects-settings-view`,
  `ai-skills-settings-view`, `ai-memory-access`).
- **Models.** A model store and settings (`ai-models-store`, `ai-models-settings-view`, an "auto" model),
  credits metering (`ai-credits`, `ai-credits-meter`), and an agent backend that can run the Codex
  `app-server` with a connected ChatGPT account (`backend/index.mjs`).
- **Integrations.** AI Extensions with @-mentions (`ai-extension-mentions`), skills mentions, and an MCP
  client and gateway (`backend/mcp-client-sdk.cjs`; the agent gets a `raycast` MCP server).
- **Screen Awareness** (`composer-screen-awareness.logic`). It attaches a text block, "[Context from
  focused app]", with the app name, window title, selected text, focused element, app accessibility
  context, and browser page content, title and URL. Screenshots are separate commands: "Send Screen",
  "Send Screen Area" and a "capture window screenshot" AI extension.
- **Voice in.** Full dictation: Dictate Text, **Dictate AI** (speak a prompt to AI), dictation profiles,
  personalization, history and a microphone picker (`command-dictate-*`, `dictation-*`). There's a
  push-to-talk mode in the dictation HUD and about 100 languages (the Whisper list, including Hindi, Tamil,
  Telugu, Bengali, Marathi, Kannada, Malayalam, Gujarati and Punjabi).
- **Hotkeys.** The shortcut recorder supports "Single Key" and **"Double Tap"** modifier hotkeys
  (`keyboard-shortcut-recorder`), so any command can be bound to, say, double-tapping a modifier.
- **Voice out.** Not for AI answers. The only text-to-speech in the bundle is the Translator extension
  pronouncing translations with macOS system voices (`speechSynthesis`, logged as `extension::translator`,
  with voice-pack installs). AI Chat and Quick AI don't speak.
- **Acting on the Mac.** Only through extensions and MCP tools. When Raycast starts its agent it
  explicitly turns these off: `--disable computer_use`, `browser_use`, `shell_tool`, `apps`, `plugins`
  and more, all set `false` in the thread config. The only tools left are its MCP gateway and web search.
  There is no clicking in arbitrary apps.

## Side by side

| | Quicky | Raycast AI 2.8.2 |
|---|---|---|
| Summon | Hold fn to talk; double-tap Control for hands-free; shift+fn to type; panel at the cursor | Any hotkey, including Double Tap modifiers; Quick AI window, AI Chat window |
| Voice in | Built in: live Saaras STT, a local speech gate (silent holds never send), Hinglish | Dictate AI, ~100 Whisper languages, push-to-talk, profiles |
| Voice out | **Yes:** Bulbul streams the answer sentence by sentence; fn or Esc interrupts, and it remembers what you heard | **No** for AI answers (system voices only in Translator) |
| Indian languages | 11 plus English, answered *and spoken* in your language and script | Dictation recognises them; replies are text in whatever language the model picks |
| Screen context | Every turn by default: screenshot of the front window, accessibility text, the element under the pointer, the selection, Finder selection paths, browser URL | Screen Awareness text block (app, window, selection, focused element, page content, URL); screenshots on demand |
| Conversation | Threaded chats, continue within 2 minutes, ⌘[ / ⌘] | Quick AI and AI Chat, Projects with memory |
| Acting on the Mac | Keyboard shortcuts (⌘W …), open apps and links, calendar, reminders, move files, Shortcuts, trim and join videos, **computer use with its own cursor** (accessibility presses first, your cursor never moves) | Extensions and MCP tools, web search. **Computer use, browser use and shell are explicitly disabled** |
| Models | Sarvam (sarvam-105b, gemma4); OpenAI only for computer use | Model store, auto model, connected ChatGPT account |
| Saved prompts | No | AI Commands with built-ins and custom ones |
| Extensibility | Tools added in code | Extensions store, MCP, skills, agents, automations |
| Cost | Free and open source; pay Sarvam (and optionally OpenAI) per use | Credits-based plans |

## In one line

Raycast AI is a typed, extensible AI layer with voice *input*. Quicky is a voice conversation about the
window you're in, it answers out loud in Indian languages, and it does things on screen that Raycast
deliberately leaves out.

## Worth borrowing from Raycast

1. AI Commands, but spoken: "fix my grammar", "make this polite", run on the selection.
2. Push-to-talk HUD polish: Raycast shows the push-to-talk state and a limit countdown in its HUD.
3. Hotkey choice in Settings, like Raycast's Single Key and Double Tap recorder.
4. An MCP client, so integrations don't need Swift.
5. Screen context as an explicit, visible attachment (Raycast shows it in the composer), so users see
   what's being sent.
