import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Services.js" as Services
import "Alerts.js" as Alerts
import "Proxmox.js" as Proxmox

// Background side of the plugin, loaded once by the shell as a `service`
// (the bar widget exists once per screen; this does not). It watches every
// host while the panel is closed, raises alerts, checks for updates and sends
// desktop notifications exactly once per new event. Bar widgets read
// `alerts`, `updates` and `alertCount` from here through
// bar.shell.serviceFor("dadoux01.homelab").
Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "dadoux01.homelab"

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/+$/, "")
  readonly property string helper: pluginDir + "/bin/homelab"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omarchy-homelab"
  readonly property string statePath: stateDir + "/state.json"

  // ---------- settings (from the widget's bar entry) ----------

  readonly property var settings: {
    var layout = shell && shell.barConfig ? shell.barConfig.layout : null
    if (layout)
      for (var section in layout) {
        var entries = layout[section]
        if (!Array.isArray(entries)) continue
        for (var i = 0; i < entries.length; i++)
          if (entries[i] && entries[i].id === root.pluginId) return entries[i]
      }
    return ({})
  }
  function setting(name, fallback) {
    var v = settings[name]
    return v === undefined || v === null || v === "" ? fallback : v
  }
  function intSetting(name, fallback, min, max) {
    var v = parseInt(setting(name, fallback), 10)
    return Math.max(min, Math.min(max, isFinite(v) ? v : fallback))
  }
  function expand(p) { return p.indexOf("~/") === 0 ? home + p.slice(1) : p }

  readonly property string configPath: expand(String(setting("configPath", "~/.config/omarchy/homelab.json")))
  readonly property string secretsPath: expand(String(setting("secretsPath", "~/.config/omarchy/homelab-secrets.json")))
  readonly property bool notificationsEnabled: setting("notifications", true) !== false
  readonly property bool notifyUpdates: setting("notifyUpdates", true) !== false
  readonly property int watchMs: intSetting("backgroundIntervalSec", 120, 30, 3600) * 1000
  readonly property int updateHours: intSetting("updateCheckHours", 6, 0, 168)
  readonly property var thresholds: ({
    disk: intSetting("diskWarnPercent", 90, 50, 100),
    memory: intSetting("memoryWarnPercent", 95, 50, 100),
    temperature: intSetting("temperatureWarnCelsius", 85, 40, 120)
  })

  Strings {
    id: strings
    directory: Qt.resolvedUrl("i18n")
    language: codeFor(root.setting("language", "English"))
  }
  function t(k) { return strings.t(k) }

  // ---------- state ----------

  property var hosts: []
  property var hostState: ({})         // hostKey -> { failures, lastError, metrics, docker, running, expectedStops, services }
  property var updates: ({})           // hostKey -> parsed updates (persisted)
  property var alerts: []              // every active alert, all hosts
  property var updateList: []          // every pending update, all hosts
  property var notified: ({})          // alert/update id -> epoch ms (persisted)
  property var checking: ({})          // hostKey -> true while an update check runs
  property bool stateLoaded: false

  readonly property int alertCount: alerts.filter(function(a) { return a.level !== "info" }).length
  readonly property bool hasErrors: alerts.some(function(a) { return a.level === "error" })
  readonly property int updateCount: updateList.length
  readonly property bool checkingUpdates: Object.keys(checking).length > 0

  function hostByKey(key) {
    for (var i = 0; i < hosts.length; i++) if (hosts[i].key === key) return hosts[i]
    return null
  }

  function stateOf(key) {
    return hostState[key] || { failures: 0, lastError: "", metrics: null, docker: null, running: {}, expectedStops: {}, services: {},
                               pve: null, pveKnown: {}, pveExpected: {} }
  }

  function patchHost(key, patch) {
    var next = Object.assign({}, hostState)
    next[key] = Object.assign({}, stateOf(key), patch)
    hostState = next
  }

  // ---------- public API (used by the bar widgets) ----------

  function updatesFor(hostKey) { return updates[hostKey] || null }

  function imageUpdateFor(hostKey, container) {
    var u = updates[hostKey]
    if (!u) return false
    for (var i = 0; i < u.images.length; i++) if (u.images[i].container === container) return true
    return false
  }

  // A container the user stops on purpose must not raise "stopped".
  function expectStop(hostKey, name) {
    var s = stateOf(hostKey)
    var e = Object.assign({}, s.expectedStops)
    e[name] = Date.now()
    patchHost(hostKey, { expectedStops: e })
  }

  // A Proxmox guest shut down from the panel must not raise "stopped".
  function expectPveStop(hostKey, key) {
    var s = stateOf(hostKey)
    var e = Object.assign({}, s.pveExpected || {})
    e[key] = Date.now()
    patchHost(hostKey, { pveExpected: e })
  }

  // An image update recreated the container: forget it until the next check.
  function containerUpdated(hostKey, name) {
    var u = updates[hostKey]
    if (!u) return
    var copy = Object.assign({}, u, { images: u.images.filter(function(i) { return i.container !== name }) })
    var next = Object.assign({}, updates)
    next[hostKey] = copy
    updates = next
    rebuildUpdates()
    saveState()
  }

  function checkUpdates(hostKey) {
    for (var i = 0; i < hosts.length; i++)
      if (!hostKey || hosts[i].key === hostKey) runUpdates(hosts[i])
  }

  function upgradePackages(hostKey) {
    var host = hostByKey(hostKey)
    if (host) Quickshell.execDetached([helper, "os", host.target, String(host.port), "upgrade"])
  }

  property var checkingPackages: ({})  // hostKey -> true during a packages-only check

  // Packages only: refreshes the host's package lists (privately, no root)
  // and keeps the last image results, so it is quick and spares registries.
  function checkPackages(hostKey) {
    var host = hostByKey(hostKey)
    if (!host || checkingPackages[hostKey]) return
    var c = Object.assign({}, checkingPackages); c[hostKey] = true; checkingPackages = c
    run("packages:" + hostKey, [helper, "updates", host.target, String(host.port), "packages"], function(code, out) {
      var n = Object.assign({}, root.checkingPackages); delete n[hostKey]; root.checkingPackages = n
      if (code !== 0 && out.trim() === "") return
      var fresh = Alerts.parseUpdates(out)
      var prev = root.updates[hostKey] || { images: [], imageErrors: 0, rateLimited: 0, imageCheck: true, checkedAt: 0 }
      var next = Object.assign({}, root.updates)
      next[hostKey] = Object.assign({}, prev, { os: fresh.os, sudo: fresh.sudo, reboot: fresh.reboot, busy: fresh.busy, packagesCheckedAt: fresh.checkedAt })
      root.updates = next
      root.evaluate(hostKey)
      root.rebuildUpdates()
      root.notifyNewUpdates()
      root.saveState()
    })
  }

  function dismiss(id) {
    alerts = alerts.filter(function(a) { return a.id !== id })
  }

  function refreshNow() {
    watchTick()
    probeTick()
  }

  // ---------- jobs ----------

  Component {
    id: jobComponent
    Process {
      id: job
      property var done: null
      property int pending: 3
      property int code: 0
      property string out: ""
      property string err: ""
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: { job.out = String(text || ""); job.step() } }
      stderr: StdioCollector { waitForEnd: true; onStreamFinished: { job.err = String(text || "").trim().split("\n").pop(); job.step() } }
      onExited: function(exitCode) { job.code = exitCode; job.step() }
      function step() {
        if (--pending > 0) return
        var cb = done
        done = null
        if (cb) cb(code, out, err)
        job.destroy()
      }
    }
  }

  property var runningJobs: ({})
  function run(key, command, cb) {
    if (runningJobs[key]) return
    var r = Object.assign({}, runningJobs); r[key] = true; runningJobs = r
    var p = jobComponent.createObject(root, {
      command: command,
      done: function(code, out, err) {
        var n = Object.assign({}, root.runningJobs); delete n[key]; root.runningJobs = n
        cb(code, out, err)
      }
    })
    p.running = true
  }

  function watchHost(host) {
    var key = host.key
    run("metrics:" + key, [helper, "metrics", host.target, String(host.port)], function(code, out, err) {
      if (code === 0) {
        var metrics = Model.parseMetrics(out)
        patchHost(key, { failures: 0, lastError: "", metrics: metrics })
        run("docker:" + key, [helper, "docker", host.target, String(host.port)], function(c2, out2) {
          var d = Model.parseDocker(out2)
          if (c2 !== 0 && d.error === "") d.error = "unreachable"
          trackRunning(key, d)
          evaluate(key)
        })
        var pveOff = host.proxmox && host.proxmox.enabled === false
        if (!pveOff && (metrics.pve || (host.proxmox && host.proxmox.enabled))) {
          run("pve:" + key, [helper, "pve-read", host.target, String(host.port), secretsPath, key + "/proxmox",
                             Proxmox.baseUrl(host), Proxmox.insecure(host) ? "1" : "0"], function(c3, out3) {
            var pve = Proxmox.parse(out3)
            if (c3 !== 0 && pve.error === "") pve.error = "noaccess"
            trackPve(key, pve)
            evaluate(key)
          })
        }
      } else {
        patchHost(key, { failures: stateOf(key).failures + 1, lastError: Model.clip(err || ("ssh exit " + code), 200) })
        evaluate(key)
      }
    })
  }

  // Containers seen running stay "expected up" until removed, restarted, or
  // stopped on purpose from the panel.
  function trackRunning(key, docker) {
    var s = stateOf(key)
    var running = Object.assign({}, s.running)
    var expected = Object.assign({}, s.expectedStops)
    var present = {}
    if (docker.error === "") {
      for (var i = 0; i < docker.containers.length; i++) {
        var c = docker.containers[i]
        present[c.name] = true
        if (c.state === "running") { running[c.name] = true; delete expected[c.name] }
        else if (expected[c.name]) delete running[c.name]
      }
      for (var n in running) if (!present[n]) delete running[n]
      for (var e in expected) if (Date.now() - expected[e] > 3600000) delete expected[e]
    }
    patchHost(key, { docker: docker, running: running, expectedStops: expected })
    saveState()
  }

  // Guests seen running stay "expected up" until they run again after a stop
  // the user asked for, or disappear.
  function trackPve(key, pve) {
    var s = stateOf(key)
    var known = Object.assign({}, s.pveKnown || {})
    var expected = Object.assign({}, s.pveExpected || {})
    if (pve.error === "") {
      var present = {}
      pve.guests.forEach(function(g) {
        var k = g.node + "/" + g.type + "/" + g.vmid
        present[k] = true
        if (g.running) { known[k] = true; delete expected[k] }
        else if (expected[k]) delete known[k]
      })
      for (var n in known) if (!present[n]) delete known[n]
      for (var e in expected) if (Date.now() - expected[e] > 3600000) delete expected[e]
    }
    patchHost(key, { pve: pve, pveKnown: known, pveExpected: expected })
    saveState()
  }

  function probeHost(host) {
    var s = stateOf(host.key)
    if (!s.docker) return
    var list = Services.list(host, s.docker)
    list.forEach(function(svc) {
      if (!svc.running || !hasSecret(svc)) return
      var steps = Services.probePlan(svc)
      var results = {}
      var left = steps.length
      steps.forEach(function(step) {
        api.request(svc, "GET", step.path, null, function(res) {
          results[step.key] = res
          if (--left > 0) return
          var probe = Services.parseProbe(svc, results, root.t)
          var services = Object.assign({}, stateOf(host.key).services)
          services[svc.id] = probe
          patchHost(host.key, { services: services })
          evaluate(host.key)
          rebuildUpdates()
          notifyNewUpdates()
        })
      })
    })
  }

  function hasSecret(svc) {
    var have = api.secretFields[svc.key] || []
    var fields = Services.CATALOG[svc.id].fields
    for (var i = 0; i < fields.length; i++) if (have.indexOf(fields[i].key) < 0) return false
    return true
  }

  function runUpdates(host) {
    if (checking[host.key]) return
    var c = Object.assign({}, checking); c[host.key] = true; checking = c
    run("updates:" + host.key, [helper, "updates", host.target, String(host.port)], function(code, out) {
      var n = Object.assign({}, root.checking); delete n[host.key]; root.checking = n
      if (code !== 0 && out.trim() === "") return
      var next = Object.assign({}, root.updates)
      var parsed = Alerts.parseUpdates(out)
      parsed.packagesCheckedAt = parsed.checkedAt
      next[host.key] = parsed
      root.updates = next
      root.evaluate(host.key)
      root.rebuildUpdates()
      root.notifyNewUpdates()
      root.saveState()
    })
  }

  // ---------- evaluation + notifications ----------

  function evaluate(key) {
    var host = hostByKey(key)
    if (!host) return
    var s = Object.assign({}, stateOf(key), { updates: updates[key] || null })
    var fresh = Alerts.evaluate(host, s, thresholds, t)
    var previous = alerts.filter(function(a) { return a.hostKey === key })
    var others = alerts.filter(function(a) { return a.hostKey !== key })
    var now = Date.now()
    fresh.forEach(function(a) {
      var old = previous.filter(function(p) { return p.id === a.id })[0]
      a.since = old ? old.since : now
    })
    alerts = others.concat(fresh).sort(function(a, b) {
      var rank = { error: 0, warning: 1, info: 2 }
      return rank[a.level] - rank[b.level] || b.since - a.since
    })

    var activeIds = {}
    fresh.forEach(function(a) { activeIds[a.id] = true })
    var wasDown = previous.some(function(a) { return a.kind === "down" })
    var isDown = fresh.some(function(a) { return a.kind === "down" })

    var n = Object.assign({}, notified)
    var announce = fresh.filter(function(a) { return !n[a.id] && a.level !== "info" })
    // A host that just went down takes its other alerts with it: one message.
    if (announce.length > 3) {
      notify(announce.some(function(a) { return a.level === "error" }) ? "critical" : "normal",
             t("notify.manyAlerts").arg(announce.length).arg(host.name),
             announce.slice(0, 4).map(function(a) { return a.title }).join("\n"), "alerts")
    } else {
      announce.forEach(function(a) {
        notify(a.level === "error" ? "critical" : "normal", a.title, a.body, a.tab)
      })
    }
    announce.forEach(function(a) { n[a.id] = now })
    if (wasDown && !isDown) notify("low", t("notify.backOnline").arg(host.name), "", "monitoring")
    // Forget resolved alerts so they announce again if they come back.
    for (var id in n)
      if (id.indexOf(key + "|") === 0 && id.indexOf("|upd|") < 0 && !activeIds[id]) delete n[id]
    notified = n
    saveState()
  }

  function rebuildUpdates() {
    var list = []
    for (var i = 0; i < hosts.length; i++) {
      var h = hosts[i]
      var services = stateOf(h.key).services || {}
      list = list.concat(Alerts.updateItems(h, updates[h.key] || null, services))
    }
    updateList = list
  }

  function notifyNewUpdates() {
    var n = Object.assign({}, notified)
    var fresh = updateList.filter(function(u) { return !n[u.id] })
    var current = {}
    updateList.forEach(function(u) { current[u.id] = true })
    for (var id in n) if (id.indexOf("|upd|") >= 0 && !current[id]) delete n[id]
    if (fresh.length > 0 && notifyUpdates) {
      // One line per host naming what changed, so nobody has to open every
      // host to find out where the updates are.
      var order = [], byHost = {}
      fresh.forEach(function(u) {
        if (!byHost[u.hostKey]) { byHost[u.hostKey] = []; order.push(u.hostKey) }
        byHost[u.hostKey].push(u)
      })
      var lines = order.slice(0, 5).map(function(hk) {
        var h = hostByKey(hk)
        return (h ? h.name : hk) + ": " + updateSummary(byHost[hk])
      })
      if (order.length > 5) lines.push(t("notify.moreHosts").arg(order.length - 5))
      var title = order.length === 1
          ? t("notify.updatesOn").arg(hostByKey(order[0]) ? hostByKey(order[0]).name : order[0])
          : t("notify.updatesTitle")
      notify("normal", title, lines.join("\n"), "alerts")
    }
    fresh.forEach(function(u) { n[u.id] = Date.now() })
    notified = n
    saveState()
  }

  // "sonarr, radarr +2 · 12 packages · Jellyfin 10.10.3" for one host.
  function updateSummary(items) {
    var parts = []
    var images = items.filter(function(u) { return u.kind === "image" }).map(function(u) { return u.container })
    if (images.length > 0)
      parts.push(images.slice(0, 4).join(", ") + (images.length > 4 ? " " + t("notify.more").arg(images.length - 4) : ""))
    var os = items.filter(function(u) { return u.kind === "os" })
    var count = os.reduce(function(s, u) { return s + u.count }, 0)
    var security = os.reduce(function(s, u) { return s + u.security }, 0)
    if (count > 0)
      parts.push((count === 1 ? t("notify.package") : t("notify.packages").arg(count))
                 + (security > 0 ? " (" + t("notify.security").arg(security) + ")" : ""))
    var svcs = items.filter(function(u) { return u.kind === "service" })
    svcs.slice(0, 3).forEach(function(u) { parts.push(u.name + (u.latest ? " " + u.latest : "")) })
    if (svcs.length > 3) parts.push(t("notify.more").arg(svcs.length - 3))
    return parts.join(" · ")
  }

  function notify(urgency, title, body, tab) {
    if (!notificationsEnabled || !stateLoaded) return
    Quickshell.execDetached([helper, "notify", urgency, Alerts.escapeMarkup(title), Alerts.escapeMarkup(body),
                             t("notify.open"), tab || "alerts"])
  }

  // ---------- persistence ----------

  function saveState() {
    if (!stateLoaded) return
    saveTimer.restart()
  }

  Timer {
    id: saveTimer
    interval: 1500
    onTriggered: {
      var running = {}, pveKnown = {}
      for (var k in root.hostState) {
        running[k] = root.hostState[k].running || {}
        pveKnown[k] = root.hostState[k].pveKnown || {}
      }
      stateFile.setText(JSON.stringify({ version: 1, notified: root.notified, updates: root.updates, running: running, pveKnown: pveKnown }))
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    blockLoading: true
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  function loadState(text) {
    if (stateLoaded) return
    try {
      var data = JSON.parse(text || "{}") || {}
      notified = data.notified && typeof data.notified === "object" ? data.notified : {}
      updates = data.updates && typeof data.updates === "object" ? data.updates : {}
      var hs = {}
      for (var k in (data.running || {})) hs[k] = Object.assign(stateOf(k), { running: data.running[k] || {} })
      for (var p in (data.pveKnown || {})) hs[p] = Object.assign(hs[p] || stateOf(p), { pveKnown: data.pveKnown[p] || {} })
      hostState = hs
    } catch (e) {}
    stateLoaded = true
    rebuildUpdates()
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    running: true
  }

  // ---------- config + helpers ----------

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.hosts = Model.parseConfig(text()).hosts; root.rebuildUpdates(); startDelay.restart() }
    onLoadFailed: root.hosts = []
  }

  ServicesClient {
    id: api
    helper: root.helper
    secretsPath: root.secretsPath
    active: false
  }

  // ---------- schedule ----------

  function watchTick() { hosts.forEach(function(h) { watchHost(h) }) }
  function probeTick() { hosts.forEach(function(h) { probeHost(h) }) }
  function updateTick() {
    if (updateHours <= 0) return
    var now = Date.now()
    hosts.forEach(function(h) {
      var u = updates[h.key]
      if (!u || now - (u.checkedAt || 0) >= updateHours * 3600000) runUpdates(h)
    })
  }

  // Let the shell finish starting before the first round of ssh.
  Timer {
    id: startDelay
    interval: 8000
    onTriggered: { root.watchTick(); probeStart.restart() }
  }
  Timer { id: probeStart; interval: 15000; onTriggered: { root.probeTick(); root.updateTick() } }

  Timer { interval: root.watchMs; repeat: true; running: root.hosts.length > 0; onTriggered: root.watchTick() }
  Timer { interval: Math.max(root.watchMs * 3, 300000); repeat: true; running: root.hosts.length > 0; onTriggered: root.probeTick() }
  Timer { interval: 600000; repeat: true; running: root.hosts.length > 0 && root.updateHours > 0; onTriggered: root.updateTick() }
}
