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

var ICON = {
  play: "󰐊", scan: "󰑐", test: "󰸞", web: "󰖟",
  grab: "󰇚", toggle: "󰐥", run: "󰐊", open: "󰏌"
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
    help: "help.homeassistant"
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
  }
}

var ORDER = ["homeassistant", "jellyfin", "navidrome", "prowlarr"]

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
function urlFromPorts(ports, defaultPort, host) {
  var best = null
  var parts = String(ports || "").split(",")
  for (var i = 0; i < parts.length; i++) {
    var m = /^\s*(.*):(\d+)->(\d+)\/tcp/.exec(parts[i])
    if (!m) continue
    var entry = { ip: m[1], hostPort: m[2], containerPort: parseInt(m[3], 10) }
    if (entry.containerPort === defaultPort) { best = entry; break }
    if (!best) best = entry
  }
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

function plan(service) {
  switch (service.id) {
  case "jellyfin": return [
    { key: "info", path: "/System/Info" },
    { key: "sessions", path: "/Sessions?activeWithinSeconds=960" },
    { key: "counts", path: "/Items/Counts" },
    { key: "tasks", path: "/ScheduledTasks?isHidden=false" }
  ]
  case "homeassistant": return [
    { key: "config", path: "/api/config" },
    { key: "states", path: "/api/states" }
  ]
  case "prowlarr": return [
    { key: "status", path: "/api/v1/system/status" },
    { key: "health", path: "/api/v1/health" },
    { key: "indexers", path: "/api/v1/indexer" },
    { key: "istatus", path: "/api/v1/indexerstatus" }
  ]
  case "navidrome": return [
    { key: "ping", path: "/rest/ping.view" },
    { key: "scan", path: "/rest/getScanStatus.view" },
    { key: "playing", path: "/rest/getNowPlaying.view" },
    { key: "newest", path: "/rest/getAlbumList2.view?type=newest&size=8" }
  ]
  }
  return []
}

// Service- or item-level action -> one request, or null.
function actionRequest(service, actionId, item) {
  var d = item && item.data ? item.data : {}
  switch (service.id + ":" + actionId) {
  case "jellyfin:scan": return { method: "POST", path: "/Library/Refresh" }
  case "navidrome:scan": return { method: "GET", path: "/rest/startScan.view" }
  case "prowlarr:testall": return { method: "POST", path: "/api/v1/indexer/testall" }
  case "prowlarr:grab":
    if (!d.guid || !(d.indexerId > 0)) return null
    return { method: "POST", path: "/api/v1/search", body: JSON.stringify({ guid: d.guid, indexerId: d.indexerId }) }
  case "homeassistant:toggle": {
    if (!/^[a-z_]+\.[A-Za-z0-9_]+$/.test(d.entityId || "")) return null
    var domain = d.entityId.split(".")[0]
    var svc = HA_SERVICE[domain]
    if (!svc) return null
    return { method: "POST", path: "/api/services/" + svc[0] + "/" + svc[1], body: JSON.stringify({ entity_id: d.entityId }) }
  }
  }
  return null
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

function parseJellyfin(results, t, fmt) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var info = json(results.info) || {}
  vm.version = Model.clip(info.Version || "", 24)
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
    playing.push({
      id: "session:" + Model.clip(ss.Id, 64),
      title: Model.clip(title, 90),
      subtitle: Model.clip([ss.UserName, ss.DeviceName || ss.Client].filter(Boolean).join(" · "), 90),
      meta: ps.IsPaused ? t("state.paused") : (ps.PlayMethod === "Transcode" ? t("jellyfin.transcoding") : t("state.playing")),
      progress: run > 0 ? Math.max(0, Math.min(1, ticks(ps.PositionTicks) / run)) : -1,
      actions: []
    })
  }
  vm.stats.push(stat(t("jellyfin.streams"), fmt(playing.length, 0)))
  vm.sections.push({ title: t("section.nowPlaying"), empty: t("jellyfin.idle"), items: playing })
  var tasks = arr(json(results.tasks)).filter(function(x) { return x && x.State === "Running" })
  if (tasks.length > 0) {
    vm.sections.push({ title: t("section.tasks"), items: tasks.slice(0, 8).map(function(x) {
      return { id: "task:" + Model.clip(x.Id, 64), title: Model.clip(x.Name, 80), subtitle: Model.clip(x.Category || "", 60),
               meta: fmt(Model.num(x.CurrentProgressPercentage), 0) + " %", progress: Model.num(x.CurrentProgressPercentage) / 100, actions: [] }
    }) })
  }
  vm.actions.push({ id: "scan", label: t("action.scanLibrary"), icon: ICON.scan })
  return vm
}

var HA_SERVICE = {
  light: ["light", "toggle"], switch: ["switch", "toggle"], fan: ["fan", "toggle"],
  input_boolean: ["input_boolean", "toggle"], automation: ["automation", "toggle"],
  scene: ["scene", "turn_on"], script: ["script", "turn_on"],
  button: ["button", "press"], input_button: ["input_button", "press"]
}
var HA_DEFAULT_DOMAINS = ["light", "switch", "fan", "input_boolean", "scene", "script"]

