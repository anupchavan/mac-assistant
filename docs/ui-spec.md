# UI spec: the panel at your cursor

Figma: [Mac assistant UI](https://www.figma.com/design/0lkGMSXVtQ5FmnsOUZ6y9t). There are three boards. **Components** holds Keycap, ContextChip, LangTag and StatusStep (done/active/pending). **States · Light** and **States · Dark** each show six scenes, and the Dark board is the same frames with the Flexoki `Semantic` collection switched to Dark. Every colour is bound to your Flexoki library variables, so changing the library restyles everything.

Design language: Raycast's floating pill, squircle corners, quiet chrome. Type is Geist, Geist Mono and a pixel face. Colour is Flexoki semantic tokens only.

## v4 (current): Midnight glass, one grid, one icon family

Figma page **"v3 · Midnight glass"** (first page of the file): 13 scenes plus a Components board. It replaces Flexoki entirely. Earlier pages are kept only for reference. The behaviour rules in "Behaviour and edge cases" below still apply; anything visual below this section is superseded where it disagrees.

### It's a chat, not a single turn (added 19:05 IST)
- **Each summon continues the current chat** if it was used in the last 5 minutes. Otherwise it starts a new chat.
- **Turns stack in the body as a thread:**
  - Your turn: the "?" or mic lead glyph plus your words in text/secondary.
  - Its turn: the answer text at x = 52 below it.
  - Each turn gets its own collapsed status line ("Worked for 1.6s"). The input row stays at the top for the next turn, and the newest turn is at the bottom.
- **Scrolling:** the body scrolls inside the height cap with stick-to-bottom.
- **Screen context:**
  - It is re-captured on every turn.
  - When the app changed between turns, a quiet divider row says so ("Now looking at Chrome · arxiv.org").
- **Switching chats** (same keys as Raycast Quick AI):
  - **⌘[** goes to the previous chat and **⌘]** to the next.
  - **⌘N** starts a new chat.
  - **⌘K → Chats** lists recent chats with their first question as the title.
  - The footer's left side shows the chat position ("2 / 5") after the app label whenever there is more than one chat.
- **Storage:** chats are stored locally (Application Support/…/chats.json), each with its turns, the language and the app per turn. Screenshots are never stored.
- **What the model receives:** the last 6 turns as history plus the fresh screen context. History keeps only what was actually spoken or shown (barge-in rule).
- **Voice in a chat:**
  - Hold fn while an answer shows to ask a follow-up in the same chat.
  - fn + Space types a follow-up.
  - Esc closes the panel but keeps the chat.

### Colour: Raycast's bundled Midnight theme, read from the app
Values come from `Raycast.app/…/frontend/contrast-improvement-*.js` (theme `bundled-midnight`) and the role mapping from Raycast's own CSS (`--color-text-secondary: var(--fg-60)` and so on). Nothing was sampled from screenshots.

| Token | Value | Raycast source |
|---|---|---|
| theme/background | #070034 | `background` (gradient start) |
| theme/background-secondary | #11005B | `backgroundSecondary` (gradient end) |
| theme/foreground | #FAF0FF | `foreground` |
| theme/accent | #4FA3F8 | `accent` |
| theme/selection | #B1A7FF | `selection` |
| theme/loader | #F4C4FF | `loader` (spinner while working) |
| theme/green · red · orange · yellow · blue · purple · magenta | #63BA89 · #F84141 · #FFC100 · #FEFF7F · #6AB7FB · #C58AFA · #FF5DB3 | named colours |
| text/primary · secondary · tertiary · quaternary | fg 100% · 60% · 40% · 20% | `--color-text-*` (placeholder = 40%) |
| surface/list-selection · list-hover · control | fg 10% · 5% · 10% | `--color-surface-*` |
| surface/action-bar · input-field | #FFFFFF 5% (0x0d) | `--color-surface-action-bar` |
| border/panel · secondary · separator · tertiary | fg 20% · 20% · 10% · 5% | `--shadow-panel-border`, `--color-border-*` |
| window/bg · window/bg-secondary | #070034 40% · #11005B 40% | `--color-window-bg: var(--bg-40)` |
| window/base | #262626 | `--color-window-base` (dark) |

Semantic use: listening = theme/purple, working spinner = theme/loader, done = theme/green, error = theme/red, links = theme/accent.

### Glass
- **Panel fill:** two layers.
  - Bottom: window/base at 55% as the dark material stand-in.
  - Top: a vertical gradient from window/bg (top) to window/bg-secondary (bottom).
- **Panel effects:**
  - Figma Glass effect (frost 20, refraction 0.35, depth 12, light 0.4 at −45°, dispersion 0.05).
  - Shadow 0 24 64 #000 45%.
- **Panel border:** 1 px inside, border/panel.
- **In SwiftUI:** an `NSGlassEffectView` (macOS 26) or `NSVisualEffectView(.hudWindow)`, with the two-stop gradient on top at 40% per stop.
- **Glass on glass:** only the panel and the computer-use pill are glass. Rows and keycaps are flat tints on top.

### Grid (every scene was checked node by node, not by eye)
- Panel width 560, radius 20 (Raycast's macOS 27 window radius).
- **Lead column:** x = 16 to 40, centre x = 28. Every icon in every row sits here.
- **Text column:** starts at x = 52 (16 + 24 + 12) for the input, every row title, the answer text and the footer label. The right inset is 16 everywhere.
- **Rows:** inset 8 from the panel, radius 12 (20 − 8, concentric), height 32, padding 8.
- **Input row:** height 56, glyph 22 px. Typed input wraps to 3 lines (72 px), giving a row height of 104.
- **Footer:** height 44 (Raycast `--default-window-footer-height`), fill surface/action-bar, top separator.
  - Left: the context app icon (16) in the lead column, with its label at x = 52.
  - Right: actions as "Label + keycaps", split by 1×16 separators.
- **Keycap:** height 20, minimum width 20, radius 6, fill surface/control. Inner shadows +0.5 px #FFF 30% (top) and −0.5 px #000 80% (bottom), Raycast's `--interactive-key-*`. Geist Mono Medium 11, or a 12 px glyph.
- **Scales used:** spacing 2/4/6/8/12/16/24/32/40/48/56; radius 6/12/20; type 11/13/16 (Raycast's own scales).

### Type
Geist only, with Geist Mono for keycaps and times. Input 16/24 Regular. Rows, answer and footer 13/20 (Regular, Medium for emphasis, SemiBold for the confirm title). Times and keycaps 11. Tracking −1% (Raycast uses −0.01em). Telugu uses Anek Telugu at the same size. Geist Pixel is no longer in the panel, because a pixel glyph next to stroke icons was the incoherence.

### Icons
Hugeicons Stroke Rounded only, stroke 1.5, at 22 (input glyph), 16 (rows, footer) and 12 (keycaps). The idle mark is a bare "?" drawn from Hugeicons' help-circle glyph without its circle, rescaled so its stroke stays 1.5. It now matches the mic exactly in weight and style.

## v3: less chrome, and how it behaves at the edges

v3 sits on top of v2; where they disagree, v3 wins. The Figma scenes on page "v2 · Desktop" are already updated to it.

**Removed, and why** (sources in [research notes](#sources-for-v3)):
- The filled square behind the lead glyph. The "?" / mic / spinner stands alone in a 28×28 hit area, because a coloured tile behind an icon is decoration that competes with the answer (Linear removed exactly this in its Mar 2026 refresh).
- The language tag and the "Speaking" waveform row. The answer text *is* the state; playback is shown by the footer's "esc Stop speaking", which is also the control. ChatGPT voice (Nov 2025) dropped its orb for the same reason.
- The esc keycap in the input row. Esc is universal for a floating panel; it appears only in the footer when it does something specific (stop speaking, cancel, back).
- The divider under the input. Spacing separates; a 1 px line appears only when the body is scrolled (a scroll-edge cue, macOS 26 style).
- Developer metrics in the footer ("audio 0.89s", tool names). They move to a debug overlay (⌥⌘D).
- The all-caps "LOOK AT ANOTHER APP" label. Real app icons explain the list.
- Icons on suggestion rows; the text starts at the same x = 48 as everything else.

**Footer, Raycast model:** one primary action on the left in tx with its key, secondary actions behind **⌘K Actions** on the right (Copy, Insert, Think harder, Read aloud again, Open in…). Voice answer: "esc Stop speaking … ⌘K Actions". Typed answer: "↵ Insert … ⌘K Actions". Confirm: "↵ Add to Calendar · esc Cancel" (verb + object, never "OK").

**Motion:** the panel appears with **no animation** (it is summoned dozens of times a day; Raycast does the same). Height changes ease-in-out 150 ms. Dismiss is a 100 ms fade. Spinners appear only after 150 ms and then stay ≥ 300 ms. Everything is interruptible, and Reduce Motion turns movement into opacity.

## Behaviour and edge cases

### Sizes and scrolling
- **Panel height:** never taller than **min(60% of the screen's visible height, 560 px)**, and always ≥ 24 px from every screen edge. Near the bottom it grows upward from the cursor instead of running off-screen; it never re-positions while the user is reading.
- **Typed input:** one line by default; wraps up to **3 lines** (3 × 20 = 60 px, row grows from 48 to 88), then scrolls inside itself. It never grows to fill the panel.
- **Voice transcript:** stays on **one line** while live. New words push old ones left; a 16 px fade on the left edge shows that text is hidden. Click it to see and edit the whole transcript (switches to typed, 3-line rule).
- **Answer body:** grows with the text until the panel cap, then scrolls inside the panel. While streaming it stays pinned to the bottom; the moment the user scrolls up it stops following (no debounce) and shows a small "↓ Latest" pill at the bottom edge. A 12 px fade mask appears only on an edge that has more content.
- **Scroll containment:** scrolling the answer never scrolls the app behind it.
- **Status rows:** fixed 28 px rows, at most 4 visible; when the answer starts they collapse to one line "Worked for 1.6s" (tap to expand), so the answer doesn't jump down.

### Stopping the voice (barge-in)
- **Esc** stops speech instantly and keeps the text. A second Esc closes.
- **Pressing fn while it's speaking** stops speech and starts a new push-to-talk turn with the same context. This is the main "shut up and listen" gesture.
- **Clicking "Stop speaking"** in the footer does the same as Esc.
- **Talking over it** interrupts only on headphones. On built-in speakers the mic would hear our own voice, so voice barge-in stays off there unless echo cancellation (AVAudioEngine voice processing) is on. Even then, it needs ≥ 0.5 s of speech or ≥ 3 words, so "haan" or "okay" don't cut it off.
- **After a stop:** the unspoken rest of the answer stays visible in tx2, and the conversation memory records only what was actually heard.
- **Implementation:** Bulbul's socket has no cancel message. Stopping means clearing local playback, closing the socket and opening a fresh one in the background.
- **Volume:** duck other audio to medium while speaking and restore it afterwards. There is no pause/resume; "Read aloud again" (in ⌘K) restarts from the beginning.

### Turn-taking
- **Hold shorter than 300 ms, or a hold with no speech:** discarded silently. No API call, no error.
- **Hands-free:** ends after 0.5 s of silence, extended to 3 s if the sentence sounds unfinished (trailing "and", "ki", "toh").
- **No speech heard:** close quietly.
- **Noisy room:** after two false starts, show "Noisy here. Hold fn to talk."
- **Language:** detected per utterance, never locked. Hinglish in, Hinglish out.

### Focus and dismissal
- **Focus:** the panel never activates our app. Keys typed in the first 300 ms after the gesture are buffered, not lost.
- **Returning focus:** on close, focus returns to the app that was in front.
- **Click outside:** closes only when idle. It never closes while recording, speaking, waiting on a confirm, running computer use, or after the user has scrolled the answer.
- **Placement:**
  - It opens on the screen with the cursor.
  - It is pushed 16 px aside if it would cover the element under the pointer (from its AX frame).
  - It works over full-screen apps without kicking them out of full screen.
- **Re-opening:**
  - Within 5 minutes, it shows the last answer and the same context, ready for a follow-up.
  - After 5 minutes it starts fresh.
  - ⌘N always starts fresh.

### Errors
- **Network drop mid-answer:** keep the partial text and add an inline line "Connection lost · ↵ Retry". Retry continues the same turn.
- **Bulbul socket closed** (1001/1006/1011): reconnect with backoff. Never auto-retry auth or quota errors. Ping the socket so it doesn't close after 60 s idle.
- **Screen Recording permission expired** (macOS re-prompts monthly): answer from the accessibility text and say so in one line.
- **Errors say the next step:** "Mic blocked. Open Settings", never "Error 403".

### Actions and computer use
- **Confirmation:** consequential actions confirm first, naming the exact target. The confirm button disables on the first press, and every action carries an idempotency key, so nothing runs twice.
- **Running computer use:**
  - The panel shrinks to a 32 px status pill in the target window's top-right corner, so it doesn't cover what the model must see.
  - The pill shows the current step ("Clicking Block") and "esc Stop".
  - Esc, fn, or moving the mouse more than 40 px stops the run instantly.
- **Untrusted text:** text on screen never counts as an instruction.

### Privacy
- **Secure fields:** password fields (AXSecureTextField) are never read.
- **Private windows:** private/incognito windows are not captured; the panel says so.
- **Menu bar mic dot:** goes off whenever the mic is muted.

### Accessibility
- **VoiceOver:** announces "Thinking…" and "Answer ready", not every token.
- **Keyboard paths:**
  - Every fn gesture has a keyboard equivalent in Settings.
  - Every control is reachable with Tab.
- **Contrast:** text is 4.5:1 against the panel in both themes.

### Sources for v3
Linear, "Behind the latest design refresh" (Mar 2026). Apple HIG Materials (Sep 2025) and Typography (Dec 2025). WWDC25 "Get to know the new design system". Vercel Web Interface Guidelines (current, Jan 2026). Emil Kowalski, "You don't need animations". Raycast Manual, Action Panel, and Raycast macOS changelog v2.3–2.7 (Sep–Oct 2026). TechRadar on ChatGPT voice in chat (Nov 2025). Gemini Live help and 9to5Google on Mute (Dec 2025). LiveKit turn-tuning docs (Oct 2026). Pipecat interruptions docs. Sarvam TTS WebSocket docs. Brave on screenshot prompt injection (Oct 2025). 9to5Mac on monthly Screen Recording prompts (Aug 2024). Wispr Flow hands-free docs. use-stick-to-bottom README.

## v2: what changed from v1 (v3 above wins where they differ)

Figma page **"v2 · Desktop"**: Components v2, a Desktop kit (wallpaper with menu bar, Finder, Chrome, Mail windows as editable layers), and two sheets, **States v2 · Light** and **States v2 · Dark**, with eight scenes each at 1000 px wide. Page "v1 (superseded)" is kept for reference only.

- **Concentric corners.** Inner radius = outer radius − inset. Panel 16; sections padded 10, so every control 10 px from the edge is **6** (LeadBox, Keycap, AppChip, confirm badge). The suggestion and switcher lists are padded 6, so their rows are **10**. App icons inside 16 px are 4.
- **Vertical rhythm.** Input row 48 (10 + 28 + 10). Status rows 28. List rows 36. Footer 44 (10 + 24 + 10), footer keycaps 24.
- **One text column.** Input text, status text and answer text all start at x = 48 (10 padding + 28 lead column + 10 gap), so the eye runs straight down the panel.
- **Mark.** No sparkle anywhere. The idle mark is a Geist Pixel Square "?" drawn as a 12×19 vector (1 px per pixel cell, so it stays crisp), centred in a 28×28 LeadBox. The mic replaces it while listening, a spinner after submit. A HelpCircle icon was tried and dropped: it reads as "help docs", while the pixel "?" reads as "ask".
- **Icons.** Hugeicons Stroke Rounded everywhere, stroke 1.5, 16 px (14 in keycaps, 12 for the chip chevron), coloured with tokens. No SF Symbols.
- **Geist Pixel.** Used for the "?" mark and LangTag/section labels (10/12, +4%, uppercase). In Figma the LangTag layers still use Geist Mono as a stand-in; switch them to Geist Pixel locally.
- **Backgrounds.** Scenes sit on a wallpaper with real-looking app windows (Finder, Chrome on arxiv.org, Mail), never on a flat Flexoki fill, so contrast and the shadow are judged in context. Rendered PNGs are in `assets/`; drop real Mac screenshots over the window components to replace them.
- **AppChip is a button.** h28, chevron on the right. Click or ⌘K opens the app switcher.

### Listening hint (state 01)

*(v4: the hint now sits on the footer's right, "Release fn to send", and there is no HANDS-FREE tag.)* The input placeholder says how the turn ends, so nobody has to remember the gesture: **hold** → "Listening… release fn to send"; **hands-free** → "Listening… tap fn to send". Both tx3, after the live transcript replaces them. While held, the LeadBox ring pulses with level; hands-free adds a small "HANDS-FREE" LangTag before the chip.

### New states

| # | State | What shows |
|---|---|---|
| 07 | App switcher | Body becomes "LOOK AT ANOTHER APP" + ListRows (Chrome · arxiv.org, Mail · inbox, Finder · Current). Footer: ↵ Focus & look · esc Back · "re-captures screen". |
| 08 | After switching | Chosen app comes forward behind the panel; chip reads "Chrome · arxiv.org"; one done status row "Brought Chrome forward · captured the window 0.11s"; input text kept. |

Behaviour behind 07/08 is in feature-map.md F2b; the build prompt is prompts.md §10.7.

## Foundations

### Grid and geometry
- 4 px base grid. Every dimension below is a multiple of 2, and nearly all are multiples of 4.
- **Squircle**: every rounded rect uses `cornerSmoothing 0.6` in Figma. In SwiftUI that's `RoundedRectangle(cornerRadius: r, style: .continuous)`.
- Radii scale: 3.5 (app icon 14px), 4 (lang tag), 5 (keycap), 7 (chip), 8 (row, badge), 12 (mock window), **16 (panel)**.

### Colour (Flexoki `Semantic` collection; hex shown for reference)
| Token | Light | Dark | Used for |
|---|---|---|---|
| `base/bg` | #FFFCF0 | #100F0F | Panel fill, keycap fill |
| `base/bg-2` | #F2F0E5 | #1C1B1A | Footer fill, desktop backdrop |
| `base/ui` | #E6E4D9 | #282726 | Divider, chip fill, selected row |
| `base/ui-2` | #DAD8CE | #343331 | Panel border, keycap border, lang tag border |
| `base/ui-3` | #CECDC3 | #403E3C | App-icon placeholder, pressed states |
| `base/tx` | #100F0F | #CECDC3 | Primary text, answer |
| `base/tx-2` | #6F6E69 | #878580 | Submitted query, chip label, footer labels, done steps |
| `base/tx-3` | #B7B5AC | #575653 | Placeholder, timings, pending steps, idle lead icon |
| `orange/tx` | #BC5215 | #DA702C | **Voice**: live mic, speaking bars, "Speaking" |
| `orange/bg-2` | tint | tint | Action icon badge |
| `cyan/tx` | #24837B | #3AA99F | **Agent working**: active-step spinner |
| `green/tx` | #66800B | #879A39 | Done check |
| `red/tx` | #AF3029 | #D14D41 | Errors, destructive confirm |

Rule: one accent per meaning. Orange means voice, cyan means "the agent is doing something", green means done, red means error or destructive. Nothing else gets colour.

### Type
| Style | Family / weight | Size / line | Tracking | Where |
|---|---|---|---|---|
| `input` | Geist Regular | 15 / 20 | −0.6% | Input text, placeholder |
| `answer` | Geist Regular | 14 / 21 | −0.3% | Answer body (1.5 line-height for reading) |
| `title` | Geist SemiBold | 14 / 18 | −0.6% | Confirm-card title |
| `body` | Geist Regular | 13 / 18 | −0.3% | Steps, suggestions, card detail |
| `body-strong` | Geist Medium | 13 / 18 | −0.3% | Active step, selected suggestion |
| `label` | Geist Medium | 12 / 16 | −0.3% (chip −0.5%) | Chip, footer action labels, "Speaking" |
| `key` | Geist Mono Medium | 11 / 14 | 0 | Keycap glyphs |
| `metric` | Geist Mono Regular | 11 / 14 | 0 | Timings, "audio 0.89s", tool name |
| `pixel-tag` | **Geist Pixel** (stand-in Geist Mono Medium) | 10 / 12 | +4%, UPPERCASE | Lang tag, scene captions, status-bar micro text |

**Geist Pixel isn't installed in your Figma account** (only Geist and Geist Mono are), so the pixel slots use Geist Mono Medium for now. Install Geist Pixel locally, then swap the family in LangTag and in the captions; sizes stay the same. Use the pixel face only at 10–12 px and only for machine-ish labels, because it stops looking crisp at body sizes.

**Indic scripts**: Geist has no Telugu or Devanagari glyphs. In Figma, Telugu uses **Anek Telugu** (Anek Devanagari for Hindi) at the same size, line height and tracking. In the app, set a font cascade so macOS falls back to Kohinoor Telugu / Kohinoor Devanagari instead of tofu: `Font.custom("Geist", size:)` plus a `CTFontDescriptor` cascade list.

### Elevation
Panel shadow, two layers, colour #100F0F (Flexoki black):
1. y 16, blur 40, spread −8, 16% opacity (the float)
2. y 2, blur 6, spread 0, 8% opacity (the contact edge)

Border: 1 px `base/ui-2`, inside. In dark mode the border does most of the separating work; keep it.

Optional Raycast glass: set the panel fill to `base/bg` at 88% and add a 24 px background blur (`NSVisualEffectView`, `.hudWindow` material, plus the tinted fill on top). Default is **opaque** for the demo, because blur over busy screens hurts readability on a projector.

## Placement

- **Anchor**: panel top-left = pointer hotspot + (12, 18). The 18 px vertical offset clears the 24 px arrow cursor's body so the pointer never covers the lead icon.
- **Flip**: if `x + 520 > visibleFrame.maxX − 8`, anchor the right edge at pointer.x − 12. If `y + panelHeight > visibleFrame.maxY − 8`, grow upward from pointer.y − 12. When it flips up, the input row stays on the side nearest the pointer, so the order reverses: body above, input below.
- **Clamp**: always keep 8 px from every screen edge. Use the visible frame of the screen the pointer is on (multi-monitor), not the main screen.
- **Growth**: width is fixed at **520**. Height grows downward in place (or upward if flipped). The input row never moves once shown.
- **Setting "Centre"**: same panel, centred horizontally, top at 28% of the visible frame height (Raycast's resting height).

## Anatomy

```
Panel 520 × auto, r16 squircle, fill bg, 1px ui-2 inside, shadow ×2, clip
├─ InputRow 520 × 48 · pl14 pr10 · gap10 · center
│   ├─ lead icon 20×20   (mic: orange/tx when live, tx-3 after submit · spark: tx-3 when typed)
│   ├─ input text FILL · input style · 1 line, truncate tail
│   ├─ ContextChip  h24 · pl6 pr8 · gap6 · r7 · fill ui · 14px icon r3.5 · label style tx-2
│   └─ Keycap       h20 · min-w20 · px5 · r5 · fill bg · 1px ui-2 · key style tx-2
├─ Divider 520 × 1, fill ui          (only when a body exists)
├─ Body · padding 12 (steps: 10 top/bottom, gap 2; answer: 12 / 14, gap 10)
└─ Footer 520 × 36 · px12 · gap14 · fill bg-2 · 1px top ui
    ├─ action = Keycap + label (gap 6), repeated
    ├─ spacer FILL
    └─ metric text (tx-3)
```

Heights: input only = **48**. Working with 4 steps = 48 + 1 + 10 + (4 × 24 + 3 × 2) + 10 = **171**. Answer = 48 + 1 + body + 36. Confirm = 48 + 1 + 12 + 36 + 12 + 36 = **145**. Suggestions (3 rows) = 48 + 1 + 6 + (3 × 32 + 2 × 2) + 6 = **161**.

## States

| # | State | Lead | Input text | Body | Footer |
|---|---|---|---|---|---|
| 01 | **Listening** (opens here by default) | mic, orange/tx, pulses with input level | Live partial transcript, tx-2. Placeholder "Listening… ask in any language" tx-3 | none | none |
| 02 | **Typed** | spark, tx-3 | Placeholder "Ask about what's on screen…" tx-3, caret tx | none | none |
| 03 | **Working** | mic or spark, tx-3 | Submitted ask, tx-2 | StatusStep list | none |
| 04 | **Answer / speaking** | tx-3 | Submitted ask | LangTag + speaking bars + "Speaking", then answer text | ⌘C Copy · ↵ Insert · ⌘↵ Think harder · metric "audio 0.89s" |
| 05 | **Confirm action** | spark | Ask | 28 px orange badge (r8, orange/bg-2, 16 px icon orange/tx) + title + detail | ↵ Add · esc Cancel · metric "tool · create_event" |
| 06 | **Suggestions** (empty, stretch) | mic orange | Listening placeholder | 3 rows, h32, r8, px8, gap10, icon 16; the selected row gets fill ui and an ↵ keycap. Body padding 6 | none |

Missing states, built from the same parts:
- **Error**: a single StatusStep row with a red/tx `!` icon and "That didn't go through. ↵ to retry". Footer: ↵ Retry · esc Close.
- **Voice unavailable for the language**: LangTag + tx-3 line "Voice isn't available in this language yet, so here's the text."
- **Deep route**: the active step reads "Thinking harder" and the timing keeps counting. This is the visible proof of the router.
- **Permission missing**: the chip turns into "No accessibility · Grant" (label red/tx, click opens Settings).

## Agent status (the Claude-style part)

Status lines come from pipeline events the app already emits; there's **no extra model call**, which is how it stays fast. Each event maps to one row:

| Pipeline event | Row text (English UI; localise later) | When it turns done |
|---|---|---|
| capture finished | Looked at {App} · {n files selected / selection / page} | immediately (it ran while you spoke) |
| STT final | Heard you in {Language} | on `transcript.final` |
| route = docs | Reading {filename} | Sarvam Docs returns |
| route = deep | Thinking harder | first token |
| tool proposed | Preparing {tool verb} | confirm card shows |
| tool ran | {Past-tense result, e.g. "Added to Calendar"} | tool returns |
| first token | Answering in {Language} | the row is replaced by the answer body |

Rules:
- Rows appear only if the step takes **> 150 ms**. Fast steps are added already done, so a 400 ms answer never flickers through four spinners.
- At most 4 rows are visible; older done rows collapse into "+2 more" (tx-3).
- The timer on the right counts up live (Geist Mono, tabular) and freezes when the row completes. It's the latency story, visible on stage.
- When the answer starts streaming, the steps collapse to a single tx-3 summary line above the answer ("3 steps · 1.6s"), which you can click to expand.

## Motion

Everything here is short: the panel has to feel instant.

| What | Trigger | Animation | Duration | Easing |
|---|---|---|---|---|
| Panel in | hotkey | opacity 0→1, scale 0.98→1, y +4→0, from the pointer corner | 120 ms | `cubic-bezier(0.2, 0, 0, 1)` |
| Panel out | esc / submit-done | opacity → 0, scale → 0.98 | 90 ms | ease-in |
| Height change | body appears / grows | spring, no overshoot | 180 ms | spring(response 0.25, damping 1.0) |
| Mic pulse | input level | 3 px ring around the mic, orange/tx at 25%, radius follows RMS | per audio buffer | none |
| Active spinner | step active | rotate 360° | 800 ms loop | linear |
| Active row label | step active | shimmer gradient tx-3 → tx → tx-3 across the text | 1.4 s loop | linear |
| Speaking bars | TTS playing | 5 bars (2 px wide, gap 2, r1), heights follow the audio envelope, 4–14 px | per audio buffer | none |
| Answer stream | tokens | text appends; no per-token fade (fades look laggy) | n/a | n/a |
| Row select | ↑/↓ | fill ui snaps, no animation | 0 ms | n/a |

Reduce Motion (system setting) turns off the scale, the shimmer and the spinner rotation (use a static ring instead).

## Keyboard

| Key | Effect |
|---|---|
| hold fn | push-to-talk: panel at 200 ms, listening; release submits |
| double-tap fn (≤ 400 ms) | hands-free listening; tap fn or VAD silence ends it |
| fn + Space | open in typed mode |
| tap fn while an answer shows | follow-up by voice, same context |
| triple-tap fn | cancel and close |
| same gestures on right ⌥ | settings fallback |
| any printable key while listening | switch to typed mode, stop mic |
| ↵ | submit; confirm on the confirm card; pick the selected suggestion |
| ⌘↵ | think harder (re-run deep) |
| ↑ / ↓ | move through suggestions |
| ⌘C | copy answer |
| esc | stop speech → cancel generation → close (each press does the next one) |
| ⌘, | settings |

## Content rules
- Input: one line, truncate the tail. The full text is in the tooltip.
- Chip label: at most 24 characters, truncate the middle of file names (`IITH_Fee…eipt.pdf`).
- Answer: 6 lines max visible (126 px), then the body scrolls with a 12 px fade at the bottom edge. Voice answers are kept under 60 words by the prompt anyway.
- Step text: one line, truncate the tail.
- Numbers in metrics: tabular figures, 2 significant decimals (`0.41s`, `1.2s`).

## Accessibility
- The panel is an `NSPanel` with role "dialog", labelled "Assistant".
- Focus starts in the input. Tab order: input → chip → footer actions.
- VoiceOver announces the step changes politely ("Reading IITH fee receipt"), and announces the answer once complete, not token by token.
- Contrast: tx and tx-2 on bg pass AA in both modes. tx-3 is decoration and metadata only; never use it for anything the user must read to act.
- Every keycap hint also exists as a menu or button action.
