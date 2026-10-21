# Stress test: real-world prompt sizes (2026-10-22)

`Quicky --probe stress <data-dir> 3 <screenshot>` — the app's real system prompt, 12 tools and context block,
plus preloaded "memory" built from Raycast AI's own prompts (chat, memory extraction/update, compaction,
pulled from the Raycast 2.8.2 bundle) and Quicky's docs, repeated to size. From 8k up, ten earlier chat turns
are added. A fact (dentist appointment) sits in the middle of the memory; "needle" is how often it was recalled.

| model | memory (≈tokens) | cold first token | warm first token | needle |
|---|---|---|---|---|
| sarvam-105b | 0 | 145 ms | 125 ms | n/a |
| sarvam-105b | 3k (Raycast-sized) | 179 ms | 178 ms | 2/2 |
| sarvam-105b | 8k + history | 443 ms | 492 ms | 2/2 |
| sarvam-105b | 32k + history | 1.5–1.9 s | 1.4–1.8 s | 2/2 |
| sarvam-105b | 100k + history | 6.1–6.3 s | 6.1–6.4 s | 0/2 |
| gemma4 + screenshot | 0 | 399 ms | 495 ms | n/a |
| gemma4 + screenshot | 3k | 2.2 s | 971 ms | 2/2 |
| gemma4 + screenshot | 8k + history | 1.1 s | 1.2 s | 2/2 |
| gemma4 + screenshot | 32k + history | 1.8 s | 747 ms | 2/2 |
| gemma4 + screenshot | 100k + history | 5.6 s | 720 ms | 2/2 |

Findings:
- sarvam-105b gets no visible benefit from a repeated prefix: time to first token grows with the prompt
  (~6 s at 100k). gemma4 does cache: after the first call, 100k tokens answer in ~0.7 s.
- sarvam-105b lost the fact at 100k ("I can't find your dentist appointment on screen") but found it at 32k.
- With no memory, "when is my dentist appointment?" made sarvam-105b call create_event with an invented
  date, or open Calendar. It acted on a question and made up data.
