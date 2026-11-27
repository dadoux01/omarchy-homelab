.pragma library
.import "Model.js" as Model

// Service integrations for the Services tab. Each entry in CATALOG says how
// to recognise the service from a Docker image, how to authenticate, which
// requests make up a refresh, and how to turn the answers into one generic
// view model the panel renders the same way for every service:
//
//   { state: "ok" | "auth" | "down" | "error", error, version,
//     stats:    [{ label, value }],
//     alerts:   [{ level: "warning" | "error", text }],
//     actions:  [{ id, label, icon }],
//     sections: [{ title, items: [{ id, title, subtitle, meta, progress, on,
//                                   activate, actions: [{ id, icon, tooltip, urgent }], data }] }] }
//
// `t` is the plugin's translate function; parsers never touch the network.

function g(cp) { return String.fromCodePoint(cp) }

var ICON = {
  play: "󰐊", scan: "󰑐", test: "󰸞", web: "󰖟",
  grab: "󰇚", toggle: "󰐥", run: "󰐊", open: "󰏌",
  pause: g(0xF03E4), playPause: g(0xF040E), stop: g(0xF04DB), next: g(0xF04AD), prev: g(0xF04AE),
  up: g(0xF0143), down: g(0xF0140), heat: g(0xF0238), cool: g(0xF0717), auto: g(0xF006A),
  fan: g(0xF0210), dry: g(0xF058E), volume: g(0xF057E), muted: g(0xF0581), power: "󰐥", shield: g(0xF0483), shieldOff: g(0xF099E),
  speed: g(0xF04C5), flask: g(0xF0668), rss: g(0xF046B), search: "󰍉", refresh: "󰑐", check: g(0xF012C), cross: g(0xF0156)
}

var CATALOG = {
  jellyfin: {
    name: "Jellyfin",
    icon: "󰾴",
    image: /(^|\/)jellyfin(:|$)/i,
    port: 8096,
    auth: "mediabrowser",
    fields: [{ key: "apiKey", label: "field.apiKey", password: true }],
    help: "help.jellyfin"
  },
  homeassistant: {
    name: "Home Assistant",
    icon: "󰟐",
    image: /home-?assistant/i,
    port: 8123,
    auth: "bearer",
    fields: [{ key: "apiKey", label: "field.token", password: true }],
    help: "help.homeassistant",
    filter: true,
    filterPlaceholder: "ha.filterPlaceholder"
  },
  prowlarr: {
    name: "Prowlarr",
    icon: "󰍉",
    image: /(^|\/)prowlarr(:|$)/i,
    port: 9696,
    auth: "apikey",
    fields: [{ key: "apiKey", label: "field.apiKey", password: true }],
    help: "help.prowlarr",
    fetchKey: true,
    search: true
  },
  navidrome: {
    name: "Navidrome",
    icon: "󰎇",
    image: /(^|\/)navidrome(:|$)/i,
    port: 4533,
    auth: "subsonic",
    fields: [
      { key: "username", label: "field.username", password: false },
      { key: "password", label: "field.password", password: true }
    ],
    help: "help.navidrome"
  },
  sonarr: {
    name: "Sonarr",
    icon: g(0xF0502),
    image: /(^|\/)sonarr(:|$)/i,
    port: 8989,
    auth: "apikey",
    fields: [{ key: "apiKey", label: "field.apiKey", password: true }],
    help: "help.arr",
    fetchKey: true
  },
  radarr: {
    name: "Radarr",
    icon: g(0xF0FCE),
    image: /(^|\/)radarr(:|$)/i,
    port: 7878,
    auth: "apikey",
    fields: [{ key: "apiKey", label: "field.apiKey", password: true }],
    help: "help.arr",
    fetchKey: true
  },
  qbittorrent: {
    name: "qBittorrent",
    icon: g(0xF01DA),
    image: /qbittorrent/i,
    port: 8080,
    auth: "qbittorrent",
    fields: [
      { key: "username", label: "field.username", password: false },
      { key: "password", label: "field.password", password: true }
    ],
    help: "help.qbittorrent"
  },
  transmission: {
    name: "Transmission",
    icon: g(0xF01DA),
    image: /(^|\/)transmission(:|$|-)/i,
    port: 9091,
    auth: "transmission",
    fields: [
      { key: "username", label: "field.username", password: false, optional: true },
      { key: "password", label: "field.password", password: true, optional: true }
    ],
    help: "help.transmission"
  },
  pihole: {
    name: "Pi-hole",
    icon: g(0xF0483),
    image: /(^|\/)pihole(:|$)/i,
    port: 80,
    auth: "pihole",
    fields: [{ key: "password", label: "field.password", password: true }],
    help: "help.pihole"
  },
  adguard: {
    name: "AdGuard Home",
    icon: g(0xF0483),
    image: /adguardhome/i,
    port: 80,
    auth: "basic",
    fields: [
      { key: "username", label: "field.username", password: false },
      { key: "password", label: "field.password", password: true }
    ],
    help: "help.adguard"
  }
}

var ORDER = ["homeassistant", "jellyfin", "navidrome", "sonarr", "radarr", "prowlarr", "qbittorrent", "transmission", "pihole", "adguard"]

// True when every non-optional credential field is stored.
function hasSecret(svc, have) {
  var fields = CATALOG[svc.id].fields
  for (var i = 0; i < fields.length; i++)
    if (!fields[i].optional && (have || []).indexOf(fields[i].key) < 0) return false
  return true
}

function hostAddress(host) {
  if (host.address) return host.address
  var t = String(host.target || "")
  var at = t.lastIndexOf("@")
  return at >= 0 ? t.slice(at + 1) : t
}

function bracket(ip) {
  return ip.indexOf(":") >= 0 && ip[0] !== "[" ? "[" + ip + "]" : ip
}

// "0.0.0.0:8096->8096/tcp, [::]:8096->8096/tcp" -> base URL for the service.
// The service's usual port wins; otherwise the first TCP port that is not
// also published over UDP (those carry traffic: BitTorrent, DNS…), so a
// qBittorrent web UI moved to 8081 is not mistaken for its 6881 peer port.
function urlFromPorts(ports, defaultPort, host) {
  var best = null, fallback = null
  var parts = String(ports || "").split(",")
  var udp = {}
  for (var u = 0; u < parts.length; u++) {
    var mu = /->(\d+)\/udp/.exec(parts[u])
    if (mu) udp[mu[1]] = true
  }
  for (var i = 0; i < parts.length; i++) {
    var m = /^\s*(.*):(\d+)->(\d+)\/tcp/.exec(parts[i])
    if (!m) continue
    var entry = { ip: m[1], hostPort: m[2], containerPort: parseInt(m[3], 10) }
    if (entry.containerPort === defaultPort) { best = entry; break }
    if (!best && !udp[m[3]]) best = entry
    if (!fallback) fallback = entry
  }
  best = best || fallback
  var addr = hostAddress(host)
  if (!best) return "http://" + bracket(addr) + ":" + defaultPort
  var ip = best.ip.replace(/^\[|\]$/g, "")
  if (ip === "0.0.0.0" || ip === "::" || ip === "") ip = addr
  return "http://" + bracket(ip) + ":" + best.hostPort
}

// Detected (from Docker) plus configured services for one host.
function list(host, docker) {
  if (!host) return []
  var overrides = host.services || {}
  var found = {}
  var containers = docker && docker.containers ? docker.containers : []
  for (var i = 0; i < containers.length; i++) {
    var c = containers[i]
    for (var id in CATALOG) {
      if (found[id] || !CATALOG[id].image.test(c.image)) continue
      found[id] = { container: c.name, running: c.state === "running", url: urlFromPorts(c.ports, CATALOG[id].port, host) }
    }
  }
  var out = []
  for (var k = 0; k < ORDER.length; k++) {
    var sid = ORDER[k]
    var o = overrides[sid] || null
    var f = found[sid] || null
    if (o && o.enabled === false) continue
    if (!f && !(o && o.url)) continue
    out.push({
      id: sid,
      key: host.key + "/" + sid,
      name: CATALOG[sid].name,
      icon: CATALOG[sid].icon,
      url: o && o.url ? o.url : f.url,
      insecure: !!(o && o.insecure),
      container: f ? f.container : (o && o.container ? o.container : ""),
      detected: !!f,
      running: f ? f.running : true,
      options: o || {}
    })
  }
  return out
}

// ---------- refresh plans ----------

var HA_AREA_TEMPLATE = "{%- set ns = namespace(o=[]) -%}{%- for s in states -%}{%- set a = area_name(s.entity_id) -%}"
  + "{%- if a -%}{%- set ns.o = ns.o + [[s.entity_id, a]] -%}{%- endif -%}{%- endfor -%}{{ ns.o | tojson }}"

var TR_TORRENT_FIELDS = ["id", "name", "status", "percentDone", "rateDownload", "rateUpload", "eta", "totalSize", "error", "errorString", "addedDate"]

function day(offset) {
  var d = new Date(Date.now() + offset * 86400000)
  return d.toISOString().slice(0, 10)
}

