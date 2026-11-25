.pragma library

// Pure parsing and formatting helpers for the Homelab plugin. Every input
// here comes from a remote host or a user file, so values are bounded and
// coerced before the panel sees them.

var MAX_HOSTS = 16
var MAX_LINKS = 24
var MAX_TEXT = 160

function clip(value, max) {
  var s = value === undefined || value === null ? "" : String(value)
  s = s.replace(/[\u0000-\u001f\u007f]/g, " ")
  var limit = max || MAX_TEXT
  return s.length > limit ? s.slice(0, limit - 1) + "…" : s
}

function num(value) {
  var n = parseFloat(value)
  return isFinite(n) ? n : 0
}

function validTarget(target) {
  return /^[A-Za-z0-9][A-Za-z0-9_.@:%-]*$/.test(String(target || ""))
}

function validUrl(url) {
  return /^https?:\/\/[^\s"'<>]+$/i.test(String(url || ""))
}

function validContainer(name) {
  return /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(String(name || ""))
}

function validAddress(addr) {
  return /^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$/.test(String(addr || ""))
}

var SERVICE_IDS = ["jellyfin", "homeassistant", "prowlarr", "navidrome"]

// "services": { "<id>": { url, enabled, insecure, container, entities } }
function parseServiceOverrides(raw) {
  var out = {}
  if (!raw || typeof raw !== "object") return out
  for (var i = 0; i < SERVICE_IDS.length; i++) {
    var id = SERVICE_IDS[i]
    var o = raw[id]
    if (o === false) { out[id] = { enabled: false }; continue }
    if (!o || typeof o !== "object") continue
    var entry = {}
    if (o.enabled === false) entry.enabled = false
    if (validServiceUrl(o.url)) entry.url = String(o.url).replace(/\/+$/, "")
    if (o.insecure === true) entry.insecure = true
    if (validContainer(o.container)) entry.container = String(o.container)
    if (Array.isArray(o.entities))
      entry.entities = o.entities.filter(function(e) { return /^[a-z_]+\.[A-Za-z0-9_]+$/.test(String(e)) }).slice(0, 60)
    out[id] = entry
  }
  return out
}

// "proxmox": false | true | { url, insecure } -> null (auto) or settings.
function parseProxmox(raw) {
  if (raw === false) return { enabled: false }
  if (raw === true) return { enabled: true }
  if (!raw || typeof raw !== "object") return null
  var out = { enabled: raw.enabled !== false }
  if (/^https?:\/\/[\][A-Za-z0-9._:%-]+\/?$/.test(String(raw.url || ""))) out.url = String(raw.url).replace(/\/+$/, "")
  if (raw.insecure === false) out.insecure = false
  return out
}

// Base URL for a service API: scheme, host, port and an optional plain path.
function validServiceUrl(url) {
  return /^https?:\/\/[\][A-Za-z0-9._:%-]+(\/[A-Za-z0-9._~\/-]*)?$/.test(String(url || ""))
}

// Hosts file -> { hosts: [...], error: "" }
function parseConfig(text) {
  var result = { hosts: [], error: "" }
  if (!text || String(text).trim() === "") return result
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    result.error = "json"
    return result
  }
  var list = data && Array.isArray(data.hosts) ? data.hosts : []
  for (var i = 0; i < list.length && result.hosts.length < MAX_HOSTS; i++) {
    var h = list[i] || {}
    var target = String(h.ssh || h.host || "")
    if (!validTarget(target)) continue
    var port = parseInt(h.port, 10)
    if (!(port > 0 && port < 65536)) port = 22
    var links = []
    var rawLinks = Array.isArray(h.links) ? h.links : []
    for (var j = 0; j < rawLinks.length && links.length < MAX_LINKS; j++) {
      var l = rawLinks[j] || {}
      if (!validUrl(l.url)) continue
      links.push({ name: clip(l.name || l.url, 60), url: String(l.url).slice(0, 2048), icon: clip(l.icon || "", 4) })
    }
    result.hosts.push({
      key: target + ":" + port,
      name: clip(h.name || target, 40),
      target: target,
      port: port,
      address: validAddress(h.address) ? String(h.address) : "",
      links: links,
      services: parseServiceOverrides(h.services),
      proxmox: parseProxmox(h.proxmox)
    })
  }
  return result
}

