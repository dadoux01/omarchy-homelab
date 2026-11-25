.pragma library
.import "Model.js" as Model

// Alert rules for the background watcher. Pure functions: given what the
// watcher last saw for a host, return the alerts active right now. Each alert
// has a stable id so the watcher can tell new ones (notify) from ones it has
// already announced.
//
//   { id, hostKey, host, level: "error" | "warning" | "info", kind, title, body, tab }
//
// `t` is the plugin's translate function.

function updatesId(hostKey, kind, key) { return hostKey + "|upd|" + kind + "|" + key }

// host: parsed host; s: { failures, metrics, docker, running, expectedStops, services }
function evaluate(host, s, th, t) {
  var out = []
  var hk = host.key
  function add(level, kind, key, title, body, tab) {
    out.push({ id: hk + "|" + kind + (key ? "|" + key : ""), hostKey: hk, host: host.name,
               level: level, kind: kind, title: title, body: body || "", tab: tab || "monitoring" })
  }

  // Two failed rounds in a row before calling a host down, so a single
  // dropped packet does not page anyone.
  if (s.failures >= 2) {
    add("error", "down", "", t("alert.hostDown").arg(host.name), Model.clip(s.lastError || "", 160), "monitoring")
    return out
  }

  var m = s.metrics
  if (m) {
    for (var i = 0; i < m.disks.length; i++) {
      var d = m.disks[i]
      var pct = Model.percent(d.used, d.total)
      if (pct >= th.disk)
        add(pct >= Math.max(th.disk, 97) ? "error" : "warning", "disk", d.mount,
            t("alert.diskFull").arg(d.mount).arg(Math.round(pct)),
            t("alert.diskFree").arg(Model.bytes(d.total - d.used)), "monitoring")
    }
    if (m.mem && Model.percent(m.mem.used, m.mem.total) >= th.memory)
      add("warning", "memory", "", t("alert.memoryHigh").arg(Math.round(Model.percent(m.mem.used, m.mem.total))), "", "monitoring")
    for (var j = 0; j < m.temps.length; j++)
      if (m.temps[j].value >= th.temperature)
        add(m.temps[j].value >= th.temperature + 10 ? "error" : "warning", "temp", m.temps[j].name,
            t("alert.tempHigh").arg(m.temps[j].name).arg(Math.round(m.temps[j].value)), "", "monitoring")
    for (var g = 0; g < m.gpus.length; g++)
      if (m.gpus[g].temp >= th.temperature)
        add("warning", "temp", "gpu" + g, t("alert.tempHigh").arg("GPU").arg(Math.round(m.gpus[g].temp)), "", "monitoring")
  }

  var dk = s.docker
  if (dk && dk.error === "") {
    var was = s.running || {}
    var expected = s.expectedStops || {}
    for (var c = 0; c < dk.containers.length; c++) {
      var ct = dk.containers[c]
      if (ct.state === "restarting")
        add("error", "ctr", ct.name + "|restarting", t("alert.restarting").arg(ct.name), ct.status, "docker")
      else if (/\(unhealthy\)/.test(ct.status))
        add("warning", "ctr", ct.name + "|unhealthy", t("alert.unhealthy").arg(ct.name), ct.image, "docker")
      else if (ct.state !== "running" && was[ct.name] && !expected[ct.name])
        add("error", "ctr", ct.name + "|stopped", t("alert.stopped").arg(ct.name), ct.status, "docker")
    }
  }

  var svc = s.services || {}
  for (var id in svc) {
    var st = svc[id]
    if (st.down) add("warning", "svc", id + "|down", t("alert.serviceDown").arg(st.name), Model.clip(st.error || "", 160), "services")
    for (var a = 0; a < (st.alerts || []).length; a++)
      add(st.alerts[a].level, "svc", id + "|" + st.alerts[a].key, st.alerts[a].title, st.alerts[a].body, "services")
  }

  if (s.updates && s.updates.reboot)
    add("warning", "reboot", "", t("alert.reboot").arg(host.name), "", "alerts")

  return out
}