// Requests that make up one refresh: { key, path, method?, body? }.
function plan(service) {
  switch (service.id) {
  case "jellyfin": return [
    { key: "info", path: "/System/Info" },
    { key: "sessions", path: "/Sessions?activeWithinSeconds=960" },
    { key: "counts", path: "/Items/Counts" },
    { key: "tasks", path: "/ScheduledTasks?isHidden=false" },
    { key: "latest", path: "/Items?SortBy=DateCreated&SortOrder=Descending&Recursive=true&IncludeItemTypes=Movie,Episode,MusicAlbum&Limit=8&Fields=ProductionYear" }
  ]
  case "homeassistant": return [
    { key: "config", path: "/api/config" },
    { key: "states", path: "/api/states" },
    { key: "areas", path: "/api/template", method: "POST", body: JSON.stringify({ template: HA_AREA_TEMPLATE }) }
  ]
  case "prowlarr": return [
    { key: "status", path: "/api/v1/system/status" },
    { key: "health", path: "/api/v1/health" },
    { key: "indexers", path: "/api/v1/indexer" },
    { key: "istatus", path: "/api/v1/indexerstatus" },
    { key: "history", path: "/api/v1/history?page=1&pageSize=10&sortKey=date&sortDirection=descending" }
  ]
  case "navidrome": return [
    { key: "ping", path: "/rest/ping.view" },
    { key: "scan", path: "/rest/getScanStatus.view" },
    { key: "playing", path: "/rest/getNowPlaying.view" },
    { key: "newest", path: "/rest/getAlbumList2.view?type=newest&size=8" },
    { key: "playlists", path: "/rest/getPlaylists.view" }
  ]
  case "sonarr": return [
    { key: "status", path: "/api/v3/system/status" },
    { key: "health", path: "/api/v3/health" },
    { key: "queue", path: "/api/v3/queue?page=1&pageSize=20&includeSeries=true&includeEpisode=true" },
    { key: "calendar", path: "/api/v3/calendar?start=" + day(0) + "&end=" + day(7) + "&includeSeries=true" },
    { key: "missing", path: "/api/v3/wanted/missing?page=1&pageSize=1" }
  ]
  case "radarr": return [
    { key: "status", path: "/api/v3/system/status" },
    { key: "health", path: "/api/v3/health" },
    { key: "queue", path: "/api/v3/queue?page=1&pageSize=20&includeMovie=true" },
    { key: "calendar", path: "/api/v3/calendar?start=" + day(-1) + "&end=" + day(30) },
    { key: "missing", path: "/api/v3/wanted/missing?page=1&pageSize=1" }
  ]
  case "qbittorrent": return [
    { key: "version", path: "/api/v2/app/version" },
    { key: "webapi", path: "/api/v2/app/webapiVersion" },
    { key: "transfer", path: "/api/v2/transfer/info" },
    { key: "altspeed", path: "/api/v2/transfer/speedLimitsMode" },
    { key: "torrents", path: "/api/v2/torrents/info?sort=added_on&reverse=true" }
  ]
  case "transmission": return [
    { key: "session", path: "/transmission/rpc", method: "POST", body: JSON.stringify({ method: "session-get", arguments: { fields: ["version", "alt-speed-enabled"] } }) },
    { key: "stats", path: "/transmission/rpc", method: "POST", body: JSON.stringify({ method: "session-stats" }) },
    { key: "torrents", path: "/transmission/rpc", method: "POST", body: JSON.stringify({ method: "torrent-get", arguments: { fields: TR_TORRENT_FIELDS } }) }
  ]
  case "pihole": return [
    { key: "summary", path: "/api/stats/summary" },
    { key: "blocking", path: "/api/dns/blocking" },
    { key: "blocked", path: "/api/stats/top_domains?blocked=true&count=8" },
    { key: "clients", path: "/api/stats/top_clients?count=6" },
    { key: "version", path: "/api/info/version" }
  ]
  case "adguard": return [
    { key: "status", path: "/control/status" },
    { key: "stats", path: "/control/stats" }
  ]
  }
  return []
}

var ENTITY_RE = /^[a-z_]+\.[A-Za-z0-9_]+$/

function haCall(domain, service, data) {
  return { method: "POST", path: "/api/services/" + domain + "/" + service, body: JSON.stringify(data) }
}

function clampNum(v, lo, hi) {
  var n = Number(v)
  if (!isFinite(n)) return null
  return Math.max(lo, Math.min(hi, n))
}

function allowed(d, kind, value) {
  return typeof value === "string" && arr(d.modes && d.modes[kind]).indexOf(value) >= 0
}

function homeAssistantAction(actionId, d, value) {
  var id = d.entityId || ""
  if (!ENTITY_RE.test(id)) return null
  var domain = id.split(".")[0]
  var target = { entity_id: id }
  var call = function(svc, extra) { return haCall(domain, svc, Object.assign(extra || {}, target)) }
  var v
  switch (actionId) {
  case "toggle": {
    var svc = HA_SERVICE[domain]
    return svc ? haCall(svc[0], svc[1], target) : null
  }
  case "bright":
    if (domain !== "light" || (v = clampNum(value, 0, 100)) === null) return null
    return v === 0 ? call("turn_off") : call("turn_on", { brightness_pct: Math.round(v) })
  case "ct": {
    var ct = arr(d.ct)
    if (domain !== "light" || ct.length !== 2 || (v = clampNum(value, ct[0], ct[1])) === null) return null
    return call("turn_on", { color_temp_kelvin: Math.round(v) })
  }
  case "rgb":
    if (domain !== "light" || !Array.isArray(value) || value.length !== 3) return null
    var rgb = value.map(function(c) { return clampNum(c, 0, 255) })
    if (rgb.some(function(c) { return c === null })) return null
    return call("turn_on", { rgb_color: rgb.map(Math.round) })
  case "fanpct":
    if (domain !== "fan" || (v = clampNum(value, 0, 100)) === null) return null
    return call("set_percentage", { percentage: Math.round(v) })
  case "osc":
    if (domain !== "fan" || (value !== "on" && value !== "off")) return null
    return call("oscillate", { oscillating: value === "on" })
  case "direction":
    if (domain !== "fan" || !allowed(d, "direction", value)) return null
    return call("set_direction", { direction: value })
  case "preset":
    if ((domain !== "fan" && domain !== "climate") || !allowed(d, "preset", value)) return null
    return call("set_preset_mode", { preset_mode: value })
  case "fanMode":
    if (domain !== "climate" || !allowed(d, "fanMode", value)) return null
    return call("set_fan_mode", { fan_mode: value })
  case "humMode":
    if (domain !== "humidifier" || !allowed(d, "humMode", value)) return null
    return call("set_mode", { mode: value })
  case "hum":
    if ((domain !== "humidifier" && domain !== "climate") || (v = clampNum(value, 0, 100)) === null) return null
    return call("set_humidity", { humidity: Math.round(v) })
  case "option":
    if ((domain !== "select" && domain !== "input_select") || !allowed(d, "option", value)) return null
    return call("select_option", { option: value })
  case "number": {
    var nr = arr(d.number)
    if ((domain !== "number" && domain !== "input_number") || nr.length !== 2 || (v = clampNum(value, nr[0], nr[1])) === null) return null
    return call("set_value", { value: v })
  }
  case "source":
    if (domain !== "media_player" || !allowed(d, "source", value)) return null
    return call("select_source", { source: value })
  case "mute": return domain === "media_player" ? call("volume_mute", { is_volume_muted: !d.muted }) : null
  case "autoRun": return domain === "automation" ? call("trigger", { skip_condition: false }) : null
  case "coverOpen": return domain === "cover" ? call("open_cover") : null
  case "coverClose": return domain === "cover" ? call("close_cover") : null
  case "coverStop": return domain === "cover" ? call("stop_cover") : null
  case "coverPos":
    if (domain !== "cover" || (v = clampNum(value, 0, 100)) === null) return null
    return call("set_cover_position", { position: Math.round(v) })
  case "temp":
    if (domain !== "climate" || (v = clampNum(value, -50, 100)) === null) return null
    return call("set_temperature", { temperature: Math.round(v * 10) / 10 })
  case "tempLow":
  case "tempHigh": {
    var r = arr(d.range)
    if (domain !== "climate" || r.length !== 2 || (v = clampNum(value, -50, 100)) === null) return null
    var lo = actionId === "tempLow" ? v : r[0], hi = actionId === "tempHigh" ? v : r[1]
    if (lo > hi) return null
    return call("set_temperature", { target_temp_low: Math.round(lo * 10) / 10, target_temp_high: Math.round(hi * 10) / 10 })
  }
  case "mpPrev": return domain === "media_player" ? call("media_previous_track") : null
  case "mpPlay": return domain === "media_player" ? call("media_play_pause") : null
  case "mpNext": return domain === "media_player" ? call("media_next_track") : null
  case "mpPower": return domain === "media_player" ? call("toggle") : null
  case "vol":
    if (domain !== "media_player" || (v = clampNum(value, 0, 100)) === null) return null
    return call("volume_set", { volume_level: Math.round(v) / 100 })
  }
  var m = /^hvac:([a-z_]{1,20})$/.exec(actionId)
  if (m && domain === "climate" && allowed(d, "hvac", m[1])) return call("set_hvac_mode", { hvac_mode: m[1] })
  return null
}

function form(obj) {
  var parts = []
  for (var k in obj) parts.push(k + "=" + encodeURIComponent(obj[k]))
  return parts.join("&")
}

function trRpc(method, args) {
  return { method: "POST", path: "/transmission/rpc", body: JSON.stringify(args ? { method: method, arguments: args } : { method: method }) }
}