function cpuPercent(a, b) {
  var x = String(a || "").trim().split(/\s+/).slice(1).map(num)
  var y = String(b || "").trim().split(/\s+/).slice(1).map(num)
  if (x.length < 4 || y.length < 4) return -1
  var idleA = x[3] + (x[4] || 0)
  var idleB = y[3] + (y[4] || 0)
  var totalA = 0, totalB = 0
  for (var i = 0; i < Math.min(8, x.length); i++) totalA += x[i]
  for (var k = 0; k < Math.min(8, y.length); k++) totalB += y[k]
  var total = totalB - totalA
  if (total <= 0) return 0
  return Math.max(0, Math.min(100, (1 - (idleB - idleA) / total) * 100))
}

// Friendly name for an hwmon chip.
function sensorName(chip, label) {
  var c = String(chip)
  if (/^(coretemp|k10temp|zenpower|cpu_thermal|cpu-thermal|soc_thermal)$/.test(c)) return "CPU"
  if (/^nvme/.test(c)) return "NVMe"
  if (/^(amdgpu|nouveau|radeon)$/.test(c)) return "GPU"
  if (/^drivetemp$/.test(c)) return "Disk"
  if (/^(acpitz|pch_)/.test(c)) return "Board"
  return clip(c, 24)
}

// metrics.sh output -> snapshot object
function parseMetrics(text) {
  var m = {
    hostname: "", os: "", kernel: "", uptime: 0, load: [0, 0, 0], cpus: 0, cpuModel: "",
    cpu: -1, mem: null, swap: null, disks: [], temps: [], gpus: [], net: null, docker: false, pve: null
  }
  var tempsByName = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length && i < 400; i++) {
    var f = lines[i].split("\t")
    switch (f[0]) {
    case "host": m.hostname = clip(f[1], 64); break
    case "os": m.os = clip(f[1], 80); break
    case "kernel": m.kernel = clip(f[1], 64); break
    case "uptime": m.uptime = num(f[1]); break
    case "load": m.load = String(f[1] || "").split(" ").map(num).slice(0, 3); break
    case "cpus": m.cpus = Math.round(num(f[1])); break
    case "cpumodel": m.cpuModel = clip(f[1].replace(/\s+/g, " "), 80); break
    case "cpustat": m.cpu = cpuPercent(f[1], f[2]); break
    case "mem": {
      var total = num(f[1]) * 1024, avail = num(f[2]) * 1024
      if (total > 0) m.mem = { used: total - avail, total: total }
      var st = num(f[3]) * 1024, sf = num(f[4]) * 1024
      if (st > 0) m.swap = { used: st - sf, total: st }
      break
    }
    case "disk": {
      if (m.disks.length >= 12) break
      var size = num(f[2]) * 1024
      if (size <= 0) break
      m.disks.push({ mount: clip(f[1], 48), used: num(f[3]) * 1024, total: size })
      break
    }
    case "temp": {
      var name = sensorName(f[1], f[2])
      var c = num(f[3]) / 1000
      if (c <= 0 || c > 150) break
      if (tempsByName[name] === undefined || c > tempsByName[name]) tempsByName[name] = c
      break
    }
    case "gpu": {
      if (m.gpus.length >= 4) break
      m.gpus.push({
        name: clip(f[1], 48), util: num(f[2]),
        memUsed: num(f[3]) * 1048576, memTotal: num(f[4]) * 1048576,
        temp: f[5] !== undefined && f[5] !== "" ? num(f[5]) : -1
      })
      break
    }
    case "net": {
      var a = String(f[1] || "").split(" ").map(num)
      var b = String(f[2] || "").split(" ").map(num)
      var dt = num(f[3]) || 0.5
      if (a.length === 2 && b.length === 2)
        m.net = { rx: Math.max(0, (b[0] - a[0]) / dt), tx: Math.max(0, (b[1] - a[1]) / dt) }
      break
    }
    case "docker": m.docker = true; break
    case "pve": m.pve = { version: clip(f[1], 24), access: /^(root|sudo|none)$/.test(f[2]) ? f[2] : "none" }; break
    }
  }
  for (var key in tempsByName) m.temps.push({ name: key, value: tempsByName[key] })
  m.temps.sort(function(x, y) { return x.name === "CPU" ? -1 : y.name === "CPU" ? 1 : x.name.localeCompare(y.name) })
  return m
}

