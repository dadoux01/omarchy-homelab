import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Proxmox.js" as Proxmox

// Owns the hosts file and every ssh round-trip. All remote work goes through
// bin/homelab with argv arrays; the panel only reads the properties below.
Item {
  id: root

  property var settings: ({})
  property bool active: false          // panel open: poll on the interval
  property string pluginDir: ""

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configPath: {
    var p = settings && settings.configPath ? String(settings.configPath) : ""
    if (p === "") return home + "/.config/omarchy/homelab.json"
    return p.indexOf("~/") === 0 ? home + p.slice(1) : p
  }
  readonly property string secretsPath: {
    var p = settings && settings.secretsPath ? String(settings.secretsPath) : ""
    if (p === "") return home + "/.config/omarchy/homelab-secrets.json"
    return p.indexOf("~/") === 0 ? home + p.slice(1) : p
  }
  readonly property int refreshMs: {
    var s = settings ? parseInt(settings.refreshIntervalSec, 10) : NaN
    return Math.max(3, Math.min(600, isFinite(s) ? s : 10)) * 1000
  }
  readonly property string helper: pluginDir + "/bin/homelab"

  property var hosts: []
  property string configError: ""      // "" | "missing" | "json" | "empty"
  property int hostIndex: 0
  readonly property var host: hosts.length > 0 ? hosts[Math.max(0, Math.min(hostIndex, hosts.length - 1))] : null

  // Per-host caches keyed by host.key so switching hosts shows the last
  // known state instantly while the fresh fetch runs.
  property var metricsCache: ({})
  property var dockerCache: ({})
  property var errorCache: ({})

  readonly property var metrics: host ? (metricsCache[host.key] || null) : null
  readonly property var docker: host ? (dockerCache[host.key] || null) : null
  readonly property string hostError: host ? (errorCache[host.key] || "") : ""
  readonly property bool online: metrics !== null && hostError === ""

  // ---------- Proxmox VE ----------
  // A host is treated as Proxmox when its metrics report it (or the hosts
  // file says "proxmox": true), unless "proxmox": false.
  readonly property bool isPve: host !== null && !(host.proxmox && host.proxmox.enabled === false)
      && ((metrics !== null && metrics.pve !== null) || (host.proxmox !== null && host.proxmox.enabled === true))
  property var pveCache: ({})
  readonly property var pve: host ? (pveCache[host.key] || null) : null
  property bool loadingPve: false
  property string pvePending: ""       // "<node>/<type>/<vmid>:<action>"
  property string pveActionError: ""
  property string pveNotice: ""
  readonly property string pveSecretId: host ? host.key + "/proxmox" : ""

  signal pveGuestStopping(string hostKey, string key)

  function pveArgs(h) {
    return [h.target, String(h.port), secretsPath, h.key + "/proxmox", Proxmox.baseUrl(h), Proxmox.insecure(h) ? "1" : "0"]
  }

  function refreshPve() {
    if (!host || !isPve || pveProc.running) return
    loadingPve = true
    pveProc.hostKey = host.key
    pveProc.command = [helper, "pve-read"].concat(pveArgs(host))
    pveProc.running = true
  }

  function pveAction(guest, action) {
    if (!host || pveActionProc.running || !guest) return
    if (["start", "shutdown", "stop", "reboot"].indexOf(action) < 0) return
    var key = guest.node + "/" + guest.type + "/" + guest.vmid
    if (action === "shutdown" || action === "stop") pveGuestStopping(host.key, key)
    pveActionError = ""
    pvePending = key + ":" + action
    pveActionProc.command = [helper, "pve-action"].concat(pveArgs(host), [guest.node, guest.type, String(guest.vmid), action])
    pveActionProc.running = true
  }

  function openPveConsole(guest) {
    if (host && guest) openUrl(Proxmox.consoleUrl(host, guest))
  }

  function openPveWeb() {
    if (host) openUrl(Proxmox.baseUrl(host))
  }

  function savePveToken(tokenId, secret) {
    if (!host) return
    var p = secretProcComponent.createObject(root, {
      command: [helper, "secret-set", secretsPath, pveSecretId],
      payload: JSON.stringify({ tokenId: String(tokenId || "").trim(), secret: String(secret || "").trim() })
    })
    p.running = true
  }

  function forgetPveToken() {
    if (!host) return
    var p = secretProcComponent.createObject(root, { command: [helper, "secret-del", secretsPath, pveSecretId] })
    p.running = true
  }

  Component {
    id: secretProcComponent
    Process {
      id: sp
      property string payload: ""
      stdinEnabled: true
      onStarted: { if (payload !== "") write(payload + "\n"); payload = "" }
      stderr: StdioCollector { id: spErr; waitForEnd: true }
      onExited: function(code) {
        root.pveNotice = code === 0 ? "saved" : Model.clip(String(spErr.text || "").trim() || ("exit " + code), 200)
        Qt.callLater(root.refreshPve)
        sp.destroy(1000)
      }
    }
  }

  property bool loadingMetrics: metricsProc.running
  property bool loadingDocker: dockerProc.running
  property string pendingAction: ""    // "<action>:<container>" while running
  // Image updates run on their own so start/stop stays usable meanwhile.
  property var updateQueue: []         // [{ host, name }] waiting
  property string updating: ""         // container being updated
  property string updatingHost: ""     // its host key
  property var updateResults: ({})     // "<hostKey>/<name>" -> "updated" | "uptodate" | "error <reason>"
  property var updateDetails: ({})     // "<hostKey>/<name>" -> remote error line, for failures

  signal containerUpdated(string hostKey, string name)

  function isQueued(hostKey, name) {
    return updateQueue.some(function(q) { return q.host.key === hostKey && q.name === name })
  }
  function isUpdating(hostKey, name) { return updating === name && updatingHost === hostKey }
  function updateResult(hostKey, name) { return updateResults[hostKey + "/" + name] || "" }
  function updateDetail(hostKey, name) { return updateDetails[hostKey + "/" + name] || "" }
  property string actionError: ""

  function put(cacheName, key, value) {
    var copy = Object.assign({}, root[cacheName])
    if (value === undefined) delete copy[key]
    else copy[key] = value
    root[cacheName] = copy
  }

  function selectHost(index) {
    if (index < 0 || index >= hosts.length || index === hostIndex) return
    hostIndex = index
    actionError = ""
    refresh()
  }

  function refresh() {
    refreshMetrics()
    refreshDocker()
    refreshPve()
  }

  function refreshMetrics() {
    if (!host || metricsProc.running) return
    metricsProc.hostKey = host.key
    metricsProc.command = [helper, "metrics", host.target, String(host.port)]
    metricsProc.running = true
  }

  function refreshDocker() {
    if (!host || dockerProc.running) return
    dockerProc.hostKey = host.key
    dockerProc.command = [helper, "docker", host.target, String(host.port)]
    dockerProc.running = true
  }

  function containerAction(action, name) {
    if (!host || actionProc.running) return
    if (["start", "stop", "restart"].indexOf(action) < 0 || !Model.validContainer(name)) return
    actionError = ""
    pendingAction = action + ":" + name
    actionProc.command = [helper, "action", host.target, String(host.port), action, name]
    actionProc.running = true
  }

  function updateContainer(name, onHost) {
    var h = onHost || host
    if (!h || !Model.validContainer(name)) return
    if (isUpdating(h.key, name) || isQueued(h.key, name)) return
    put("updateResults", h.key + "/" + name, undefined)
    updateQueue = updateQueue.concat([{ host: h, name: name }])
    nextUpdate()
  }

  function nextUpdate() {
    if (updateProc.running || updateQueue.length === 0) return
    var next = updateQueue[0]
    updateQueue = updateQueue.slice(1)
    updating = next.name
    updatingHost = next.host.key
    updateProc.command = [helper, "update", next.host.target, String(next.host.port), next.name]
    updateProc.running = true
  }

  function openShell() {
    if (host) Quickshell.execDetached([helper, "shell", host.target, String(host.port)])
  }

  function openLogs(name) {
    if (host && Model.validContainer(name))
      Quickshell.execDetached([helper, "logs", host.target, String(host.port), name])
  }

  function openUrl(url) {
    if (Model.validUrl(url)) Quickshell.execDetached(["xdg-open", url])
  }

  function editConfig() {
    Quickshell.execDetached([helper, "init", configPath])
  }

  function loadConfig(text, exists) {
    if (!exists) {
      hosts = []
      configError = "missing"
      return
    }
    var parsed = Model.parseConfig(text)
    hosts = parsed.hosts
    configError = parsed.error !== "" ? parsed.error : (parsed.hosts.length === 0 ? "empty" : "")
    if (hostIndex >= hosts.length) hostIndex = 0
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadConfig(text(), true)
    onLoadFailed: root.loadConfig("", false)
  }

  // Reload when the file appears later (created from the panel button).
  Timer {
    interval: 3000
    repeat: true
    running: root.active && root.configError === "missing"
    onTriggered: configFile.reload()
  }

  Timer {
    interval: root.refreshMs
    repeat: true
    running: root.active && root.host !== null
    triggeredOnStart: false
    onTriggered: root.refreshMetrics()
  }

  // Docker stats are slower and change less; poll them at a gentler pace.
  Timer {
    interval: Math.max(root.refreshMs * 3, 15000)
    repeat: true
    running: root.active && root.host !== null
    onTriggered: { root.refreshDocker(); root.refreshPve() }
  }

  // Exit and stream-finished arrive in no guaranteed order, so each run
  // finalizes only once both have landed.
  Process {
    id: metricsProc
    property string hostKey: ""
    property int code: 0
    property int pending: 0
    property string out: ""
    property string err: ""
    onRunningChanged: if (running) { pending = 3; out = ""; err = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { metricsProc.out = String(text || ""); metricsProc.step() }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { metricsProc.err = String(text || "").trim().split("\n").pop(); metricsProc.step() }
    }
    onExited: function(exitCode) { metricsProc.code = exitCode; metricsProc.step() }
    function step() {
      if (--pending > 0) return
      if (code === 0) {
        root.put("metricsCache", hostKey, Model.parseMetrics(out))
        root.put("errorCache", hostKey, "")
      } else {
        root.put("errorCache", hostKey, Model.clip(err || ("ssh exit " + code), 200))
      }
    }
  }

  Process {
    id: dockerProc
    property string hostKey: ""
    property int code: 0
    property int pending: 0
    property string out: ""
    onRunningChanged: if (running) { pending = 2; out = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { dockerProc.out = String(text || ""); dockerProc.step() }
    }
    onExited: function(exitCode) { dockerProc.code = exitCode; dockerProc.step() }
    function step() {
      if (--pending > 0) return
      var parsed = Model.parseDocker(out)
      if (code !== 0 && parsed.error === "") parsed.error = "unreachable"
      root.put("dockerCache", hostKey, parsed)
    }
  }

  Process {
    id: actionProc
    property int code: 0
    property int pending: 0
    property string err: ""
    onRunningChanged: if (running) { pending = 2; err = "" }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { actionProc.err = String(text || "").trim().split("\n").pop(); actionProc.step() }
    }
    onExited: function(exitCode) { actionProc.code = exitCode; actionProc.step() }
    function step() {
      if (--pending > 0) return
      if (code !== 0) root.actionError = Model.clip(err || ("exit " + code), 200)
      root.pendingAction = ""
      root.refreshDocker()
    }
  }

  Process {
    id: updateProc
    property int code: 0
    property int pending: 0
    property string out: ""
    onRunningChanged: if (running) { pending = 2; out = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { updateProc.out = String(text || ""); updateProc.step() }
    }
    onExited: function(exitCode) { updateProc.code = exitCode; updateProc.step() }
    function step() {
      if (--pending > 0) return
      var last = out.trim().split("\n").pop() || ""
      var result = /^(updated|uptodate|error [a-z]+)$/.test(last) ? last : (code === 124 ? "error timeout" : "error ssh")
      var hostKey = root.updatingHost, name = root.updating
      var detail = ""
      out.split("\n").forEach(function(l) { if (l.indexOf("detail\t") === 0) detail = Model.clip(l.slice(7), 300) })
      root.put("updateResults", hostKey + "/" + name, result)
      root.put("updateDetails", hostKey + "/" + name, result.indexOf("error") === 0 && detail !== "" ? detail : undefined)
      root.updating = ""
      root.updatingHost = ""
      if (result === "updated" || result === "uptodate") root.containerUpdated(hostKey, name)
      if (result === "updated" && root.host && root.host.key === hostKey) root.refreshDocker()
      root.nextUpdate()
    }
  }

  Process {
    id: pveProc
    property string hostKey: ""
    property int code: 0
    property int pending: 0
    property string out: ""
    onRunningChanged: if (running) { pending = 2; out = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { pveProc.out = String(text || ""); pveProc.step() }
    }
    onExited: function(exitCode) { pveProc.code = exitCode; pveProc.step() }
    function step() {
      if (--pending > 0) return
      var parsed = Proxmox.parse(out)
      if (code !== 0 && parsed.error === "") parsed.error = code === 124 ? "unreachable" : "noaccess"
      root.put("pveCache", hostKey, parsed)
      root.loadingPve = false
    }
  }

  Process {
    id: pveActionProc
    property int code: 0
    property int pending: 0
    property string err: ""
    onRunningChanged: if (running) { pending = 2; err = "" }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { pveActionProc.err = String(text || "").trim().split("\n").pop(); pveActionProc.step() }
    }
    onExited: function(exitCode) { pveActionProc.code = exitCode; pveActionProc.step() }
    function step() {
      if (--pending > 0) return
      if (code !== 0) root.pveActionError = Model.clip(err || ("exit " + code), 200)
      root.pvePending = ""
      pveFollowUp.restart()
    }
  }

  // Guests take a few seconds to change state; look again shortly after.
  Timer { id: pveFollowUp; interval: 3000; onTriggered: root.refreshPve() }
}