// Service- or item-level action -> one request, or null. `value` comes from
// a slider.
function actionRequest(service, actionId, item, value) {
  var d = item && item.data ? item.data : {}
  if (service.id === "homeassistant") return homeAssistantAction(actionId, d, value)
  switch (service.id + ":" + actionId) {
  case "jellyfin:scan": return { method: "POST", path: "/Library/Refresh" }
  case "jellyfin:playPause":
  case "jellyfin:stop":
    if (!/^[A-Za-z0-9-]{1,64}$/.test(d.session || "")) return null
    return { method: "POST", path: "/Sessions/" + d.session + "/Playing/" + (actionId === "stop" ? "Stop" : "PlayPause") }
  case "jellyfin:runTask":
    if (!/^[A-Za-z0-9-]{1,64}$/.test(d.task || "")) return null
    return { method: "POST", path: "/ScheduledTasks/Running/" + d.task }
  case "navidrome:scan": return { method: "GET", path: "/rest/startScan.view" }
  case "navidrome:fullscan": return { method: "GET", path: "/rest/startScan.view?fullScan=true" }
  case "prowlarr:testall": return { method: "POST", path: "/api/v1/indexer/testall" }
  case "prowlarr:grab":
    if (!d.guid || !(d.indexerId > 0)) return null
    return { method: "POST", path: "/api/v1/search", body: JSON.stringify({ guid: d.guid, indexerId: d.indexerId }) }
  case "prowlarr:enable":
    if (!(d.indexerId > 0)) return null
    return { method: "PUT", path: "/api/v1/indexer/bulk", body: JSON.stringify({ ids: [d.indexerId], enable: !d.enabled }) }
  case "prowlarr:test":
    if (!(d.indexerId > 0) || !d.raw) return null
    return { method: "POST", path: "/api/v1/indexer/test", body: JSON.stringify(d.raw) }
  case "sonarr:missing": return { method: "POST", path: "/api/v3/command", body: JSON.stringify({ name: "MissingEpisodeSearch" }) }
  case "radarr:missing": return { method: "POST", path: "/api/v3/command", body: JSON.stringify({ name: "MissingMoviesSearch" }) }
  case "sonarr:rss":
  case "radarr:rss": return { method: "POST", path: "/api/v3/command", body: JSON.stringify({ name: "RssSync" }) }
  case "sonarr:refresh": return { method: "POST", path: "/api/v3/command", body: JSON.stringify({ name: "RefreshSeries" }) }
  case "radarr:refresh": return { method: "POST", path: "/api/v3/command", body: JSON.stringify({ name: "RefreshMovie" }) }
  case "qbittorrent:pause":
  case "qbittorrent:resume":
  case "qbittorrent:pauseAll":
  case "qbittorrent:resumeAll": {
    var hashes = /All$/.test(actionId) ? "all" : d.hash
    if (hashes !== "all" && !/^[a-f0-9]{40,64}$/.test(hashes || "")) return null
    var stop = /^pause/.test(actionId)
    var v5 = !!d.v5
    return { method: "POST", path: "/api/v2/torrents/" + (stop ? (v5 ? "stop" : "pause") : (v5 ? "start" : "resume")), body: form({ hashes: hashes }) }
  }
  case "qbittorrent:altspeed": return { method: "POST", path: "/api/v2/transfer/toggleSpeedLimitsMode", body: "" }
  case "transmission:pause":
  case "transmission:resume":
    if (!(d.id > 0)) return null
    return trRpc(actionId === "pause" ? "torrent-stop" : "torrent-start", { ids: [d.id] })
  case "transmission:pauseAll": return trRpc("torrent-stop")
  case "transmission:resumeAll": return trRpc("torrent-start")
  case "transmission:altspeed": return trRpc("session-set", { "alt-speed-enabled": !d.alt })
  case "pihole:disable5": return { method: "POST", path: "/api/dns/blocking", body: JSON.stringify({ blocking: false, timer: 300 }) }
  case "pihole:disable": return { method: "POST", path: "/api/dns/blocking", body: JSON.stringify({ blocking: false, timer: null }) }
  case "pihole:enable": return { method: "POST", path: "/api/dns/blocking", body: JSON.stringify({ blocking: true, timer: null }) }
  case "adguard:disable5": return { method: "POST", path: "/control/protection", body: JSON.stringify({ enabled: false, duration: 300000 }) }
  case "adguard:disable": return { method: "POST", path: "/control/protection", body: JSON.stringify({ enabled: false }) }
  case "adguard:enable": return { method: "POST", path: "/control/protection", body: JSON.stringify({ enabled: true }) }
  }
  return null
}

// Did an action's answer mean success? (status is already 2xx)
function actionOk(service, res) {
  try {
    if (service.id === "navidrome") return JSON.parse(res.body)["subsonic-response"].status === "ok"
    if (service.id === "transmission") return JSON.parse(res.body).result === "success"
    if (service.id === "qbittorrent") return !/^Fails/.test(res.body || "")
  } catch (e) { return false }
  return true
}