// docker.sh output -> { containers: [...], error: "" }
function parseDocker(text) {
  var out = { containers: [], error: "" }
  var stats = {}
  var byName = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length && i < 500; i++) {
    var f = lines[i].split("\t")
    if (f[0] === "error") out.error = f[1] === "missing" ? "missing" : "noaccess"
    else if (f[0] === "c" && validContainer(f[1]) && !byName[f[1]]) {
      var c = { name: f[1], image: clip(f[2], 120), state: clip(f[3], 16).toLowerCase(), status: clip(f[4], 60), ports: clip(f[5], 400),
                created: parseDockerDate(f[6]), cpu: "", mem: "", cpuValue: -1, memBytes: -1 }
      byName[c.name] = c
      out.containers.push(c)
    } else if (f[0] === "s") {
      stats[f[1]] = { cpu: clip(f[2], 12), mem: clip(String(f[3] || "").split("/")[0].trim(), 16) }
    }
  }
  for (var j = 0; j < out.containers.length; j++) {
    var s = stats[out.containers[j].name]
    if (s) {
      out.containers[j].cpu = s.cpu
      out.containers[j].mem = s.mem
      out.containers[j].cpuValue = num(String(s.cpu).replace("%", ""))
      out.containers[j].memBytes = parseSize(s.mem)
    }
  }
  out.containers.sort(function(a, b) {
    var ra = a.state === "running" ? 0 : 1, rb = b.state === "running" ? 0 : 1
    return ra !== rb ? ra - rb : a.name.localeCompare(b.name)
  })
  return out
}

// "2026-11-18 09:38:43 +0100 CET" -> epoch ms, 0 when unknown.
function parseDockerDate(text) {
  var m = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ([+-]\d{2})(\d{2})/.exec(String(text || ""))
  if (!m) return 0
  var ms = Date.parse(m[1] + "T" + m[2] + m[3] + ":" + m[4])
  return isFinite(ms) ? ms : 0
}

// Docker size strings ("90.72MiB", "1.2GB", "512kB") -> bytes, -1 when unknown.
function parseSize(text) {
  var m = /^([\d.]+)\s*([KMGTP]?i?B|[kmgtp]B)$/.exec(String(text || "").trim())
  if (!m) return -1
  var unit = m[2].toUpperCase()
  var pow = { "B": 0, "KB": 1, "KIB": 1, "MB": 2, "MIB": 2, "GB": 3, "GIB": 3, "TB": 4, "TIB": 4, "PB": 5, "PIB": 5 }[unit]
  if (pow === undefined) return -1
  var base = unit.indexOf("I") >= 0 || unit === "B" ? 1024 : 1000
  return num(m[1]) * Math.pow(base, pow)
}

// Search, state filter and sort for the Docker tab. Containers without a
// value for the sort key (stopped ones have no CPU/memory) always go last.
function filterContainers(list, query, state, sortKey, descending) {
  var q = String(query || "").trim().toLowerCase()
  var out = (list || []).filter(function(c) {
    if (state === "running" && c.state !== "running") return false
    if (state === "stopped" && c.state === "running") return false
    if (q === "") return true
    return c.name.toLowerCase().indexOf(q) >= 0 || c.image.toLowerCase().indexOf(q) >= 0
  })
  function value(c) {
    switch (sortKey) {
    case "created": return c.created > 0 ? c.created : null
    case "cpu": return c.cpuValue >= 0 ? c.cpuValue : null
    case "memory": return c.memBytes >= 0 ? c.memBytes : null
    }
    return c.name.toLowerCase()
  }
  out.sort(function(a, b) {
    var va = value(a), vb = value(b)
    if (va === null || vb === null) {
      if (va === null && vb === null) return a.name.localeCompare(b.name)
      return va === null ? 1 : -1
    }
    var r = typeof va === "string" ? va.localeCompare(vb) : va - vb
    if (r === 0) r = a.name.localeCompare(b.name)
    return descending ? -r : r
  })
  return out
}

function bytes(value, formatNumber) {
  var units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
  var v = num(value), i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  var decimals = v >= 100 || i === 0 ? 0 : 1
  return (formatNumber ? formatNumber(v, decimals) : v.toFixed(decimals)) + " " + units[i]
}

// "1,8 / 4,0 GiB" when both share a unit, else "512 MiB / 4,0 GiB".
function bytesPair(used, total, formatNumber) {
  var a = bytes(used, formatNumber), b = bytes(total, formatNumber)
  var ua = a.split(" ").pop(), ub = b.split(" ").pop()
  return ua === ub ? a.slice(0, a.length - ua.length - 1) + " / " + b : a + " / " + b
}

function rate(value, formatNumber) {
  return bytes(value, formatNumber) + "/s"
}

function percent(used, total) {
  return total > 0 ? Math.max(0, Math.min(100, used / total * 100)) : 0
}

function duration(seconds) {
  var s = Math.max(0, Math.floor(num(seconds)))
  var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  return m + "m"
}
