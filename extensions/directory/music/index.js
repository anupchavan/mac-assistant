// Music: songs, albums, lyrics, credits and what's playing.
//
// Sources, measured from India on 22 Oct 2026 (experiments/music-bench, 18 mainstream-to-niche queries):
// - YouTube Music (the web client's own search API): 18/18 found, ~520 ms. The only source with OSTs,
//   anime and game music, Coke Studio and unofficial uploads. Also has lyrics for most songs.
// - iTunes Search (the user's storefront): 18/18 in the India store, ~450 ms. Clean metadata and the
//   Apple Music link.
// - LRCLIB: time-synced lyrics, ~200-400 ms when it answers; rate-limits under load, so answers and
//   misses are cached and YouTube Music's lyrics are the fallback.
// - MusicBrainz: credits, on demand only (one request per second).

const YTM = 'https://music.youtube.com/youtubei/v1/'
const FILTERS = {
  song: 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D',
  album: 'EgWKAQIYAWoKEAkQBRAKEAMQBA%3D%3D',
  artist: 'EgWKAQIgAWoKEAkQBRAKEAMQBA%3D%3D',
}

// MARK: helpers

const enc = s => encodeURIComponent(s)
const mmss = s => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`
const flat = s => (s || '').toLowerCase().replace(/[^\p{L}\p{N}]/gu, '')
const titleKey = s => flat((s || '').toLowerCase().split(/[(\[\-–|]/)[0])

async function getJSON(q, url, opts) {
  const r = await q.fetch(url, Object.assign({ timeoutMs: 4000, headers: { Accept: 'application/json' } }, opts || {}))
  if (r.status === 404) return null
  if (!r.ok) throw new Error(`${url.split("/")[2]} answered ${r.status}`)
  return r.json()
}

// iTunes links carry tracking ("uo=4"); a clean music.apple.com link opens straight in the Music app.
function appleLink(s) {
  if (!s) return ''
  const [base, query] = s.split('?')
  const i = (query || '').split('&').find(p => p.startsWith('i='))
  return i ? `${base}?${i}` : base
}

// Same recording? Covers share a title, so also need a shared artist and, when known, lengths within 5 s.
function same(a, b) {
  const x = flat(a.title), y = flat(b.title)
  const titles = titleKey(a.title) === titleKey(b.title) || (Math.min(x.length, y.length) >= 4 && (x.includes(y) || y.includes(x)))
  if (!titles || !titleKey(a.title)) return false
  const names = s => new Set((s || '').toLowerCase().split(/[,&·]/).map(flat).filter(Boolean))
  const na = names(a.artists), nb = names(b.artists)
  if (![...na].some(n => nb.has(n))) return false
  if (typeof a.seconds === 'number' && typeof b.seconds === 'number' && Math.abs(a.seconds - b.seconds) > 5) return false
  return true
}

// MARK: iTunes

async function itunesSearch(q, query, kind, store) {
  const entity = { album: 'album', artist: 'musicArtist' }[kind] || 'song'
  const j = await getJSON(q, `https://itunes.apple.com/search?term=${enc(query)}&entity=${entity}&limit=8&country=${store || q.country}`)
  return ((j && j.results) || []).map(r => {
    const seconds = r.trackTimeMillis ? r.trackTimeMillis / 1000 : undefined
    return {
      title: r.trackName || r.collectionName || r.artistName || '',
      artists: r.artistName || '',
      album: entity === 'song' ? r.collectionName || '' : '',
      year: (r.releaseDate || '').slice(0, 10),
      length: seconds ? mmss(seconds) : '',
      seconds,
      genre: r.primaryGenreName || '',
      apple: appleLink(r.trackViewUrl || r.collectionViewUrl || r.artistLinkUrl || ''),
      youtube: '',
      sources: ['itunes'],
    }
  })
}