function searchRequest(service, query) {
  var q = String(query || "").trim().slice(0, 200)
  if (service.id !== "prowlarr" || q === "") return null
  return { key: "search", path: "/api/v1/search?type=search&limit=40&query=" + encodeURIComponent(q).replace(/[!'()]/g, escape) }
}

// ---------- parsing helpers ----------

function json(res) {
  if (!res || res.status < 200 || res.status >= 300) return null
  try { return JSON.parse(res.body) } catch (e) { return null }
}

function arr(v) { return Array.isArray(v) ? v : [] }

function stat(label, value) { return { label: label, value: String(value) } }

// Shared failure mapping: missing secret, rejected secret, unreachable.
function failure(results, t) {
  var any = null
  for (var k in results) {
    var r = results[k]
    if (r.missingSecret) return { state: "auth", error: t("service.needsSecret") }
    if (r.status === 401 || r.status === 403) return { state: "auth", error: t("service.rejected") }
    if (r.status >= 200 && r.status < 300) any = r
  }
  if (!any) {
    for (var k2 in results)
      if (results[k2].error) return { state: "down", error: Model.clip(results[k2].error, 200) }
    return { state: "down", error: t("service.unreachable") }
  }
  return null
}

function base() {
  return { state: "ok", error: "", version: "", stats: [], alerts: [], actions: [], sections: [] }
}

function ticks(v) { return Model.num(v) }

// ---------- per service ----------

function jellyfinImage(service, id, height) {
  if (service.insecure || !/^[A-Za-z0-9-]{1,64}$/.test(id || "")) return ""
  return service.url + "/Items/" + id + "/Images/Primary?fillHeight=" + height + "&quality=80"
}

function parseJellyfin(results, t, fmt, service) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var info = json(results.info) || {}
  vm.version = Model.clip(info.Version || "", 24)
  if (info.HasPendingRestart) vm.alerts.push({ level: "warning", text: t("alert.jellyfinRestart") })
  if (info.HasUpdateAvailable) vm.alerts.push({ level: "warning", text: t("jellyfin.updateAvailable") })
  var counts = json(results.counts) || {}
  var countKeys = [["MovieCount", "jellyfin.movies"], ["SeriesCount", "jellyfin.series"], ["EpisodeCount", "jellyfin.episodes"],
                   ["AlbumCount", "jellyfin.albums"], ["SongCount", "jellyfin.songs"]]
  for (var i = 0; i < countKeys.length; i++) {
    var n = Model.num(counts[countKeys[i][0]])
    if (n > 0) vm.stats.push(stat(t(countKeys[i][1]), fmt(n, 0)))
  }
  var playing = []
  var sessions = arr(json(results.sessions))
  for (var s = 0; s < sessions.length && playing.length < 12; s++) {
    var ss = sessions[s] || {}
    var it = ss.NowPlayingItem
    if (!it) continue
    var ps = ss.PlayState || {}
    var title = it.SeriesName ? it.SeriesName + " — " + (it.Name || "") : (it.Name || "")
    var run = ticks(it.RunTimeTicks)
    var controllable = ss.SupportsRemoteControl !== false && /^[A-Za-z0-9-]{1,64}$/.test(ss.Id || "")
    playing.push({
      id: "session:" + Model.clip(ss.Id, 64),
      title: Model.clip(title, 90),
      subtitle: Model.clip([ss.UserName, ss.DeviceName || ss.Client].filter(Boolean).join(" · "), 90),
      meta: ps.IsPaused ? t("state.paused") : (ps.PlayMethod === "Transcode" ? t("jellyfin.transcoding") : t("state.playing")),
      progress: run > 0 ? Math.max(0, Math.min(1, ticks(ps.PositionTicks) / run)) : -1,
      image: jellyfinImage(service, it.SeriesId || it.AlbumId || it.Id, 96),
      data: { session: ss.Id },
      actions: controllable ? [
        { id: "playPause", icon: ps.IsPaused ? ICON.play : ICON.pause, tooltip: t(ps.IsPaused ? "ha.play" : "ha.pause") },
        { id: "stop", icon: ICON.stop, tooltip: t("ha.stop") }
      ] : []
    })
  }
  vm.stats.push(stat(t("jellyfin.streams"), fmt(playing.length, 0)))
  vm.sections.push({ title: t("section.nowPlaying"), empty: t("jellyfin.idle"), items: playing })

  var latest = arr((json(results.latest) || {}).Items)
  if (latest.length > 0) {
    vm.sections.push({ title: t("jellyfin.latest"), items: latest.slice(0, 8).map(function(x) {
      var name = x.Type === "Episode" && x.SeriesName ? x.SeriesName + " — " + (x.Name || "") : (x.Name || "")
      var kind = t("jellyfin.type." + x.Type) !== "jellyfin.type." + x.Type ? t("jellyfin.type." + x.Type) : (x.Type || "")
      return { id: "latest:" + Model.clip(x.Id, 64), title: Model.clip(name, 90),
               subtitle: Model.clip([kind, x.ProductionYear, x.AlbumArtist].filter(Boolean).join(" · "), 80),
               meta: x.DateCreated ? ago(x.DateCreated, t) : "",
               progress: -1, image: jellyfinImage(service, x.Type === "Episode" ? (x.SeriesId || x.Id) : x.Id, 96), actions: [] }
    }) })
  }

  var tasks = arr(json(results.tasks)).filter(function(x) { return x && x.Id })
  tasks.sort(function(x, y) { return (y.State === "Running") - (x.State === "Running") || String(x.Name).localeCompare(String(y.Name)) })
  if (tasks.length > 0) {
    vm.sections.push({ title: t("section.scheduledTasks"), items: tasks.slice(0, 10).map(function(x) {
      var running = x.State === "Running"
      var last = x.LastExecutionResult || {}
      var when = last.EndTimeUtc ? ago(last.EndTimeUtc, t) : ""
      return { id: "task:" + Model.clip(x.Id, 64), title: Model.clip(x.Name, 80),
               subtitle: Model.clip([x.Category, when].filter(Boolean).join(" · "), 80),
               meta: running ? fmt(Model.num(x.CurrentProgressPercentage), 0) + " %" : (last.Status === "Failed" ? t("jellyfin.taskFailed") : ""),
               progress: running ? Model.num(x.CurrentProgressPercentage) / 100 : -1,
               data: { task: x.Id },
               actions: running ? [] : [{ id: "runTask", icon: ICON.play, tooltip: t("jellyfin.runTask") }] }
    }) })
  }
  vm.actions.push({ id: "scan", label: t("action.scanLibrary"), icon: ICON.scan })
  return vm
}

var HA_SERVICE = {
  light: ["light", "toggle"], switch: ["switch", "toggle"], fan: ["fan", "toggle"],
  input_boolean: ["input_boolean", "toggle"], automation: ["automation", "toggle"],
  humidifier: ["humidifier", "toggle"],
  scene: ["scene", "turn_on"], script: ["script", "turn_on"],
  button: ["button", "press"], input_button: ["input_button", "press"],
  media_player: ["media_player", "toggle"]
}
// Shown without an explicit entity list, in this order.
var HA_DEFAULT_DOMAINS = ["light", "switch", "fan", "cover", "climate", "humidifier", "media_player", "input_boolean",
                          "sensor", "binary_sensor", "scene", "script", "automation"]
var HA_SENSOR_CLASSES = { temperature: 1, humidity: 1, power: 1, aqi: 1, pm25: 1, carbon_dioxide: 1 }
var HA_BINARY_CLASSES = { door: 1, window: 1, opening: 1, motion: 1, garage_door: 1 }
// Sections that stay per domain: they rarely belong to a room.
var HA_GLOBAL_DOMAINS = { scene: 1, script: 1, automation: 1, button: 1, input_button: 1, input_boolean: 1 }
var HVAC_ICON = { off: ICON.power, heat: ICON.heat, cool: ICON.cool, heat_cool: ICON.auto, auto: ICON.auto, fan_only: ICON.fan, dry: ICON.dry }
// One-click colors, as in Omahome. Whites are RGB approximations.
var RGB_PRESETS = [
  [255, 0, 0], [255, 128, 0], [255, 255, 0], [0, 255, 0], [0, 255, 255], [0, 0, 255], [128, 0, 255], [255, 64, 160],
  [255, 197, 143], [255, 255, 255], [201, 226, 255], [128, 255, 191], [192, 160, 255], [255, 180, 128]
]
var RGB_MODES = { rgb: 1, rgbw: 1, rgbww: 1, hs: 1, xy: 1 }

function haDefault(st) {
  var domain = st.entity_id.split(".")[0]
  if (HA_DEFAULT_DOMAINS.indexOf(domain) < 0 || st.state === "unavailable") return false
  var cls = (st.attributes || {}).device_class
  if (domain === "sensor") return !!HA_SENSOR_CLASSES[cls]
  if (domain === "binary_sensor") return !!HA_BINARY_CLASSES[cls]
  return true
}

function strList(v, max) {
  return arr(v).filter(function(x) { return typeof x === "string" && x.length > 0 && x.length <= 64 }).slice(0, max || 12)
}

// A row of text choices: { id, label, options: [{ value, label, active }] }.
function choice(id, label, values, current, word) {
  return { id: id, label: label, options: values.map(function(v) { return { value: v, label: word ? word(v) : v, active: v === current } }) }
}

function haItem(e, t, fmt) {
  var domain = e.entity_id.split(".")[0]
  var a = e.attributes || {}
  var on = e.state === "on"
  var features = Model.num(a.supported_features)
  var unit = a.unit_of_measurement ? " " + a.unit_of_measurement : ""
  var item = {
    id: e.entity_id,
    title: Model.clip(a.friendly_name || e.entity_id, 70),
    subtitle: "",
    meta: Model.clip(String(e.state) + unit, 40),
    progress: -1,
    on: undefined,
    activate: "",
    data: { entityId: e.entity_id, modes: {} },
    actions: [],
    sliders: [],
    choices: []
  }
  var stateWord = function(s) { var k = "ha.state." + s; return t(k) !== k ? t(k) : s }
  var modeWord = function(s) { var k = "ha.mode." + s; return t(k) !== k ? t(k) : String(s).replace(/_/g, " ") }
  var addChoice = function(id, label, values, current, word) {
    if (values.length === 0) return
    item.data.modes[id] = values
    item.choices.push(choice(id, label, values, current, word || modeWord))
  }
  switch (domain) {
  case "light":
  case "switch":
  case "fan":
  case "input_boolean":
  case "automation":
  case "humidifier": {
    item.on = on
    item.activate = "toggle"
    item.meta = stateWord(e.state)
    if (domain === "automation") item.actions.push({ id: "autoRun", icon: ICON.run, tooltip: t("ha.runAutomation") })
    item.actions.push({ id: "toggle", icon: ICON.toggle, tooltip: t(domain === "automation" ? "ha.enableAutomation" : "ha.toggle"), active: on })
    if (domain === "light") {
      var cmodes = arr(a.supported_color_modes)
      var dimmable = cmodes.some(function(m) { return m !== "onoff" && m !== "unknown" })
      if (dimmable)
        item.sliders.push({ id: "bright", value: on ? Math.round(Model.num(a.brightness) / 255 * 100) : 0, min: 0, max: 100, step: 1, unit: " %", label: t("ha.brightness") })
      if (cmodes.indexOf("color_temp") >= 0) {
        var kmin = Model.num(a.min_color_temp_kelvin) || 2000, kmax = Model.num(a.max_color_temp_kelvin) || 6500
        item.data.ct = [kmin, kmax]
        item.sliders.push({ id: "ct", value: Model.num(a.color_temp_kelvin) || Math.round((kmin + kmax) / 2), min: kmin, max: kmax, step: 50, unit: " K", label: t("ha.colorTemp"), gradient: "kelvin" })
      }
      if (cmodes.some(function(m) { return RGB_MODES[m] })) {
        var cur = arr(a.rgb_color).length === 3 ? a.rgb_color.map(Model.num) : null
        item.rgb = { current: on ? cur : null, presets: RGB_PRESETS }
        if (on && cur) item.swatch = cur
      }
    }
    if (domain === "fan") {
      if (features & 1)
        item.sliders.push({ id: "fanpct", value: Model.num(a.percentage), min: 0, max: 100, step: Math.max(1, Model.num(a.percentage_step) || 1), unit: " %", label: t("ha.speed") })
      if (features & 8) addChoice("preset", t("ha.preset"), strList(a.preset_modes), a.preset_mode)
      if (features & 2) addChoice("osc", t("ha.oscillation"), ["on", "off"], a.oscillating ? "on" : "off", stateWord)
      if (features & 4) addChoice("direction", t("ha.direction"), ["forward", "reverse"], a.direction)
    }
    if (domain === "humidifier") {
      if (a.humidity !== undefined && a.humidity !== null)
        item.sliders.push({ id: "hum", value: Model.num(a.humidity), min: Model.num(a.min_humidity) || 0, max: Model.num(a.max_humidity) || 100, step: 1, unit: " %", label: t("ha.targetHumidity") })
      if (a.current_humidity !== undefined) item.subtitle = fmt(Model.num(a.current_humidity), 0) + " %"
      if (features & 1) addChoice("humMode", t("ha.mode"), strList(a.available_modes), a.mode)
    }
    break
  }
  case "cover": {
    item.meta = stateWord(e.state)
    if (!features || features & 1) item.actions.push({ id: "coverOpen", icon: ICON.up, tooltip: t("ha.open") })
    if (!features || features & 8) item.actions.push({ id: "coverStop", icon: ICON.stop, tooltip: t("ha.stop") })
    if (!features || features & 2) item.actions.push({ id: "coverClose", icon: ICON.down, tooltip: t("ha.close") })
    if (a.current_position !== undefined)
      item.sliders.push({ id: "coverPos", value: Model.num(a.current_position), min: 0, max: 100, step: 1, unit: " %", label: t("ha.position") })
    break
  }
  case "climate": {
    var curT = a.current_temperature !== undefined && a.current_temperature !== null ? fmt(Model.num(a.current_temperature), 1) + " °" : ""
    var target = a.temperature !== undefined && a.temperature !== null ? Model.num(a.temperature) : null
    var range = a.target_temp_low !== undefined && a.target_temp_low !== null && a.target_temp_high !== undefined && a.target_temp_high !== null
    var tgt = target !== null ? "→ " + fmt(target, 1) + " °" : range ? "→ " + fmt(Model.num(a.target_temp_low), 1) + "–" + fmt(Model.num(a.target_temp_high), 1) + " °" : ""
    item.meta = [curT, tgt].filter(Boolean).join(" ")
    item.subtitle = [stateWord(e.state), a.hvac_action ? stateWord(a.hvac_action) : "",
                     a.current_humidity !== undefined && a.current_humidity !== null ? fmt(Model.num(a.current_humidity), 0) + " %" : ""].filter(Boolean).join(" · ")
    var modes = strList(a.hvac_modes).filter(function(m) { return HVAC_ICON[m] }).slice(0, 6)
    item.data.modes.hvac = modes
    for (var i = 0; i < modes.length; i++)
      item.actions.push({ id: "hvac:" + modes[i], icon: HVAC_ICON[modes[i]], tooltip: stateWord(modes[i]), active: e.state === modes[i] })
    var step = Model.num(a.target_temp_step) || (a.temperature_unit === "°F" ? 1 : 0.5)
    var tmin = Model.num(a.min_temp) || 7, tmax = Model.num(a.max_temp) || 35
    var dec = step < 1 ? 1 : 0
    if (target !== null) {
      item.sliders.push({ id: "temp", value: target, min: tmin, max: tmax, step: step, unit: " °", label: t("ha.target"), decimals: dec })
    } else if (range) {
      item.data.range = [Model.num(a.target_temp_low), Model.num(a.target_temp_high)]
      item.sliders.push({ id: "tempLow", value: Model.num(a.target_temp_low), min: tmin, max: tmax, step: step, unit: " °", label: t("ha.targetLow"), decimals: dec })
      item.sliders.push({ id: "tempHigh", value: Model.num(a.target_temp_high), min: tmin, max: tmax, step: step, unit: " °", label: t("ha.targetHigh"), decimals: dec })
    }
    if (features & 4 && a.humidity !== undefined && a.humidity !== null)
      item.sliders.push({ id: "hum", value: Model.num(a.humidity), min: Model.num(a.min_humidity) || 0, max: Model.num(a.max_humidity) || 100, step: 1, unit: " %", label: t("ha.targetHumidity") })
    if (features & 16) addChoice("preset", t("ha.preset"), strList(a.preset_modes), a.preset_mode)
    if (features & 8) addChoice("fanMode", t("ha.fanMode"), strList(a.fan_modes), a.fan_mode)
    break
  }
  case "media_player": {
    var playing = e.state === "playing", idle = e.state === "off" || e.state === "standby"
    var what = [a.media_artist, a.media_title].filter(Boolean).join(" — ")
    item.subtitle = Model.clip(what || a.source || "", 80)
    item.meta = stateWord(e.state)
    item.on = !idle
    if (!idle) {
      item.actions.push({ id: "mpPrev", icon: ICON.prev, tooltip: t("ha.previous") })
      item.actions.push({ id: "mpPlay", icon: playing ? ICON.pause : ICON.play, tooltip: t(playing ? "ha.pause" : "ha.play") })
      item.actions.push({ id: "mpNext", icon: ICON.next, tooltip: t("ha.next") })
      if (features & 8 || a.is_volume_muted !== undefined) {
        item.data.muted = !!a.is_volume_muted
        item.actions.push({ id: "mute", icon: a.is_volume_muted ? ICON.muted : ICON.volume, tooltip: t(a.is_volume_muted ? "ha.unmute" : "ha.mute"), active: !!a.is_volume_muted })
      }
      if (a.volume_level !== undefined)
        item.sliders.push({ id: "vol", value: Math.round(Model.num(a.volume_level) * 100), min: 0, max: 100, step: 1, unit: " %", label: t("ha.volume") })
      if (arr(a.source_list).length > 0) addChoice("source", t("ha.source"), strList(a.source_list, 10), a.source, function(v) { return v })
    }
    item.actions.push({ id: "mpPower", icon: ICON.power, tooltip: t("ha.power"), active: !idle })
    break
  }
  case "select":
  case "input_select":
    item.meta = Model.clip(e.state, 30)
    addChoice("option", t("ha.option"), strList(a.options, 12), e.state, function(v) { return v })
    break
  case "number":
  case "input_number":
    if (a.min !== undefined && a.max !== undefined && isFinite(Number(e.state))) {
      var nstep = Model.num(a.step) || 1
      item.data.number = [Model.num(a.min), Model.num(a.max)]
      item.sliders.push({ id: "number", value: Number(e.state), min: Model.num(a.min), max: Model.num(a.max), step: nstep, unit: unit, label: "", decimals: nstep < 1 ? 1 : 0 })
      item.meta = ""
    }
    break
  case "scene":
  case "script":
  case "button":
  case "input_button":
    item.activate = "toggle"
    item.meta = ""
    item.actions.push({ id: "toggle", icon: ICON.run, tooltip: t("ha.run") })
    break
  case "binary_sensor":
    item.meta = stateWord(a.device_class && (e.state === "on" || e.state === "off") ? a.device_class + "." + e.state : e.state)
    item.on = on
    break
  default:
    if (unit !== "" && isFinite(Number(e.state))) item.meta = fmt(Number(e.state), Number(e.state) % 1 === 0 ? 0 : 1) + unit
  }
  // First slider stays on the row; the rest, colors and choices fold away.
  item.expandable = item.sliders.length > 1 || item.choices.length > 0 || !!item.rgb
  return item
}

function parseHomeAssistant(results, t, fmt, options) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var cfg = json(results.config) || {}
  vm.version = Model.clip(cfg.version || "", 24)
  var states = arr(json(results.states))
  var areas = {}
  arr(json(results.areas)).forEach(function(p) { if (Array.isArray(p) && typeof p[0] === "string") areas[p[0]] = Model.clip(p[1], 40) })
  var byId = {}
  var unavailable = 0, lightsOn = 0, updates = 0
  for (var i = 0; i < states.length; i++) {
    var st = states[i]
    if (!st || typeof st.entity_id !== "string") continue
    byId[st.entity_id] = st
    if (st.state === "unavailable") unavailable++
    if (st.entity_id.indexOf("light.") === 0 && st.state === "on") lightsOn++
    if (st.entity_id.indexOf("update.") === 0 && st.state === "on") updates++
  }
  if (cfg.location_name) vm.stats.push(stat(t("ha.home"), Model.clip(cfg.location_name, 40)))
  vm.stats.push(stat(t("ha.lightsOn"), fmt(lightsOn, 0)))
  vm.stats.push(stat(t("ha.entities"), fmt(states.length, 0)))
  if (unavailable > 0) vm.stats.push(stat(t("ha.unavailable"), fmt(unavailable, 0)))
  if (updates > 0) vm.stats.push(stat(t("ha.updates"), fmt(updates, 0)))

  var query = String(options && options.filter || "").trim().toLowerCase()
  var wanted = arr(options && options.entities).filter(function(e) { return typeof e === "string" }).slice(0, 60)
  var picked = []
  if (query !== "") {
    for (var q = 0; q < states.length && picked.length < 60; q++) {
      var sq = states[q]
      if (!sq || !sq.entity_id) continue
      var hay = (sq.entity_id + " " + ((sq.attributes || {}).friendly_name || "") + " " + (areas[sq.entity_id] || "")).toLowerCase()
      if (hay.indexOf(query) >= 0) picked.push(sq)
    }
  } else if (wanted.length > 0) {
    for (var w = 0; w < wanted.length; w++) if (byId[wanted[w]]) picked.push(byId[wanted[w]])
  } else {
    for (var d = 0; d < HA_DEFAULT_DOMAINS.length; d++)
      for (var j = 0; j < states.length; j++) {
        var s2 = states[j]
        if (s2 && s2.entity_id && s2.entity_id.split(".")[0] === HA_DEFAULT_DOMAINS[d] && haDefault(s2)) picked.push(s2)
      }
    picked = picked.slice(0, 80)
  }

  // Rooms first (in Home Assistant's area names), then per-domain sections.
  var groups = {}, roomOrder = [], domainOrder = []
  for (var p = 0; p < picked.length; p++) {
    var e = picked[p]
    var domain = e.entity_id.split(".")[0]
    var item = haItem(e, t, fmt)
    var area = areas[e.entity_id]
    var g
    if (area && !HA_GLOBAL_DOMAINS[domain]) {
      g = area
      if (!groups[g]) roomOrder.push(g)
    } else {
      g = t("ha.domain." + domain) !== "ha.domain." + domain ? t("ha.domain." + domain) : domain
      if (!groups[g]) domainOrder.push(g)
      if (area) item.subtitle = item.subtitle ? area + " · " + item.subtitle : area
    }
    if (!groups[g]) groups[g] = []
    groups[g].push(item)
  }
  roomOrder.sort(function(x, y) { return x.localeCompare(y) })
  var order = roomOrder.concat(domainOrder)
  for (var o = 0; o < order.length; o++) vm.sections.push({ title: order[o], items: groups[order[o]] })
  if (picked.length === 0) vm.sections.push({ title: t("ha.entitiesTitle"), empty: t(query !== "" ? "ha.noMatch" : "ha.noEntities"), items: [] })
  return vm
}

function p2(n) { return (n < 10 ? "0" : "") + n }
// Short, locale-neutral stamps: "14:05", "27/11", "27/11 14:05".
function hhmm(ms) { var d = new Date(ms); return p2(d.getHours()) + ":" + p2(d.getMinutes()) }
function ddmm(ms) { var d = new Date(ms); return p2(d.getDate()) + "/" + p2(d.getMonth() + 1) }

function ago(iso, t) {
  var ms = Date.now() - Date.parse(iso)
  if (!isFinite(ms)) return ""
  var m = Math.max(0, Math.round(ms / 60000))
  if (m < 60) return t("time.minAgo").arg(m)
  if (m < 2880) return t("time.hAgo").arg(Math.round(m / 60))
  return t("time.dAgo").arg(Math.round(m / 1440))
}

function parseProwlarr(results, t, fmt) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var status = json(results.status) || {}
  vm.version = Model.clip(status.version || "", 24)
  var indexers = arr(json(results.indexers))
  var enabled = indexers.filter(function(x) { return x && x.enable }).length
  var names = {}
  for (var i = 0; i < indexers.length; i++) if (indexers[i]) names[indexers[i].id] = indexers[i].name
  var now = Date.now()
  var failingIds = {}
  var failing = arr(json(results.istatus)).filter(function(x) { return x && x.disabledTill && Date.parse(x.disabledTill) > now })
  failing.forEach(function(x) { failingIds[x.indexerId] = x })
  vm.stats.push(stat(t("prowlarr.indexers"), fmt(enabled, 0) + " / " + fmt(indexers.length, 0)))
  vm.stats.push(stat(t("prowlarr.failing"), fmt(failing.length, 0)))
  var health = arr(json(results.health))
  for (var h = 0; h < health.length && h < 8; h++)
    vm.alerts.push({ level: health[h].type === "error" ? "error" : "warning", text: Model.clip(health[h].message, 220) })

  var list = indexers.filter(Boolean).slice(0, 60)
  list.sort(function(x, y) { return (!!failingIds[y.id]) - (!!failingIds[x.id]) || (!!y.enable) - (!!x.enable) || String(x.name).localeCompare(String(y.name)) })
  if (list.length > 0) {
    vm.sections.push({ title: t("prowlarr.indexers"), items: list.map(function(x) {
      var f = failingIds[x.id]
      return {
        id: "idx:" + x.id,
        title: Model.clip(x.name, 60),
        subtitle: Model.clip([x.protocol, x.privacy, f ? t("prowlarr.disabledUntil").arg(hhmm(Date.parse(f.disabledTill))) : ""].filter(Boolean).join(" · "), 90),
        meta: !x.enable ? t("prowlarr.off") : f ? t("prowlarr.failingShort") : "",
        warn: !!f,
        on: !!x.enable,
        progress: -1,
        data: { indexerId: Model.num(x.id), enabled: !!x.enable, raw: x },
        actions: [
          { id: "test", icon: ICON.flask, tooltip: t("prowlarr.test") },
          { id: "enable", icon: ICON.toggle, tooltip: t(x.enable ? "prowlarr.disable" : "prowlarr.enable"), active: !!x.enable }
        ]
      }
    }) })
  }

  var history = arr((json(results.history) || {}).records).slice(0, 10)
  if (history.length > 0) {
    vm.sections.push({ title: t("prowlarr.history"), items: history.map(function(r, i) {
      var d = r.data || {}
      var ev = t("prowlarr.event." + r.eventType) !== "prowlarr.event." + r.eventType ? t("prowlarr.event." + r.eventType) : (r.eventType || "")
      return { id: "h" + i, title: Model.clip(d.grabTitle || d.query || ev, 100),
               subtitle: Model.clip([ev, names[r.indexerId], d.source].filter(Boolean).join(" · "), 90),
               meta: (r.successful === false ? "✗ " : "") + ago(r.date, t), warn: r.successful === false, progress: -1, actions: [] }
    }) })
  }
  vm.actions.push({ id: "testall", label: t("action.testIndexers"), icon: ICON.test })
  return vm
}