// Updates found for a host -> flat list for the panel and notifications.
// u: { images: [{ container, image, digest }], os: { manager, count, security, packages, listsAge }, reboot }
// services: { id: { name, updates: [{ key, name, current, latest, url }] } }
function updateItems(host, u, services) {
  var items = []
  var hk = host.key
  if (u && u.os && u.os.count > 0)
    items.push({ id: updatesId(hk, "os", u.os.count + ":" + u.os.security), hostKey: hk, kind: "os",
                 count: u.os.count, security: u.os.security, manager: u.os.manager,
                 packages: u.os.packages || [], listsAge: u.os.listsAge })
  var imgs = u && u.images ? u.images : []
  for (var i = 0; i < imgs.length; i++)
    items.push({ id: updatesId(hk, "img", imgs[i].container + "@" + imgs[i].digest), hostKey: hk, kind: "image",
                 container: imgs[i].container, image: imgs[i].image, pulled: imgs[i].digest.indexOf("local:") === 0 })
  for (var sid in services || {}) {
    var ups = services[sid].updates || []
    for (var k = 0; k < ups.length; k++)
      items.push({ id: updatesId(hk, "svc", sid + ":" + ups[k].key + ":" + ups[k].latest), hostKey: hk, kind: "service",
                   service: sid, name: ups[k].name, current: ups[k].current, latest: ups[k].latest, url: ups[k].url || "" })
  }
  return items
}

function parseUpdates(text) {
  var u = { images: [], imageErrors: 0, rateLimited: 0, imageCheck: true, os: null, reboot: false, sudo: false, busy: false, checkedAt: Date.now() }
  var seen = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length && i < 800; i++) {
    var f = lines[i].split("\t")
    switch (f[0]) {
    case "img":
      if (!Model.validContainer(f[1]) || seen[f[1]] || u.images.length >= 200) break
      seen[f[1]] = true
      u.images.push({ container: f[1], image: Model.clip(f[2], 160), digest: Model.clip(f[3], 90) })
      break
    case "imgerr": u.imageErrors++; if (f[2] === "ratelimit") u.rateLimited++; break
    case "noimgcheck": u.imageCheck = false; break
    case "os": {
      // One record per package manager (distribution's own, Flatpak, Snap);
      // the panel shows them as one list with per-manager details.
      var mgr = { manager: Model.clip(f[1], 12), count: Math.round(Model.num(f[2])), security: Math.round(Model.num(f[3])),
                  listsAge: Model.num(f[4]), fresh: f[5] === "1" }
      if (!u.os) u.os = { manager: "", count: 0, security: 0, listsAge: -1, fresh: true, managers: [], packages: [] }
      u.os.managers.push(mgr)
      u.os.manager = u.os.managers.map(function(m) { return m.manager }).join(" + ")
      u.os.count += mgr.count
      u.os.security += mgr.security
      if (!mgr.fresh) { u.os.fresh = false; u.os.listsAge = Math.max(u.os.listsAge, mgr.listsAge) }
      break
    }
    case "pkg":
      if (u.os && u.os.packages.length < 300)
        u.os.packages.push({ name: Model.clip(f[1], 80), version: Model.clip(f[2], 60), current: Model.clip(f[3] || "", 60),
                             security: f[4] === "1", source: Model.clip(f[5] || "", 12) })
      break
    case "busy": u.busy = true; break
    case "sudo": u.sudo = true; break
    case "reboot": u.reboot = true; break
    }
  }
  u.images.sort(function(a, b) { return a.container.localeCompare(b.container) })
  // Security fixes first, then alphabetical.
  if (u.os) u.os.packages.sort(function(a, b) { return (b.security - a.security) || a.name.localeCompare(b.name) })
  return u
}

// Notification body text must not be read as markup by the daemon.
function escapeMarkup(s) {
  return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}
