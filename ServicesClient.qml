import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Services.js" as Services

// State behind the Services tab: which services the selected host runs, which
// of them have credentials, and the last view model fetched for each. All
// HTTP goes through `bin/homelab api`, which reads secrets from the secrets
// file itself, so API keys never sit in argv or in this process's bindings.
Item {
  id: root

  property var host: null
  property var docker: null
  property string helper: ""
  property string secretsPath: ""
  property bool active: false          // Services tab visible
  property int refreshMs: 15000
  property var translate: function(k) { return k }
  property var formatNumber: function(v, d) { return String(v) }

  readonly property var services: Services.list(host, docker)
  property string selectedId: ""
  readonly property var service: {
    for (var i = 0; i < services.length; i++) if (services[i].id === selectedId) return services[i]
    return services.length > 0 ? services[0] : null
  }

  // service.key -> [field names present]; values are never kept here.
  property var secretFields: ({})
  // service.key -> view model / bookkeeping
  property var views: ({})
  property var loading: ({})
  property var searchResults: ({})
  property string searching: ""        // service.key while a search runs
  property string busyAction: ""       // "<service.key>|<action>|<item id>"
  property string notice: ""
  property bool noticeError: false

  readonly property var view: service ? (views[service.key] || null) : null
  readonly property bool isLoading: service ? !!loading[service.key] : false
  readonly property var catalog: service ? Services.CATALOG[service.id] : null

  function hasSecret(svc) {
    if (!svc) return false
    var have = secretFields[svc.key] || []
    var fields = Services.CATALOG[svc.id].fields
    for (var i = 0; i < fields.length; i++) if (have.indexOf(fields[i].key) < 0) return false
    return true
  }

  function put(name, key, value) {
    var copy = Object.assign({}, root[name])
    if (value === undefined) delete copy[key]
    else copy[key] = value
    root[name] = copy
  }

  function select(id) {
    selectedId = id
    notice = ""
    refresh()
  }

  // ---------- requests ----------

  Component {
    id: requestComponent
    Process {
      id: req
      property var done: null
      property int pending: 3
      property int code: 0
      property string out: ""
      property string err: ""
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: { req.out = String(text || ""); req.step() } }
      stderr: StdioCollector { waitForEnd: true; onStreamFinished: { req.err = String(text || ""); req.step() } }
      onExited: function(exitCode) { req.code = exitCode; req.step() }
      function step() {
        if (--pending > 0) return
        var lines = err.trim().split("\n")
        var status = 0, missing = false, message = ""
        for (var i = lines.length - 1; i >= 0; i--) {
          var m = /^HTTP (\d{3}|0)( missing-secret)?$/.exec(lines[i].trim())
          if (m) { status = parseInt(m[1], 10); missing = !!m[2]; break }
        }
        if (status === 0 && !missing) message = lines.filter(function(l) { return l.indexOf("HTTP ") !== 0 }).pop() || ("exit " + code)
        var cb = done
        done = null
        if (cb) cb({ status: status, body: out, missingSecret: missing, error: message })
        req.destroy()
      }
    }
  }

  function request(svc, method, path, body, cb) {
    var cmd = [helper, "api", secretsPath, svc.key, Services.CATALOG[svc.id].auth, method, svc.url, path, svc.insecure ? "1" : "0"]
    if (body !== undefined && body !== null) cmd.push(body)
    var p = requestComponent.createObject(root, { command: cmd, done: cb })
    p.running = true
  }

  function refresh() {
    var svc = service
    if (!svc || loading[svc.key]) return
    var steps = Services.plan(svc)
    var results = {}
    var left = steps.length
    put("loading", svc.key, true)
    steps.forEach(function(step) {
      request(svc, "GET", step.path, null, function(res) {
        results[step.key] = res
        if (--left > 0) return
        put("views", svc.key, Services.parse(svc, results, root.translate, root.formatNumber))
        put("loading", svc.key, undefined)
      })
    })
  }

  function runAction(actionId, item) {
    var svc = service
    if (!svc || busyAction !== "") return
    if (actionId === "open") {
      if (item && item.data && Model.validUrl(item.data.url)) Quickshell.execDetached(["xdg-open", item.data.url])
      return
    }
    var spec = Services.actionRequest(svc, actionId, item)
    if (!spec) return
    busyAction = svc.key + "|" + actionId + "|" + (item ? item.id : "")
    notice = ""
    request(svc, spec.method, spec.path, spec.body === undefined ? null : spec.body, function(res) {
      busyAction = ""
      var ok = res.status >= 200 && res.status < 300
      if (svc.id === "navidrome" && ok) {
        try { ok = JSON.parse(res.body)["subsonic-response"].status === "ok" } catch (e) { ok = false }
      }
      noticeError = !ok
      notice = ok ? translate("notice.done") : translate("notice.failed").arg(res.status || res.error)
      noticeTimer.restart()
      // Home Assistant state flips take a moment to land.
      Qt.callLater(function() { followUp.restart() })
    })
  }

  function search(query) {
    var svc = service
    var spec = svc ? Services.searchRequest(svc, query) : null
    if (!spec || searching !== "") return
    searching = svc.key
    request(svc, "GET", spec.path, null, function(res) {
      searching = ""
      if (res.status >= 200 && res.status < 300) put("searchResults", svc.key, { query: query, items: Services.parseProwlarrSearch(res, root.translate, root.formatNumber) })
      else put("searchResults", svc.key, { query: query, items: [], error: res.status ? "HTTP " + res.status : res.error })
    })
  }

  function clearSearch() {
    if (service) put("searchResults", service.key, undefined)
  }

  function openWeb() {
    if (service && Model.validUrl(service.url)) Quickshell.execDetached(["xdg-open", service.url])
  }

  // ---------- secrets ----------

  Component {
    id: secretComponent
    Process {
      id: sp
      property string payload: ""
      property var done: null
      stdinEnabled: true
      onStarted: { write(payload + "\n"); payload = "" }
      stderr: StdioCollector { id: spErr; waitForEnd: true }
      onExited: function(code) {
        var cb = done
        done = null
        if (cb) Qt.callLater(function() { cb(code, String(spErr.text || "").trim()) })
        sp.destroy(1000)
      }
    }
  }

  function saveSecret(values) {
    var svc = service
    if (!svc) return
    var clean = {}
    var fields = Services.CATALOG[svc.id].fields
    for (var i = 0; i < fields.length; i++) {
      var v = values[fields[i].key]
      if (typeof v === "string" && v !== "") clean[fields[i].key] = v
    }
    var p = secretComponent.createObject(root, {
      command: [helper, "secret-set", secretsPath, svc.key],
      payload: JSON.stringify(clean),
      done: function(code, err) { root.afterSecret(svc, code, err) }
    })
    p.running = true
  }

  function deleteSecret() {
    var svc = service
    if (!svc) return
    var p = secretComponent.createObject(root, {
      command: [helper, "secret-del", secretsPath, svc.key],
      done: function(code, err) { root.put("views", svc.key, undefined); root.afterSecret(svc, code, err) }
    })
    p.running = true
  }

  function fetchKey() {
    var svc = service
    if (!svc || !host || svc.container === "") return
    notice = translate("notice.fetchingKey")
    noticeError = false
    var p = secretComponent.createObject(root, {
      command: [helper, "fetch-key", host.target, String(host.port), svc.container, secretsPath, svc.key],
      done: function(code, err) { root.afterSecret(svc, code, err) }
    })
    p.running = true
  }

  function afterSecret(svc, code, err) {
    noticeError = code !== 0
    notice = code === 0 ? translate("notice.saved") : Model.clip(err || ("exit " + code), 200)
    noticeTimer.restart()
    secretsFile.reload()
    if (code === 0) Qt.callLater(function() { root.put("loading", svc.key, undefined); root.refresh() })
  }

  FileView {
    id: secretsFile
    path: root.secretsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var presence = {}
      try {
        var data = JSON.parse(text() || "{}")
        for (var k in data) if (data[k] && typeof data[k] === "object") presence[k] = Object.keys(data[k])
      } catch (e) {}
      root.secretFields = presence
    }
    onLoadFailed: root.secretFields = ({})
  }

  // ---------- timers ----------

  Timer { id: noticeTimer; interval: 4000; onTriggered: root.notice = "" }
  Timer { id: followUp; interval: 800; onTriggered: root.refresh() }
  Timer {
    interval: root.refreshMs
    repeat: true
    running: root.active && root.service !== null
    onTriggered: root.refresh()
  }

  onActiveChanged: if (active) refresh()
  onServiceChanged: if (active && service && !views[service.key]) refresh()
}