function parseProwlarrSearch(res, t, fmt) {
  var rows = arr(json(res)).slice(0, 200)
  rows.sort(function(a, b) { return Model.num(b.seeders) - Model.num(a.seeders) })
  return rows.slice(0, 40).map(function(r, i) {
    var parts = [r.indexer, Model.bytes(r.size, fmt)]
    if (r.seeders !== undefined) parts.push("▲ " + fmt(Model.num(r.seeders), 0))
    if (r.publishDate) parts.push(ddmm(Date.parse(r.publishDate)))
    var actions = []
    if (r.downloadAllowed !== false && r.guid && r.indexerId) actions.push({ id: "grab", icon: ICON.grab, tooltip: t("prowlarr.grab") })
    if (Model.validUrl(r.infoUrl)) actions.push({ id: "open", icon: ICON.open, tooltip: t("action.openPage") })
    return {
      id: "r" + i,
      title: Model.clip(r.title, 120),
      subtitle: Model.clip(parts.filter(Boolean).join(" · "), 120),
      meta: "", progress: -1, actions: actions,
      data: { guid: String(r.guid || "").slice(0, 2048), indexerId: Model.num(r.indexerId), url: Model.validUrl(r.infoUrl) ? r.infoUrl : "" }
    }
  })
}

function subsonic(res) {
  var j = json(res)
  return j && j["subsonic-response"] ? j["subsonic-response"] : null
}

