"""Weather task three ways on a local model (llama.cpp server on :8091).
A  tool loop, every trip re-reads the prompt (cache off)      ~ today's cloud design
A' tool loop, server keeps the prompt in memory (cache on)     ~ "own the loop / warm model"
B  model writes one small program, run locally, 1 model call
Location is a fixed local stub (0 ms); weather is a real Open-Meteo HTTP call."""
import json, os, re, statistics, sys, time, urllib.request

URL = "http://127.0.0.1:8091"
SYS = re.search(r'static let system = """(.*?)"""', open(os.path.expanduser("~/Projects/quicky/Sources/Quicky/Prompts.swift")).read(), re.S).group(1) + "\n\nYou have tools for this Mac's location and the live weather; use them for any weather question."
CTX = "APP: Safari (com.apple.Safari)\nWINDOW: Sarvam AI dashboard\nOUTPUT_MODE: voice\n\nASK: hey, what's the weather"

def get_location():
    return {"city": "Mamidipalle", "country": "India", "latitude": 17.58, "longitude": 78.12}

def get_weather(latitude, longitude):
    u = f"https://api.open-meteo.com/v1/forecast?latitude={latitude}&longitude={longitude}&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code&wind_speed_unit=ms"
    c = json.load(urllib.request.urlopen(u, timeout=10))["current"]
    return {"temperature_c": c["temperature_2m"], "humidity_pct": c["relative_humidity_2m"], "wind_m_s": c["wind_speed_10m"], "weather_code": c["weather_code"]}

TOOLS = [
    {"type": "function", "function": {"name": "get_location", "description": "Current location of this Mac.", "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {"name": "get_weather", "description": "Current weather at coordinates.", "parameters": {"type": "object", "properties": {"latitude": {"type": "number"}, "longitude": {"type": "number"}}, "required": ["latitude", "longitude"]}}},
]
FUNCS = {"get_location": get_location, "get_weather": get_weather}

def post(path, body):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=120))

def tool_loop(cache):
    msgs = [{"role": "system", "content": SYS}, {"role": "user", "content": CTX}]
    model_s = tool_s = 0.0; read = trips = 0
    while True:
        t = time.time()
        r = post("/v1/chat/completions", {"messages": msgs, "tools": TOOLS, "max_tokens": 200, "temperature": 0, "cache_prompt": cache})
        model_s += time.time() - t; trips += 1
        read += r.get("timings", {}).get("prompt_n", 0)
        m = r["choices"][0]["message"]
        if not m.get("tool_calls"):
            return m.get("content", ""), model_s, tool_s, trips, read
        msgs.append({"role": "assistant", "content": m.get("content") or "", "tool_calls": m["tool_calls"]})
        for c in m["tool_calls"]:
            t = time.time()
            out = FUNCS[c["function"]["name"]](**json.loads(c["function"]["arguments"] or "{}"))
            tool_s += time.time() - t
            msgs.append({"role": "tool", "tool_call_id": c["id"], "content": json.dumps(out)})

PROGRAM_SYS = SYS + """

To act, reply with ONLY one Python code block. Available functions: get_location() -> {city, country, latitude, longitude};
get_weather(latitude, longitude) -> {temperature_c, humidity_pct, wind_m_s, weather_code}. Set `answer` to the final spoken reply (plain sentence, under 25 words), built from the results with f-strings.
These functions work and return live data; never refuse, always call them. Example:
```python
loc = get_location()
w = get_weather(loc["latitude"], loc["longitude"])
answer = f"It's {w['temperature_c']} degrees in {loc['city']}, humidity {w['humidity_pct']} percent."
```"""

def program(cache):
    t = time.time()
    r = post("/v1/chat/completions", {"messages": [{"role": "system", "content": PROGRAM_SYS}, {"role": "user", "content": CTX}],
                                      "max_tokens": 250, "temperature": 0, "cache_prompt": cache})
    model_s = time.time() - t
    text = r["choices"][0]["message"]["content"]
    code = re.search(r"```(?:python)?\n(.*?)```", text, re.S)
    env = dict(FUNCS)
    t = time.time()
    exec(code.group(1) if code else text, env)
    return env.get("answer", "?"), model_s, time.time() - t, 1, r.get("timings", {}).get("prompt_n", 0)

if __name__ == "__main__":
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    for label, fn, cache in [("A  tool loop, no cache", tool_loop, False), ("A' tool loop, warm cache", tool_loop, True),
                             ("B  one program, no cache", program, False), ("B' one program, warm cache", program, True)]:
        fn(cache)  # warm-up (fills the cache for the warm variants)
        rows = []
        for _ in range(runs):
            t = time.time(); ans, ms, ts, trips, read = fn(cache); rows.append((time.time() - t, ms, ts, trips, read))
        med = lambda i: statistics.median(r[i] for r in rows)
        print(f"{label:28s} total {med(0)*1000:6.0f} ms | model {med(1)*1000:6.0f} | tools {med(2)*1000:5.0f} | trips {med(3):.0f} | tokens re-read {med(4):6.0f} | {ans[:90]!r}")
