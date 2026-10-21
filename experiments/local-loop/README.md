# Weather task on a local model, three designs (2026-10-22)

Qwen3-4B-Instruct-2507 Q4_K_M on llama.cpp (`llama-server -hf unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M --jinja -c 16384 --port 8091`),
M3 Pro 18 GB, Quicky's real system prompt (~1.2k tokens). Location is a local stub; weather is a live Open-Meteo call (~0.6 s).
`python3 -I bench.py 5` — medians of 5.

| design | total | model | tools | model trips | prompt tokens re-read |
|---|---|---|---|---|---|
| A tool loop, prompt re-read every trip (today's design) | 11.5 s | 10.7 s | 0.65 s | 3 | 4068 |
| A' tool loop, model keeps the prompt in memory | 3.5 s | 2.8 s | 0.64 s | 3 | 99 |
| B one program, cold | 4.5 s | 3.7 s | 0.60 s | 1 | 1243 |
| B' one program, warm | 1.9 s | 1.3 s | 0.63 s | 1 | 1 |

Measured rates on this Mac: reading prompt ~340 tokens/s, writing ~35 tokens/s.
Variance between runs was large (an earlier A' run took 9.2 s), so treat these as rough.