function parseNavidrome(results, t, fmt) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var ping = subsonic(results.ping)
  if (!ping) return Object.assign(base(), { state: "down", error: t("service.unreachable") })
  if (ping.status !== "ok") {
    var code = ping.error ? ping.error.code : 0
    return Object.assign(base(), { state: code === 40 || code === 41 ? "auth" : "error",
                                   error: code === 40 || code === 41 ? t("service.rejected") : Model.clip(ping.error && ping.error.message, 200) })
  }
  var vm = base()
  vm.version = Model.clip(ping.serverVersion || ping.version || "", 24)
  var scan = (subsonic(results.scan) || {}).scanStatus || {}
  vm.stats.push(stat(t("navidrome.songs"), fmt(Model.num(scan.count), 0)))
  if (scan.folderCount !== undefined) vm.stats.push(stat(t("navidrome.folders"), fmt(Model.num(scan.folderCount), 0)))
  vm.stats.push(stat(t("navidrome.scan"), scan.scanning ? t("navidrome.scanning") : t("navidrome.idle")))
  var playlists = arr(((subsonic(results.playlists) || {}).playlists || {}).playlist)
  vm.stats.push(stat(t("navidrome.playlists"), fmt(playlists.length, 0)))
  if (scan.lastScan) vm.stats.push(stat(t("navidrome.lastScan"), ago(scan.lastScan, t)))
  var np = arr(((subsonic(results.playing) || {}).nowPlaying || {}).entry)
  vm.sections.push({ title: t("section.nowPlaying"), empty: t("navidrome.nothing"), items: np.slice(0, 10).map(function(e, i) {
    return { id: "np" + i, title: Model.clip((e.title || "") + (e.artist ? " — " + e.artist : ""), 90),
             subtitle: Model.clip([e.username, e.playerName].filter(Boolean).join(" · "), 80),
             meta: e.minutesAgo > 0 ? t("navidrome.minutesAgo").arg(e.minutesAgo) : t("state.playing"), progress: -1, actions: [] }
  }) })
  var albums = arr(((subsonic(results.newest) || {}).albumList2 || {}).album)
  if (albums.length > 0) {
    vm.sections.push({ title: t("navidrome.newest"), items: albums.slice(0, 8).map(function(a, i) {
      return { id: "al" + i, title: Model.clip(a.name, 80),
               subtitle: Model.clip([a.artist, a.year].filter(Boolean).join(" · "), 80),
               meta: a.songCount ? t("navidrome.tracks").arg(a.songCount) : "", progress: -1, actions: [] }
    }) })
  }
  if (playlists.length > 0) {
    vm.sections.push({ title: t("navidrome.playlistsTitle"), items: playlists.slice(0, 12).map(function(pl, i) {
      return { id: "pl" + i, title: Model.clip(pl.name, 80),
               subtitle: Model.clip([pl.owner, pl.public ? t("navidrome.public") : ""].filter(Boolean).join(" · "), 80),
               meta: [pl.songCount ? t("navidrome.tracks").arg(pl.songCount) : "", pl.duration ? Model.duration(pl.duration) : ""].filter(Boolean).join(" · "),
               progress: -1, actions: [] }
    }) })
  }
  vm.actions.push({ id: "scan", label: t("action.scanLibrary"), icon: ICON.scan })
  vm.actions.push({ id: "fullscan", label: t("navidrome.fullScan"), icon: ICON.refresh })
  return vm
}

var pad2 = p2

function eta(seconds, t) {
  var s = Model.num(seconds)
  if (!(s > 0) || s >= 8640000) return ""
  return t("torrent.eta").arg(Model.duration(s))
}

function healthAlerts(vm, results) {
  var health = arr(json(results.health))
  for (var h = 0; h < health.length && h < 8; h++)
    if (health[h] && health[h].source !== "UpdateCheck")
      vm.alerts.push({ level: health[h].type === "error" ? "error" : "warning", text: Model.clip(health[h].message, 220) })
}