function parseHomeAssistant(results, t, fmt, options) {
  var fail = failure(results, t)
  if (fail) return Object.assign(base(), fail)
  var vm = base()
  var cfg = json(results.config) || {}
  vm.version = Model.clip(cfg.version || "", 24)
  var states = arr(json(results.states))
  var byId = {}
  var unavailable = 0
  for (var i = 0; i < states.length; i++) {
    var st = states[i]
    if (!st || typeof st.entity_id !== "string") continue
    byId[st.entity_id] = st
    if (st.state === "unavailable") unavailable++
  }
  if (cfg.location_name) vm.stats.push(stat(t("ha.home"), Model.clip(cfg.location_name, 40)))
  vm.stats.push(stat(t("ha.entities"), fmt(states.length, 0)))
  if (unavailable > 0) vm.stats.push(stat(t("ha.unavailable"), fmt(unavailable, 0)))

  var wanted = arr(options && options.entities).filter(function(e) { return typeof e === "string" }).slice(0, 60)
  var picked = []
  if (wanted.length > 0) {
    for (var w = 0; w < wanted.length; w++) if (byId[wanted[w]]) picked.push(byId[wanted[w]])
  } else {
    for (var d = 0; d < HA_DEFAULT_DOMAINS.length; d++)
      for (var j = 0; j < states.length; j++) {
        var s2 = states[j]
        if (s2 && s2.entity_id && s2.entity_id.split(".")[0] === HA_DEFAULT_DOMAINS[d] && s2.state !== "unavailable") picked.push(s2)
      }
    picked = picked.slice(0, 40)
  }

  var groups = {}
  var order = []
  for (var p = 0; p < picked.length; p++) {
    var e = picked[p]
    var domain = e.entity_id.split(".")[0]
    var attrs = e.attributes || {}
    var svc = HA_SERVICE[domain]
    var isToggle = svc && svc[1] === "toggle"
    var unit = attrs.unit_of_measurement ? " " + attrs.unit_of_measurement : ""
    var item = {
      id: e.entity_id,
      title: Model.clip(attrs.friendly_name || e.entity_id, 70),
      subtitle: Model.clip(e.entity_id, 70),
      meta: isToggle ? t(e.state === "on" ? "state.on" : e.state === "off" ? "state.off" : "state.unknown") : Model.clip(String(e.state) + unit, 40),
      progress: -1,
      on: isToggle ? e.state === "on" : undefined,
      activate: svc ? "toggle" : "",
      data: { entityId: e.entity_id },
      actions: svc ? [{ id: "toggle", icon: isToggle ? ICON.toggle : ICON.run, tooltip: t(isToggle ? "ha.toggle" : "ha.run") }] : []
    }
    var g = t("ha.domain." + domain) !== "ha.domain." + domain ? t("ha.domain." + domain) : domain
    if (!groups[g]) { groups[g] = []; order.push(g) }
    groups[g].push(item)
  }
  for (var o = 0; o < order.length; o++) vm.sections.push({ title: order[o], items: groups[order[o]] })
  if (picked.length === 0) vm.sections.push({ title: t("ha.entitiesTitle"), empty: t("ha.noEntities"), items: [] })
  return vm
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
  var failing = arr(json(results.istatus)).filter(function(x) { return x && x.disabledTill && Date.parse(x.disabledTill) > now })
  vm.stats.push(stat(t("prowlarr.indexers"), fmt(enabled, 0) + " / " + fmt(indexers.length, 0)))
  vm.stats.push(stat(t("prowlarr.failing"), fmt(failing.length, 0)))
  var health = arr(json(results.health))
  for (var h = 0; h < health.length && h < 8; h++)
    vm.alerts.push({ level: health[h].type === "error" ? "error" : "warning", text: Model.clip(health[h].message, 220) })
  if (failing.length > 0) {
    vm.sections.push({ title: t("prowlarr.failingTitle"), items: failing.slice(0, 12).map(function(x) {
      return { id: "idx:" + x.indexerId, title: Model.clip(names[x.indexerId] || ("#" + x.indexerId), 60),
               subtitle: t("prowlarr.disabledUntil").arg(new Date(Date.parse(x.disabledTill)).toLocaleTimeString()),
               meta: "", progress: -1, actions: [] }
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
    if (r.publishDate) parts.push(new Date(Date.parse(r.publishDate)).toLocaleDateString())
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
  vm.actions.push({ id: "scan", label: t("action.scanLibrary"), icon: ICON.scan })
  return vm
}

function parse(service, results, t, fmt) {
  switch (service.id) {
  case "jellyfin": return parseJellyfin(results, t, fmt)
  case "homeassistant": return parseHomeAssistant(results, t, fmt, service.options)
  case "prowlarr": return parseProwlarr(results, t, fmt)
  case "navidrome": return parseNavidrome(results, t, fmt)
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
  }
  return out
}