async function itunesAlbum(q, query, store) {
  store = store || q.country
  const j = await getJSON(q, `https://itunes.apple.com/search?term=${enc(query)}&entity=album&limit=1&country=${store}`)
  const a = j && j.results && j.results[0]
  if (!a || !a.collectionId) return null
  const t = await getJSON(q, `https://itunes.apple.com/lookup?id=${a.collectionId}&entity=song&country=${store}`)
  const tracks = ((t && t.results) || []).filter(r => r.wrapperType === 'track').map(r => ({
    n: r.trackNumber || 0, title: r.trackName || '', artists: r.artistName || '',
    length: r.trackTimeMillis ? mmss(r.trackTimeMillis / 1000) : '', seconds: r.trackTimeMillis ? r.trackTimeMillis / 1000 : undefined,
  }))
  if (!tracks.length) return null
  return {
    title: a.collectionName || query, artists: a.artistName || '', year: (a.releaseDate || '').slice(0, 4),
    label: a.copyright || '', youtube: '', tracks,
    ...(store === q.country ? { apple: appleLink(a.collectionViewUrl || '') }
                            : { apple: '', appleOther: appleLink(a.collectionViewUrl || ''), appleOtherStore: store }),
  }
}

// MARK: YouTube Music (the web client's API)

function ytCall(q, path, body) {
  body.context = { client: { clientName: 'WEB_REMIX', clientVersion: '1.20241023.01.00', hl: 'en', gl: q.country.toUpperCase() } }
  return getJSON(q, `${YTM}${path}?prettyPrint=false`, { method: 'POST', body, headers: { Origin: 'https://music.youtube.com' } })
}

// Every object under `key`, anywhere in the response. The page layout shifts; the renderers don't.
function all(key, j) {
  const out = []
  const walk = v => {
    if (Array.isArray(v)) v.forEach(walk)
    else if (v && typeof v === 'object') {
      if (v[key] && typeof v[key] === 'object') out.push(v[key])
      for (const k in v) walk(v[k])
    }
  }
  walk(j)
  return out
}

const runs = d => (d && d.text && d.text.runs) || []
const pageType = r => {
  const b = r.navigationEndpoint && r.navigationEndpoint.browseEndpoint
  const c = b && b.browseEndpointContextSupportedConfigs
  return (c && c.browseEndpointContextMusicConfig && c.browseEndpointContextMusicConfig.pageType) || ''
}

// One row: title, then "Artist • Album • 3:45" (songs) or "Album • Artist • 2019" (albums).
function ytHit(r) {
  const cols = (r.flexColumns || []).map(c => c.musicResponsiveListItemFlexColumnRenderer)
  const titleRun = runs(cols[0])[0]
  if (!titleRun || !titleRun.text) return null
  const parts = cols.slice(1).flatMap(runs)
  const texts = parts.map(p => p.text).filter(t => t && ![' • ', ' & ', ', '].includes(t))
  const artists = parts.filter(p => pageType(p) === 'MUSIC_PAGE_TYPE_ARTIST').map(p => p.text)
  const albumRun = parts.find(p => pageType(p) === 'MUSIC_PAGE_TYPE_ALBUM')
  const length = [...texts].reverse().find(t => /^\d+:\d{2}(:\d{2})?$/.test(t)) || ''
  const year = [...texts].reverse().find(t => /^(19|20)\d{2}$/.test(t)) || ''
  const videoId = (r.playlistItemData && r.playlistItemData.videoId) ||
    (titleRun.navigationEndpoint && titleRun.navigationEndpoint.watchEndpoint && titleRun.navigationEndpoint.watchEndpoint.videoId)
  const browseId = r.navigationEndpoint && r.navigationEndpoint.browseEndpoint && r.navigationEndpoint.browseEndpoint.browseId
  const link = videoId ? `https://music.youtube.com/watch?v=${videoId}` : browseId ? `https://music.youtube.com/browse/${browseId}` : ''
  const seconds = length ? length.split(':').reduce((a, x) => a * 60 + Number(x), 0) : undefined
  const byline = artists.length ? artists.join(', ')
    : texts.find(t => !['Song', 'Album', 'Single', 'EP'].includes(t) && t !== length && t !== year) || ''
  return { title: titleRun.text, artists: byline, album: albumRun ? albumRun.text : '', year, length, seconds,
           genre: '', apple: '', youtube: link, sources: ['youtube'], browseId }
}