// Sonarr and Radarr share the v3 API shape.
function parseArr(results, t, fmt, service) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var sonarr = service.id === "sonarr"
  var vm = base()
  vm.version = Model.clip((json(results.status) || {}).version || "", 24)
  healthAlerts(vm, results)
  var queue = arr((json(results.queue) || {}).records)
  var missing = json(results.missing)
  var calendar = arr(json(results.calendar))
  var now = Date.now()
  var upcoming = sonarr
    ? calendar.filter(function(e) { return e && Date.parse(e.airDateUtc) >= now - 86400000 })
    : calendar.filter(function(m) { return m && !m.hasFile })
  vm.stats.push(stat(t("arr.queue"), fmt(queue.length, 0)))
  if (missing && missing.totalRecords !== undefined) vm.stats.push(stat(t("arr.missing"), fmt(Model.num(missing.totalRecords), 0)))
  vm.stats.push(stat(t(sonarr ? "arr.upcomingEpisodes" : "arr.upcomingMovies"), fmt(upcoming.length, 0)))

  vm.sections.push({ title: t("arr.queueTitle"), empty: t("arr.queueEmpty"), items: queue.slice(0, 15).map(function(q, i) {
    var size = Model.num(q.size), left = Model.num(q.sizeleft)
    var title
    if (sonarr) {
      var ep = q.episode || {}
      var code = ep.seasonNumber !== undefined ? "S" + pad2(ep.seasonNumber) + "E" + pad2(ep.episodeNumber) : ""
      title = [q.series && q.series.title, code].filter(Boolean).join(" ") || q.title
    } else {
      title = q.movie ? q.movie.title + (q.movie.year ? " (" + q.movie.year + ")" : "") : q.title
    }
    var warn = q.trackedDownloadStatus === "warning" || q.trackedDownloadStatus === "error"
    var msg = warn && q.statusMessages && q.statusMessages[0] && q.statusMessages[0].messages ? q.statusMessages[0].messages[0] : ""
    return { id: "q" + i, title: Model.clip(title, 90),
             subtitle: Model.clip(msg || [t("arr.status." + q.status) !== "arr.status." + q.status ? t("arr.status." + q.status) : q.status, q.downloadClient, size > 0 ? Model.bytes(size, fmt) : ""].filter(Boolean).join(" · "), 100),
             meta: q.timeleft ? String(q.timeleft).replace(/\.\d+$/, "") : (size > 0 ? fmt(Math.round((1 - left / size) * 100), 0) + " %" : ""),
             warn: warn, progress: size > 0 ? Math.max(0, Math.min(1, 1 - left / size)) : -1, actions: [] }
  }) })

  if (sonarr) {
    upcoming.sort(function(x, y) { return Date.parse(x.airDateUtc) - Date.parse(y.airDateUtc) })
    vm.sections.push({ title: t("arr.upcomingTitle"), empty: t("arr.nothingSoon"), items: upcoming.slice(0, 12).map(function(e, i) {
      return { id: "c" + i,
               title: Model.clip([e.series && e.series.title, "S" + pad2(e.seasonNumber) + "E" + pad2(e.episodeNumber)].filter(Boolean).join(" "), 90),
               subtitle: Model.clip(e.title || "", 90),
               meta: ddmm(Date.parse(e.airDateUtc)) + " " + hhmm(Date.parse(e.airDateUtc)),
               on: e.hasFile ? true : undefined, progress: -1, actions: [] }
    }) })
  } else {
    var release = function(m) {
      var ds = [m.digitalRelease, m.physicalRelease, m.inCinemas].filter(Boolean).map(Date.parse).filter(function(x) { return x >= now - 86400000 })
      return ds.length ? Math.min.apply(null, ds) : Infinity
    }
    upcoming.sort(function(x, y) { return release(x) - release(y) })
    vm.sections.push({ title: t("arr.releasesTitle"), empty: t("arr.nothingSoon"), items: upcoming.slice(0, 12).map(function(m, i) {
      var when = release(m)
      return { id: "c" + i, title: Model.clip(m.title + (m.year ? " (" + m.year + ")" : ""), 90),
               subtitle: Model.clip(m.digitalRelease ? t("arr.digital") : m.physicalRelease ? t("arr.physical") : t("arr.cinema"), 60),
               meta: isFinite(when) ? ddmm(when) : "", progress: -1, actions: [] }
    }) })
  }
  vm.actions.push({ id: "missing", label: t("arr.searchMissing"), icon: ICON.search })
  vm.actions.push({ id: "rss", label: t("arr.rssSync"), icon: ICON.rss })
  vm.actions.push({ id: "refresh", label: t(sonarr ? "arr.refreshSeries" : "arr.refreshMovies"), icon: ICON.refresh })
  return vm
}

var QB_ACTIVE = { downloading: 1, forcedDL: 1, metaDL: 1, forcedMetaDL: 1, stalledDL: 1, checkingDL: 1, queuedDL: 1, allocating: 1 }
var QB_PAUSED = { pausedDL: 1, pausedUP: 1, stoppedDL: 1, stoppedUP: 1 }

function torrentItem(id, name, pct, down, up, etaSec, size, paused, error, data, t, fmt) {
  var parts = [fmt(Math.floor(pct * 100), 0) + " %"]
  if (down > 0) parts.push("↓ " + Model.rate(down, fmt))
  if (up > 0) parts.push("↑ " + Model.rate(up, fmt))
  var e = pct < 1 && !paused ? eta(etaSec, t) : ""
  if (e) parts.push(e)
  if (size > 0) parts.push(Model.bytes(size, fmt))
  return {
    id: id, title: Model.clip(name, 100),
    subtitle: Model.clip(error || parts.join(" · "), 120),
    meta: paused ? t("state.paused") : pct >= 1 ? t("torrent.seeding") : "",
    warn: !!error, progress: pct < 1 ? pct : -1, data: data,
    actions: [paused ? { id: "resume", icon: ICON.play, tooltip: t("torrent.resume") } : { id: "pause", icon: ICON.pause, tooltip: t("torrent.pause") }]
  }
}

function torrentStats(vm, down, up, downloading, seeding, total, alt, t, fmt) {
  vm.stats.push(stat("↓ " + t("torrent.down"), Model.bytes(down, fmt)))
  vm.stats.push(stat("↑ " + t("torrent.up"), Model.bytes(up, fmt)))
  vm.stats.push(stat(t("torrent.downloading"), fmt(downloading, 0)))
  vm.stats.push(stat(t("torrent.seedingCount"), fmt(seeding, 0)))
  vm.stats.push(stat(t("torrent.total"), fmt(total, 0)))
  vm.stats.push(stat(t("torrent.altSpeed"), t(alt ? "state.on" : "state.off")))
}

function parseQbittorrent(results, t, fmt) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var version = String((results.version && results.version.body) || "").trim()
  vm.version = Model.clip(version.replace(/^v/, ""), 24)
  var api = String((results.webapi && results.webapi.body) || "").trim().split(".").map(Number)
  var v5 = api[0] > 2 || (api[0] === 2 && api[1] >= 11)
  var tr = json(results.transfer) || {}
  var alt = String((results.altspeed && results.altspeed.body) || "").trim() === "1"
  var torrents = arr(json(results.torrents))
  var downloading = 0, seeding = 0
  torrents.forEach(function(x) { if (QB_ACTIVE[x.state]) downloading++; else if (Model.num(x.progress) >= 1 && !QB_PAUSED[x.state]) seeding++ })
  torrentStats(vm, tr.dl_info_speed, tr.up_info_speed, downloading, seeding, torrents.length, alt, t, fmt)
  if (tr.connection_status === "disconnected") vm.alerts.push({ level: "error", text: t("torrent.disconnected") })
  else if (tr.connection_status === "firewalled") vm.alerts.push({ level: "warning", text: t("torrent.firewalled") })
  var rank = function(x) { return QB_ACTIVE[x.state] ? 0 : x.state === "error" || x.state === "missingFiles" ? 0 : QB_PAUSED[x.state] && Model.num(x.progress) < 1 ? 1 : 2 }
  torrents.sort(function(x, y) { return rank(x) - rank(y) || Model.num(y.added_on) - Model.num(x.added_on) })
  vm.sections.push({ title: t("torrent.title"), empty: t("torrent.none"), items: torrents.slice(0, 20).map(function(x) {
    var err = x.state === "error" || x.state === "missingFiles" ? t("torrent.error") : ""
    return torrentItem("t:" + x.hash, x.name, Model.num(x.progress), Model.num(x.dlspeed), Model.num(x.upspeed), x.eta, Model.num(x.size),
                       !!QB_PAUSED[x.state], err, { hash: String(x.hash || ""), v5: v5 }, t, fmt)
  }) })
  vm.actions.push({ id: "pauseAll", label: t("torrent.pauseAll"), icon: ICON.pause, data: { v5: v5 } })
  vm.actions.push({ id: "resumeAll", label: t("torrent.resumeAll"), icon: ICON.play, data: { v5: v5 } })
  vm.actions.push({ id: "altspeed", label: t(alt ? "torrent.altOff" : "torrent.altOn"), icon: ICON.speed })
  return vm
}

function rpc(res) {
  var j = json(res)
  return j && j.result === "success" ? (j.arguments || {}) : null
}

function parseTransmission(results, t, fmt) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var session = rpc(results.session) || {}
  var stats = rpc(results.stats) || {}
  vm.version = Model.clip(String(session.version || "").split(" ")[0], 24)
  var alt = !!session["alt-speed-enabled"]
  var torrents = arr((rpc(results.torrents) || {}).torrents)
  var downloading = torrents.filter(function(x) { return x.status === 4 || x.status === 3 }).length
  var seeding = torrents.filter(function(x) { return x.status === 6 }).length
  torrentStats(vm, stats.downloadSpeed, stats.uploadSpeed, downloading, seeding, torrents.length, alt, t, fmt)
  var rank = function(x) { return x.error ? 0 : x.status === 4 || x.status === 3 ? 0 : x.status === 0 && x.percentDone < 1 ? 1 : 2 }
  torrents.sort(function(x, y) { return rank(x) - rank(y) || Model.num(y.addedDate) - Model.num(x.addedDate) })
  vm.sections.push({ title: t("torrent.title"), empty: t("torrent.none"), items: torrents.slice(0, 20).map(function(x) {
    return torrentItem("t:" + x.id, x.name, Model.num(x.percentDone), Model.num(x.rateDownload), Model.num(x.rateUpload), x.eta, Model.num(x.totalSize),
                       x.status === 0, x.error ? Model.clip(x.errorString || t("torrent.error"), 100) : "", { id: Model.num(x.id) }, t, fmt)
  }) })
  vm.actions.push({ id: "pauseAll", label: t("torrent.pauseAll"), icon: ICON.pause })
  vm.actions.push({ id: "resumeAll", label: t("torrent.resumeAll"), icon: ICON.play })
  vm.actions.push({ id: "altspeed", label: t(alt ? "torrent.altOff" : "torrent.altOn"), icon: ICON.speed, data: { alt: alt } })
  return vm
}

function blockingActions(vm, enabled, t) {
  if (enabled) {
    vm.actions.push({ id: "disable5", label: t("dns.disable5"), icon: ICON.shieldOff })
    vm.actions.push({ id: "disable", label: t("dns.disable"), icon: ICON.shieldOff })
  } else {
    vm.actions.push({ id: "enable", label: t("dns.enable"), icon: ICON.shield })
  }
}

function countList(title, rows, t, fmt) {
  return { title: title, items: rows.slice(0, 8).map(function(r, i) {
    return { id: "r" + i, title: Model.clip(r[0], 90), subtitle: r[2] ? Model.clip(r[2], 60) : "", meta: fmt(Model.num(r[1]), 0), progress: -1, actions: [] }
  }) }
}

