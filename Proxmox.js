.pragma library
.import "Model.js" as Model

// Proxmox VE support. `bin/homelab pve-read` prints sections
//   == resources   /cluster/resources (nodes, qemu, lxc, storage)
//   == tasks       /cluster/tasks (recent tasks of the whole cluster)
//   == version     /version
// each followed by one JSON line, or "error<TAB>reason" when it could not
// read anything (noaccess | auth | unreachable | notpve).

function parse(text) {
  var out = { error: "", via: "", version: "", nodes: [], guests: [], storages: [], failedTasks: [], checkedAt: Date.now() }
  var sections = {}
  var current = ""
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var e = /^error\t([a-z]+)/.exec(line)
    if (e) { out.error = e[1]; return out }
    var v = /^via\t([a-z]+)/.exec(line)
    if (v) { out.via = v[1]; continue }
    var h = /^== ([a-z]+)$/.exec(line)
    if (h) { current = h[1]; continue }
    if (current && line.trim() !== "" && sections[current] === undefined) {
      try { sections[current] = JSON.parse(line) } catch (err) { sections[current] = null }
    }
  }
  if (sections.resources === undefined) { out.error = "unreachable"; return out }

  var version = sections.version || {}
  out.version = Model.clip(version.version || "", 24)

  var resources = Array.isArray(sections.resources) ? sections.resources.slice(0, 2000) : []
  for (var r = 0; r < resources.length; r++) {
    var x = resources[r] || {}
    switch (x.type) {
    case "node":
      out.nodes.push({
        name: Model.clip(x.node, 64), online: x.status === "online",
        cpu: Model.num(x.cpu), maxcpu: Model.num(x.maxcpu),
        mem: Model.num(x.mem), maxmem: Model.num(x.maxmem),
        disk: Model.num(x.disk), maxdisk: Model.num(x.maxdisk), uptime: Model.num(x.uptime)
      })
      break
    case "qemu":
    case "lxc":
      if (x.template === 1 || x.template === "1") break
      out.guests.push({
        type: x.type, vmid: Math.round(Model.num(x.vmid)), name: Model.clip(x.name || ("#" + x.vmid), 64),
        node: Model.clip(x.node, 64), status: Model.clip(x.status, 16), running: x.status === "running",
        cpu: Model.num(x.cpu), maxcpu: Model.num(x.maxcpu), mem: Model.num(x.mem), maxmem: Model.num(x.maxmem),
        disk: Model.num(x.disk), maxdisk: Model.num(x.maxdisk), uptime: Model.num(x.uptime),
        tags: String(x.tags || "").split(/[;, ]+/).filter(Boolean).slice(0, 6).map(function(t) { return Model.clip(t, 24) }),
        lock: Model.clip(x.lock || "", 16), hastate: Model.clip(x.hastate || "", 16)
      })
      break
    case "storage":
      if (x.status !== "available" || !(Model.num(x.maxdisk) > 0)) break
      // A shared storage appears once per node; keep the first.
      if (x.shared && out.storages.some(function(s) { return s.storage === x.storage })) break
      out.storages.push({
        storage: Model.clip(x.storage, 48), node: Model.clip(x.node, 64), shared: !!x.shared,
        kind: Model.clip(x.plugintype || "", 16), used: Model.num(x.disk), total: Model.num(x.maxdisk)
      })
      break
    }
  }
  out.guests.sort(function(a, b) { return a.vmid - b.vmid })
  out.nodes.sort(function(a, b) { return a.name.localeCompare(b.name) })
  out.storages.sort(function(a, b) { return a.storage.localeCompare(b.storage) || a.node.localeCompare(b.node) })

  // Failed tasks of the last 24 hours (backups first), newest first.
  var since = Date.now() / 1000 - 86400
  var tasks = Array.isArray(sections.tasks) ? sections.tasks.slice(0, 500) : []
  for (var t = 0; t < tasks.length; t++) {
    var k = tasks[t] || {}
    if (!k.endtime || k.endtime < since || !k.status || k.status === "OK" || /^WARNINGS/.test(k.status)) continue
    out.failedTasks.push({
      upid: Model.clip(k.upid, 200), type: Model.clip(k.type, 24), id: Model.clip(k.id || "", 24),
      node: Model.clip(k.node, 64), user: Model.clip(k.user || "", 48), status: Model.clip(k.status, 200),
      endtime: Model.num(k.endtime) * 1000
    })
  }
  out.failedTasks.sort(function(a, b) { return (b.type === "vzdump") - (a.type === "vzdump") || b.endtime - a.endtime })
  out.failedTasks = out.failedTasks.slice(0, 20)
  return out
}