async function ytSearch(q, query, kind) {
  const j = await ytCall(q, 'search', { query, params: FILTERS[kind] || FILTERS.song })
  return all('musicResponsiveListItemRenderer', j).map(ytHit).filter(Boolean)
}

async function ytAlbum(q, query) {
  const j = await ytCall(q, 'search', { query, params: FILTERS.album })
  const first = all('musicResponsiveListItemRenderer', j)[0]
  const head = first && ytHit(first)
  if (!head || !head.browseId) return null
  const page = await ytCall(q, 'browse', { browseId: head.browseId })
  const tracks = all('musicResponsiveListItemRenderer', page).map(ytHit).filter(Boolean)
    .map((h, i) => ({ n: i + 1, title: h.title, artists: h.artists, length: h.length, seconds: h.seconds }))
  if (!tracks.length) return null
  return { title: head.title, artists: head.artists, year: head.year, label: '', apple: '', youtube: head.youtube, tracks }
}

// The lyrics tab of the best match (YouTube Music licenses these; most Indian and OST songs have them).
async function ytLyrics(q, title, artist) {
  const hit = (await ytSearch(q, `${title} ${artist}`, 'song'))[0]
  const videoId = hit && hit.youtube.split('v=')[1]
  if (!videoId) return null
  const next = await ytCall(q, 'next', { videoId })
  const browseId = all('tabRenderer', next).map(t => t.endpoint && t.endpoint.browseEndpoint && t.endpoint.browseEndpoint.browseId)
    .find(id => id && id.startsWith('MPLYt'))
  if (!browseId) return null
  const page = await ytCall(q, 'browse', { browseId })
  const shelf = all('musicDescriptionShelfRenderer', page)[0]
  const text = shelf && shelf.description && shelf.description.runs && shelf.description.runs.map(r => r.text)[0]
  if (!text) return null
  const source = ((shelf.footer && shelf.footer.runs) || []).map(r => r.text).join('')
  return { text, source: source || 'YouTube Music' }
}

// MARK: LRCLIB (cached; it rate-limits)

const stripLRC = lrc => lrc.split('\n').map(l => l.replace(/^\[[\d:.]+\]\s?/, '')).join('\n')

// The lines around `t` seconds, the current one marked with ▶.
function around(lrc, t) {
  const lines = lrc.split('\n').map(l => {
    const m = l.match(/^\[(\d+):(\d+(?:\.\d+)?)\]/)
    return m ? [Number(m[1]) * 60 + Number(m[2]), l.slice(m[0].length).trim()] : null
  }).filter(Boolean)
  let i = -1
  lines.forEach(([at], k) => { if (at <= t) i = k })
  if (i < 0) return stripLRC(lrc)
  const from = Math.max(0, i - 3), to = Math.min(lines.length - 1, i + 4)
  return lines.slice(from, to + 1).map(([, text], k) => (from + k === i ? '▶ ' : '  ') + text).join('\n')
}

