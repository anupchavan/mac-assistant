#!/usr/bin/env python3
"""Music source benchmark: speed and coverage from this machine (run it on the Mac in India).

python3 -I experiments/music-bench/bench.py            # all sources, 2 rounds
Only keyless sources; each query is checked for the expected title (and artist) in the raw response.
"""
import json, ssl, sys, time, urllib.parse, urllib.request, statistics, http.client

UA = "Quicky/0.1 (github.com/anupchavan/quicky)"
# (query, must-contain words in title, artist word) — mainstream to niche, OSTs, region-locked, unofficial.
QUERIES = [
    ("kun faya kun", "kun faya", "rahman"),
    ("mera mann kehne laga nautanki saala", "mera mann", "falak"),
    ("pasoori ali sethi", "pasoori", "sethi"),
    ("unravel tk from ling tosite sigure", "unravel", "tk"),
    ("gurenge lisa demon slayer", "gurenge", "lisa"),
    ("dearly beloved kingdom hearts", "dearly beloved", "shimomura"),
    ("hollow knight greenpath", "greenpath", "christopher larkin"),
    ("cornfield chase interstellar", "cornfield chase", "zimmer"),
    ("stay with me chanyeol punch goblin", "stay with me", "chanyeol"),
    ("afreen afreen coke studio", "afreen", "rahat"),
    ("lag ja gale lata mangeshkar", "lag ja gale", "lata"),
    ("bella ciao money heist", "bella ciao", ""),
    ("kaise hua kabir singh", "kaise hua", "vishal"),
    ("one summer's day spirited away joe hisaishi", "one summer", "hisaishi"),
    ("tere bina guru", "tere bina", "rahman"),
    ("aaoge jab tum jab we met", "aaoge jab tum", "rashid"),
    ("blue hour tomorrow x together", "blue hour", "tomorrow"),
    ("main shayar to nahin bobby", "shayar", "shailendra"),
]

ctx = ssl.create_default_context()
conns = {}

def fetch(url, data=None, headers=None):
    u = urllib.parse.urlsplit(url)
    c = conns.get(u.netloc)
    if c is None:
        c = conns[u.netloc] = http.client.HTTPSConnection(u.netloc, context=ctx, timeout=10)
    h = {"User-Agent": UA, "Accept": "application/json"}
    h.update(headers or {})
    path = u.path + ("?" + u.query if u.query else "")
    t0 = time.perf_counter()
    try:
        c.request("POST" if data else "GET", path, body=data, headers=h)
        r = c.getresponse(); body = r.read()
    except Exception as e:
        conns.pop(u.netloc, None)
        return None, (time.perf_counter() - t0) * 1000, str(e)[:60]
    ms = (time.perf_counter() - t0) * 1000
    return body.decode("utf-8", "replace").lower(), ms, r.status

q = urllib.parse.quote
def itunes(country):
    return lambda s: fetch(f"https://itunes.apple.com/search?term={q(s)}&entity=song&limit=10&country={country}")
def deezer(s): return fetch(f"https://api.deezer.com/search?q={q(s)}&limit=10")
def musicbrainz(s):
    time.sleep(1.05)  # their limit is 1 request per second
    return fetch(f"https://musicbrainz.org/ws/2/recording?query={q(s)}&limit=10&fmt=json")
def ytmusic(s):
    body = json.dumps({"context": {"client": {"clientName": "WEB_REMIX", "clientVersion": "1.20241023.01.00", "hl": "en", "gl": "IN"}},
                       "query": s, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"}).encode()
    return fetch("https://music.youtube.com/youtubei/v1/search?prettyPrint=false", body,
                 {"Content-Type": "application/json", "Origin": "https://music.youtube.com"})
def lrclib(s): return fetch(f"https://lrclib.net/api/search?q={q(s)}")

SOURCES = {"itunes-in": itunes("in"), "itunes-us": itunes("us"), "itunes-jp": itunes("jp"),
           "deezer": deezer, "musicbrainz": musicbrainz, "ytmusic": ytmusic, "lrclib": lrclib, "lrclib-synced": lrclib}
only = sys.argv[1:] or list(SOURCES)

for name in only:
    fn = SOURCES[name]
    times, hits, rows, cold = [], 0, [], None
    for rnd in range(2):
        for query, title, artist in QUERIES:
            body, ms, status = fn(query)
            ok = bool(body) and title in body and (artist in body)
            if name == "lrclib-synced": ok = ok and '"syncedlyrics":"[' in body
            if rnd == 1:
                times.append(ms); hits += ok
                rows.append(f"    {'✓' if ok else '✗'} {ms:6.0f} ms {query}" + ("" if status == 200 else f"  [{status}]"))
            elif cold is None:
                cold = ms
    print(f"{name}: {hits}/{len(QUERIES)} found · warm median {statistics.median(times):.0f} ms · p90 {sorted(times)[int(len(times)*0.9)-1]:.0f} ms · cold first {cold:.0f} ms")
    print("\n".join(rows))