function parsePihole(results, t, fmt) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var summary = json(results.summary)
  if (!summary || !summary.queries) return Object.assign(base(), { state: "error", error: t("pihole.v6") })
  var ver = ((json(results.version) || {}).version || {}).core || {}
  vm.version = Model.clip(((ver.local || {}).version || "").replace(/^v/, ""), 24)
  var blocking = json(results.blocking) || {}
  var enabled = blocking.blocking !== "disabled"
  var q = summary.queries || {}
  vm.stats.push(stat(t("dns.protection"), enabled ? t("dns.on") : t("dns.off") + (blocking.timer > 0 ? " · " + Model.duration(blocking.timer) : "")))
  vm.stats.push(stat(t("dns.queries"), fmt(Model.num(q.total), 0)))
  vm.stats.push(stat(t("dns.blocked"), fmt(Model.num(q.blocked), 0)))
  vm.stats.push(stat(t("dns.percent"), fmt(Model.num(q.percent_blocked), 1) + " %"))
  vm.stats.push(stat(t("dns.listed"), fmt(Model.num((summary.gravity || {}).domains_being_blocked), 0)))
  vm.stats.push(stat(t("dns.clients"), fmt(Model.num((summary.clients || {}).active), 0)))
  if (!enabled) vm.alerts.push({ level: "warning", text: t("dns.offAlert") })
  var blocked = arr((json(results.blocked) || {}).domains).map(function(d) { return [d.domain, d.count] })
  if (blocked.length) vm.sections.push(countList(t("dns.topBlocked"), blocked, t, fmt))
  var clients = arr((json(results.clients) || {}).clients).map(function(c) { return [c.name || c.ip, c.count, c.name ? c.ip : ""] })
  if (clients.length) vm.sections.push(countList(t("dns.topClients"), clients, t, fmt))
  blockingActions(vm, enabled, t)
  return vm
}

function pairs(list) {
  // AdGuard: [{ "example.com": 12 }, …] -> [["example.com", 12], …]
  return arr(list).map(function(o) { var k = o ? Object.keys(o)[0] : ""; return [k, k ? o[k] : 0] }).filter(function(p) { return p[0] })
}

function parseAdguard(results, t, fmt) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var status = json(results.status) || {}
  var stats = json(results.stats) || {}
  vm.version = Model.clip(String(status.version || "").replace(/^v/, ""), 24)
  var enabled = status.protection_enabled !== false
  var total = Model.num(stats.num_dns_queries), blocked = Model.num(stats.num_blocked_filtering)
  var left = Model.num(status.protection_disabled_duration) / 1000
  vm.stats.push(stat(t("dns.protection"), enabled ? t("dns.on") : t("dns.off") + (left > 0 ? " · " + Model.duration(left) : "")))
  vm.stats.push(stat(t("dns.queries"), fmt(total, 0)))
  vm.stats.push(stat(t("dns.blocked"), fmt(blocked, 0)))
  vm.stats.push(stat(t("dns.percent"), fmt(total > 0 ? blocked / total * 100 : 0, 1) + " %"))
  vm.stats.push(stat(t("dns.avgTime"), fmt(Model.num(stats.avg_processing_time) * 1000, 0) + " ms"))
  if (!enabled) vm.alerts.push({ level: "warning", text: t("dns.offAlert") })
  var topBlocked = pairs(stats.top_blocked_domains)
  if (topBlocked.length) vm.sections.push(countList(t("dns.topBlocked"), topBlocked, t, fmt))
  var topClients = pairs(stats.top_clients)
  if (topClients.length) vm.sections.push(countList(t("dns.topClients"), topClients, t, fmt))
  blockingActions(vm, enabled, t)
  return vm
}

function parse(service, results, t, fmt, filter) {
  switch (service.id) {
  case "jellyfin": return parseJellyfin(results, t, fmt, service)
  case "homeassistant": return parseHomeAssistant(results, t, fmt, Object.assign({}, service.options, { filter: filter || "" }))
  case "prowlarr": return parseProwlarr(results, t, fmt)
  case "navidrome": return parseNavidrome(results, t, fmt)
  case "sonarr":
  case "radarr": return parseArr(results, t, fmt, service)
  case "qbittorrent": return parseQbittorrent(results, t, fmt)
  case "transmission": return parseTransmission(results, t, fmt)
  case "pihole": return parsePihole(results, t, fmt)
  case "adguard": return parseAdguard(results, t, fmt)
  }
  return Object.assign(base(), { state: "error", error: "unknown service" })
}

// ---------- background probes (watcher) ----------
// Cheap checks run every few minutes for every service with credentials:
// is it reachable, does it report problems, does it offer an update.

function probePlan(service) {
  switch (service.id) {
  case "jellyfin": return [{ key: "info", path: "/System/Info" }]
  case "homeassistant": return [{ key: "states", path: "/api/states" }]
  case "prowlarr": return [
    { key: "health", path: "/api/v1/health" },
    { key: "istatus", path: "/api/v1/indexerstatus" },
    { key: "status", path: "/api/v1/system/status" }
  ]
  case "navidrome": return [{ key: "ping", path: "/rest/ping.view" }]
  case "sonarr":
  case "radarr": return [
    { key: "health", path: "/api/v3/health" },
    { key: "status", path: "/api/v3/system/status" }
  ]
  case "qbittorrent": return [{ key: "version", path: "/api/v2/app/version" }]
  case "transmission": return [plan(service)[0]]
  case "pihole": return [{ key: "version", path: "/api/info/version" }, { key: "blocking", path: "/api/dns/blocking" }]
  case "adguard": return [{ key: "status", path: "/control/status" }]
  }
  return []
}

// -> { name, skipped, down, error, alerts: [{ key, level, title, body }], updates: [{ key, name, current, latest, url }] }
function parseProbe(service, results, t) {
  var out = { name: service.name, skipped: false, down: false, error: "", alerts: [], updates: [] }
  var fail = failure(results, t)
  if (fail) {
    if (fail.state === "auth") out.skipped = true
    else { out.down = true; out.error = fail.error }
    return out
  }
  switch (service.id) {
  case "jellyfin": {
    var info = json(results.info) || {}
    if (info.HasUpdateAvailable)
      out.updates.push({ key: "server", name: "Jellyfin", current: Model.clip(info.Version, 24), latest: "", url: service.url })
    if (info.HasPendingRestart)
      out.alerts.push({ key: "restart", level: "info", title: t("alert.jellyfinRestart"), body: "" })
    break
  }
  case "homeassistant": {
    var states = arr(json(results.states))
    for (var i = 0; i < states.length && out.updates.length < 30; i++) {
      var s = states[i]
      if (!s || typeof s.entity_id !== "string" || s.entity_id.indexOf("update.") !== 0 || s.state !== "on") continue
      var a = s.attributes || {}
      out.updates.push({ key: Model.clip(s.entity_id, 80), name: Model.clip(a.title || a.friendly_name || s.entity_id, 60),
                         current: Model.clip(a.installed_version || "", 30), latest: Model.clip(a.latest_version || "", 30),
                         url: service.url + "/config/updates" })
    }
    break
  }
  case "prowlarr": {
    var health = arr(json(results.health))
    for (var h = 0; h < health.length && h < 10; h++) {
      var item = health[h] || {}
      if (item.source === "UpdateCheck") {
        var m = /v?(\d+(?:\.\d+)+)/.exec(String(item.message || ""))
        out.updates.push({ key: "server", name: "Prowlarr", current: Model.clip((json(results.status) || {}).version || "", 24),
                           latest: m ? m[1] : "", url: service.url + "/system/updates" })
      } else if (item.type === "error") {
        out.alerts.push({ key: "health|" + Model.clip(item.source, 40), level: "error", title: t("alert.prowlarrHealth"),
                          body: Model.clip(item.message, 200) })
      }
    }
    var now = Date.now()
    var failing = arr(json(results.istatus)).filter(function(x) { return x && x.disabledTill && Date.parse(x.disabledTill) > now })
    if (failing.length > 0)
      out.alerts.push({ key: "indexers", level: "warning", title: t("alert.indexersFailing").arg(failing.length), body: "" })
    break
  }
  case "navidrome": {
    var ping = subsonic(results.ping)
    if (!ping) { out.down = true; out.error = t("service.unreachable") }
    else if (ping.status !== "ok") out.skipped = true
    break
  }
  case "sonarr":
  case "radarr": {
    var ah = arr(json(results.health))
    for (var x = 0; x < ah.length && x < 10; x++) {
      var it2 = ah[x] || {}
      if (it2.source === "UpdateCheck") {
        var mv = /v?(\d+(?:\.\d+)+)/.exec(String(it2.message || ""))
        out.updates.push({ key: "server", name: service.name, current: Model.clip((json(results.status) || {}).version || "", 24),
                           latest: mv ? mv[1] : "", url: service.url + "/system/updates" })
      } else if (it2.type === "error") {
        out.alerts.push({ key: "health|" + Model.clip(it2.source, 40), level: "error", title: t("alert.arrHealth").arg(service.name),
                          body: Model.clip(it2.message, 200) })
      }
    }
    break
  }
  case "pihole": {
    var core = ((json(results.version) || {}).version || {}).core || {}
    var loc = (core.local || {}).version, rem = (core.remote || {}).version
    if (loc && rem && loc !== rem)
      out.updates.push({ key: "server", name: "Pi-hole", current: Model.clip(loc, 24), latest: Model.clip(rem, 24), url: service.url + "/admin" })
    if ((json(results.blocking) || {}).blocking === "disabled")
      out.alerts.push({ key: "blocking", level: "warning", title: t("alert.dnsOff").arg("Pi-hole"), body: "" })
    break
  }
  case "adguard": {
    if ((json(results.status) || {}).protection_enabled === false)
      out.alerts.push({ key: "blocking", level: "warning", title: t("alert.dnsOff").arg("AdGuard Home"), body: "" })
    break
  }
  }
  return out
}