async function lrclib(q, title, artist, album, seconds) {
  const key = `lrclib|${title}|${artist}`.toLowerCase()
  const cached = q.cache.get(key)
  if (cached !== undefined) return cached          // null = a recent miss
  let found
  try {
    if (artist) {
      let p = `track_name=${enc(title)}&artist_name=${enc(artist)}`
      if (album) p += `&album_name=${enc(album)}`
      if (seconds) p += `&duration=${Math.round(seconds)}`
      found = await getJSON(q, `https://lrclib.net/api/get?${p}`, { timeoutMs: 2500 })
    }
    if (!found) {   // no exact match: the best search hit, synced first
      const list = await getJSON(q, `https://lrclib.net/api/search?track_name=${enc(title)}${artist ? `&artist_name=${enc(artist)}` : ''}`, { timeoutMs: 2500 })
      found = (list || []).find(x => x.syncedLyrics) || (list || [])[0] || null
    }
  } catch (e) {
    q.log('lrclib:', e.message)   // rate limit or network: nothing to cache, fall back
    return undefined
  }
  const plain = found && (found.plainLyrics || (found.syncedLyrics && stripLRC(found.syncedLyrics)))
  const out = plain ? { plain, synced: found.syncedLyrics || '' } : null
  q.cache.set(key, out, out ? 30 * 86400 : 86400)
  return out
}

// MARK: now playing (Music, Spotify; only if already open)

async function nowPlaying(q) {
  for (const [app, scale] of [['Music', 1], ['Spotify', 0.001]]) {
    const out = await q.applescript(`tell application "${app}"
      if player state is not playing then return ""
      set t to current track
      return (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & player position
    end tell`).catch(() => '')
    const f = out.split('\t')
    if (f.length !== 5) continue
    const num = s => Number(String(s).replace(',', '.')) || 0
    return { playing: true, title: f[0], artists: f[1], album: f[2], seconds: num(f[3]) * scale, position: num(f[4]), app }
  }
  return null
}

// MARK: MusicBrainz (one request per second)

let mbLast = 0
async function mb(q, path) {
  const wait = 1050 - (Date.now() - mbLast)
  if (wait > 0) await q.sleep(wait)
  mbLast = Date.now()
  return getJSON(q, `https://musicbrainz.org/ws/2/${path}${path.includes('?') ? '&' : '?'}fmt=json`, { timeoutMs: 5000 })
}

// MARK: tools

exports.search = async ({ query, kind }, q) => {
  kind = kind || 'song'
  // Other storefronts run alongside: a song missing here still gets an Apple Music link from a store
  // that has it, which download tools (Telegram) can use even though it won't play here.
  const abroad = ['nz', 'us'].filter(s => s !== q.country)
  const [y, i, ...foreign] = await Promise.all([
    ytSearch(q, query, kind).catch(e => { q.log('ytmusic:', e.message); return [] }),
    itunesSearch(q, query, kind).catch(e => { q.log('itunes:', e.message); return [] }),
    ...abroad.map(s => itunesSearch(q, query, kind, s).then(rs => rs.map(r => Object.assign(r, { store: s }))).catch(() => [])),
  ])
  // YouTube Music finds more (loose spoken queries, OSTs, unofficial uploads) but often ranks covers
  // first; iTunes lists originals. So: rows both agree on, earliest release first, then iTunes' top pick
  // if it's about the ask, then the rest of YouTube Music.
  const yt = y.slice(0, 10)
  const agreed = [], others = []
  for (const h of yt) {
    const m = i.find(x => same(x, h))
    if (m) agreed.push(Object.assign({}, h, { year: m.year || h.year, album: h.album || m.album, genre: m.genre, apple: m.apple, sources: ['youtube', 'itunes'] }))
    else others.push(h)
  }
  const yr = h => (h.year || '9999').slice(0, 4)
  agreed.sort((a, b) => yr(a).localeCompare(yr(b)))   // stable: ties keep YouTube Music's order
  const asked = new Set(query.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(w => w.length > 2))
  const relevant = h => `${h.title} ${h.artists}`.toLowerCase().split(/[^\p{L}\p{N}]+/u).some(w => asked.has(w))
  const appleOnly = i.filter(m => !yt.some(h => same(m, h))).filter(relevant)
  // Songs only another store has (not here, not in YouTube Music's top 10) still count: they can be downloaded.
  const abroadOnly = []
  for (const f of foreign.flat()) {
    if (!relevant(f) || yt.some(h => same(f, h)) || i.some(m => same(f, m)) || abroadOnly.some(a => same(f, a))) continue
    abroadOnly.push(Object.assign({}, f, { apple: '', appleOther: f.apple, appleOtherStore: f.store }))
  }
  const rows = [...agreed, ...appleOnly.slice(0, 1), ...abroadOnly.slice(0, 1), ...others, ...appleOnly.slice(1), ...abroadOnly.slice(1)].slice(0, 6)
  for (const h of rows) {
    if (h.apple || h.appleOther) continue
    const f = foreign.flat().find(m => same(m, h))
    if (f) Object.assign(h, { appleOther: f.apple, appleOtherStore: f.store, year: h.year || f.year, album: h.album || f.album })
  }
  for (const h of rows) delete h.store
  return {
    store: q.country,
    results: rows.map(({ browseId, ...h }) => Object.assign(h, { match: q.match(query, `${h.title} ${h.artists} ${h.album}`) })),
  }
}