// Base URL of the Proxmox web interface and API for a host.
function baseUrl(host) {
  if (host.proxmox && host.proxmox.url) return host.proxmox.url
  var t = String(host.address || host.target || "")
  var at = t.lastIndexOf("@")
  var addr = at >= 0 ? t.slice(at + 1) : t
  return "https://" + (addr.indexOf(":") >= 0 ? "[" + addr + "]" : addr) + ":8006"
}

function insecure(host) {
  return !(host.proxmox && host.proxmox.insecure === false)
}

// Browser console (noVNC for VMs, xterm.js for containers).
function consoleUrl(host, guest) {
  var q = guest.type === "lxc"
    ? "console=lxc&xtermjs=1"
    : "console=kvm&novnc=1&resize=off"
  return baseUrl(host) + "/?" + q + "&vmid=" + guest.vmid + "&vmname=" + encodeURIComponent(guest.name) + "&node=" + encodeURIComponent(guest.node)
}

function filterGuests(list, query, state, kind) {
  var q = String(query || "").trim().toLowerCase()
  return (list || []).filter(function(g) {
    if (state === "running" && !g.running) return false
    if (state === "stopped" && g.running) return false
    if (kind !== "all" && g.type !== kind) return false
    if (q === "") return true
    return g.name.toLowerCase().indexOf(q) >= 0 || String(g.vmid).indexOf(q) === 0
        || g.node.toLowerCase().indexOf(q) >= 0 || g.tags.some(function(t) { return t.toLowerCase().indexOf(q) >= 0 })
  })
}

// Alert rules. `known` holds guests seen running ("node/type/vmid" -> true),
// `expected` those the user stopped from the panel.
function alerts(host, pve, known, expected, th, t) {
  var out = []
  if (!pve || pve.error !== "") return out
  var hk = host.key
  function add(level, key, title, body, tab) {
    out.push({ id: hk + "|pve|" + key, hostKey: hk, host: host.name, level: level, kind: "pve",
               title: title, body: body || "", tab: tab || "proxmox" })
  }
  for (var n = 0; n < pve.nodes.length; n++)
    if (!pve.nodes[n].online) add("error", "node|" + pve.nodes[n].name, t("alert.pveNodeOffline").arg(pve.nodes[n].name))
  for (var g = 0; g < pve.guests.length; g++) {
    var x = pve.guests[g]
    var key = x.node + "/" + x.type + "/" + x.vmid
    if (!x.running && known[key] && !expected[key])
      add("error", "guest|" + key, t("alert.pveGuestStopped").arg(x.name).arg(x.vmid), x.node + " · " + x.status)
  }
  for (var s = 0; s < pve.storages.length; s++) {
    var st = pve.storages[s]
    var pct = Model.percent(st.used, st.total)
    if (pct >= th.disk)
      add(pct >= Math.max(th.disk, 97) ? "error" : "warning", "storage|" + st.node + "|" + st.storage,
          t("alert.pveStorageFull").arg(st.storage).arg(Math.round(pct)), st.shared ? "" : st.node)
  }
  for (var k = 0; k < pve.failedTasks.length; k++) {
    var task = pve.failedTasks[k]
    add(task.type === "vzdump" ? "error" : "warning", "task|" + task.upid,
        task.type === "vzdump" ? t("alert.pveBackupFailed").arg(task.id || task.node) : t("alert.pveTaskFailed").arg(task.type).arg(task.id || task.node),
        task.status)
  }
  return out
}