exports.album = async ({ query }, q) => {
  // All stores at once; this country's wins, then another store's (for downloading), then YouTube Music.
  const stores = [q.country, ...['nz', 'us'].filter(s => s !== q.country)]
  const [here, ...abroad] = await Promise.all(stores.map(s => itunesAlbum(q, query, s).catch(() => null)))
  return here || abroad.find(Boolean) || (await ytAlbum(q, query).catch(e => { q.log('ytmusic album:', e.message); return null }))
}

exports.lyrics = async ({ title, artist, album, seconds }, q) => {
  let position
  if (!title) {
    const np = await nowPlaying(q)
    if (!np) throw new Error("nothing is playing in Music or Spotify; ask which song")
    ;({ title, artists: artist, album, seconds, position } = np)
  }
  artist = artist || ''
  const l = await lrclib(q, title, artist, album || '', seconds)
  if (l) {
    const text = position !== undefined && l.synced ? around(l.synced, position) : l.plain
    return { title, artists: artist, text, synced: !!l.synced, position, source: 'LRCLIB' }
  }
  const y = await ytLyrics(q, title, artist).catch(() => null)
  if (y) return { title, artists: artist, text: y.text, synced: false, position, source: y.source }
  return null
}

exports.now_playing = async (_, q) => (await nowPlaying(q)) || { playing: false }

exports.credits = async ({ title, artist }, q) => {
  // Artist as loose words, not a quoted phrase: "A.R. Rahman" is "A. R. Rahman" in MusicBrainz.
  const words = (artist || '').replace(/[^\p{L}\p{N}]+/gu, ' ').trim()
  const query = `recording:"${title}"` + (words ? ` AND artist:(${words})` : '')
  const r = await mb(q, `recording?limit=1&query=${enc(query)}`)
  const rec = r && r.recordings && r.recordings[0]
  if (!rec) return null
  const full = await mb(q, `recording/${rec.id}?inc=artist-credits+artist-rels+work-rels+releases`)
  if (!full) return null
  const rels = j => (j.relations || []).filter(x => x.artist && x.type).map(x => ({ role: x.type, name: x.artist.name }))
  let credits = rels(full)
  const work = (full.relations || []).find(x => x.type === 'performance' && x.work)
  if (work) {
    const w = await mb(q, `work/${work.work.id}?inc=artist-rels`)
    if (w) credits = credits.concat(rels(w))
  }
  const seen = new Set()
  credits = credits.filter(c => { const k = c.role + c.name; if (seen.has(k)) return false; seen.add(k); return true })
  const rel = (full.releases || [])[0]
  return {
    title: full.title || title,
    artists: (full['artist-credit'] || []).map(a => a.name).join(', '),
    credits,
    firstRelease: rel ? `${rel.title || ''} ${rel.date || ''}`.trim() : '',
  }
}
