import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "Services.js" as Services
import "Proxmox.js" as Proxmox

// Homelab bar widget: a server glyph in the bar that opens a panel with one
// tab per concern (Monitoring, Docker, Links) for the selected host, plus a
// button that opens an SSH session in the default terminal.
Panel {
  id: root
  moduleName: "dadoux01.homelab"
  ipcTarget: "dadoux01.homelab"
  manageIpc: false

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/+$/, "")
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var fmt: Commons.I18n.formatNumber

  // The Proxmox tab appears only for Proxmox VE hosts.
  readonly property var tabs: lab.isPve ? ["monitoring", "proxmox", "docker", "services", "links"]
                                        : ["monitoring", "docker", "services", "links"]
  readonly property var tabMeta: ({
    monitoring: { label: "tab.monitoring", icon: "󰄨" },
    proxmox: { label: "tab.proxmox", icon: "󰒋" },
    docker: { label: "tab.docker", icon: "󰡨" },
    services: { label: "tab.services", icon: "󰒓" },
    links: { label: "tab.links", icon: "󰖟" }
  })

  // Proxmox tab search / filter state.
  property string pveQuery: ""
  property string pveState: "all"          // all | running | stopped
  property string pveKind: "all"           // all | qemu | lxc
  property bool pveTokenOpen: false
  property string pveAddKey: ""            // guest whose "add as host" form is open

  // The background watcher (Watcher.qml), loaded once by the shell as this
  // plugin's service. It may register after the bar, so keep looking.
  property var watcher: null
  function findWatcher() {
    var sh = bar ? bar.shell : null
    if (sh && typeof sh.serviceFor === "function") watcher = sh.serviceFor("dadoux01.homelab") || null
  }
  Timer {
    interval: 2000
    repeat: true
    running: root.watcher === null
    triggeredOnStart: true
    onTriggered: root.findWatcher()
  }
  readonly property int alertCount: watcher ? watcher.alertCount : 0
  readonly property int updateCount: watcher ? watcher.updateCount : 0

  // Ticks relative times ("5 min ago") while the panel is open.
  property double now: Date.now()
  Timer { interval: 30000; repeat: true; running: root.opened; onTriggered: root.now = Date.now() }

  function ago(ms) {
    if (!(ms > 0)) return strings.t("time.never")
    var sec = Math.max(0, (root.now - ms) / 1000)
    if (sec < 60) return strings.t("time.now")
    if (sec < 3600) return strings.t("time.minutes").arg(Math.floor(sec / 60))
    if (sec < 86400) return strings.t("time.hours").arg(Math.floor(sec / 3600))
    return strings.t("time.days").arg(Math.floor(sec / 86400))
  }

  function hostByKey(key) {
    for (var i = 0; i < lab.hosts.length; i++) if (lab.hosts[i].key === key) return lab.hosts[i]
    return null
  }

  function goTo(hostKey, tabName) {
    for (var i = 0; i < lab.hosts.length; i++) if (lab.hosts[i].key === hostKey) lab.selectHost(i)
    selectTab(tabName)
  }

  function hasImageUpdate(name) {
    return watcher !== null && lab.host !== null && watcher.imageUpdateFor(lab.host.key, name)
  }

  function containerAction(action, name) {
    if (action === "stop" && watcher && lab.host) watcher.expectStop(lab.host.key, name)
    lab.containerAction(action, name)
  }

  function updateAllImages() {
    if (!watcher) return
    watcher.updateList.forEach(function(u) {
      if (u.kind === "image") lab.updateContainer(u.container, hostByKey(u.hostKey))
    })
  }

  Connections {
    target: lab
    function onContainerUpdated(hostKey, name) { if (root.watcher) root.watcher.containerUpdated(hostKey, name) }
    function onPveGuestStopping(hostKey, key) { if (root.watcher) root.watcher.expectPveStop(hostKey, key) }
  }
  property bool inputFocused: false

  // Docker tab search / filter state (kept for the shell session).
  property string dockerQuery: ""
  property string dockerSort: "name"       // name | created | cpu | memory
  property bool dockerDesc: false
  property string dockerState: "all"       // all | running | stopped | updates
  property bool dockerFiltersOpen: false
  readonly property bool dockerFiltered: dockerSort !== "name" || dockerDesc || dockerState !== "all"
  property string tab: "monitoring"

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null

  onTabsChanged: if (tabs.indexOf(tab) < 0 && tab !== "alerts") tab = "monitoring"

  function selectTab(name) {
    if (tabs.indexOf(name) < 0 && name !== "alerts") return
    tab = name
    if (panelFlick) panelFlick.contentY = 0
  }

  function stepTab(direction) {
    var i = tabs.indexOf(tab)
    selectTab(tabs[(i + direction + tabs.length) % tabs.length])
  }

  function stepHost(direction) {
    var n = lab.hosts.length
    if (n > 1) lab.selectHost((lab.hostIndex + direction + n) % n)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    lab.refresh()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Strings {
    id: strings
    directory: Qt.resolvedUrl("i18n")
    language: codeFor(root.setting("language", "English"))
  }

  Service {
    id: lab
    settings: root.settings
    pluginDir: root.pluginDir
    active: root.opened
  }

  ServicesClient {
    id: svc
    host: lab.host
    docker: lab.docker
    helper: lab.helper
    secretsPath: lab.secretsPath
    active: root.opened && root.tab === "services"
    refreshMs: Math.max(lab.refreshMs, 15000)
    translate: function(k) { return strings.t(k) }
    formatNumber: root.fmt
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { lab.refresh(); if (root.watcher) root.watcher.refreshNow(); return "ok" }
    function ssh(): string { lab.openShell(); return "ok" }
    function tab(name: string): string { root.selectTab(name); return root.tab }
    function dockerFilter(sort: string, order: string, query: string): string {
      if (["name", "created", "cpu", "memory"].indexOf(sort) >= 0) root.dockerSort = sort
      root.dockerDesc = order === "desc"
      root.dockerQuery = query
      root.selectTab("docker")
      return root.dockerSort + " " + (root.dockerDesc ? "desc" : "asc")
    }
    function dockerFilters(open: bool): void { root.dockerFiltersOpen = open }
    function host(name: string): string {
      for (var i = 0; i < lab.hosts.length; i++)
        if (lab.hosts[i].name === name || lab.hosts[i].key === name || String(i + 1) === name) { lab.selectHost(i); return lab.hosts[i].name }
      return "unknown host"
    }
    function recheck(hostKey: string): string {
      if (!root.watcher) return "no watcher"
      root.watcher.checkPackages(hostKey)
      return "ok"
    }
    function service(id: string): string { root.selectTab("services"); svc.select(id); return svc.service ? svc.service.id : "" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰒋"
    labelText: root.alertCount > 0 ? String(root.alertCount) : ""
    opacity: lab.hosts.length === 0 || lab.hostError !== "" ? 0.6 : 1.0
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) lab.openShell()
      else if (buttonCode === Qt.RightButton) lab.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(760))

    content: PanelKeyCatcher {
      property alias panelFlick: panelFlick
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      blocked: root.inputFocused
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.stepTab(dx)
        else if (dy !== 0 && panelFlick.interactive)
          panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height, panelFlick.contentY + dy * Style.space(48)))
      }
      onActivateRequested: lab.openShell()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") lab.refresh()
        else if (t === "s" || t === "S") lab.openShell()
        else if (t === "e" || t === "E") lab.editConfig()
        else if (t >= "1" && t <= "9" && parseInt(t, 10) <= root.tabs.length) root.selectTab(root.tabs[parseInt(t, 10) - 1])
        else if (t === "a" || t === "A") root.selectTab("alerts")
        else if (t === "[") root.stepHost(-1)
        else if (t === "]") root.stepHost(1)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- header ----------
          PanelHero {
            id: hero
            width: parent.width
            title: lab.host ? lab.host.name : strings.t("title")
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: lab.online ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰒋"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(4)
                PanelActionButton {
                  visible: root.watcher !== null
                  iconText: root.alertCount > 0 ? "󰵙" : (root.updateCount > 0 ? "󰂞" : "󰂚")
                  tooltipText: strings.t("alerts.button").arg(root.alertCount).arg(root.updateCount)
                  foreground: root.alertCount > 0 && root.watcher && root.watcher.hasErrors ? root.urgent : root.foreground
                  fontFamily: root.fontFamily
                  bordered: root.tab === "alerts"
                  onClicked: root.selectTab(root.tab === "alerts" ? "monitoring" : "alerts")
                }
                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: strings.t("action.refresh")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: lab.host !== null && !lab.loadingMetrics
                  onClicked: lab.refresh()
                }
                PanelActionButton {
                  iconText: "󰏫"
                  tooltipText: strings.t("action.edit")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: lab.editConfig()
                }
                PanelActionButton {
                  iconText: "󰆍"
                  tooltipText: strings.t("action.ssh")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  enabled: lab.host !== null
                  onClicked: lab.openShell()
                }
              }
            }
          }

          // ---------- setup / errors ----------
          Column {
            visible: lab.configError !== ""
            width: parent.width
            spacing: Style.space(10)

            PlainText {
              width: parent.width
              text: lab.configError === "json" ? strings.t("config.invalid").arg(lab.configPath)
                  : lab.configError === "empty" ? strings.t("config.empty").arg(lab.configPath)
                  : strings.t("config.missing").arg(lab.configPath)
              color: lab.configError === "json" ? root.urgent : root.dim
              wrapMode: Text.WordWrap
            }
            Button {
              text: lab.configError === "missing" ? strings.t("config.create") : strings.t("action.edit")
              iconText: "󰏫"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: lab.editConfig()
            }
          }

          // ---------- host + tab pickers ----------
          ButtonGroup {
            visible: lab.hosts.length > 1
            width: parent.width
            options: lab.hosts.map(function(h, i) { return { value: String(i), label: h.name } })
            value: String(lab.hostIndex)
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function(v) { lab.selectHost(parseInt(v, 10)) }
          }

          ButtonGroup {
            visible: lab.host !== null
            // With five tabs, only the selected one keeps its label.
            options: root.tabs.map(function(id) {
              var meta = root.tabMeta[id]
              var compact = root.tabs.length > 4 && id !== root.tab
              return { value: id, label: compact ? "" : strings.t(meta.label), icon: meta.icon, tooltip: strings.t(meta.label) }
            })
            value: root.tab
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function(v) { root.selectTab(v) }
          }

          PanelSeparator {
            visible: lab.host !== null
            foreground: root.foreground
          }

          // ---------- Monitoring ----------
          Column {
            id: monitoring
            readonly property var m: lab.metrics
            visible: lab.host !== null && root.tab === "monitoring"
            width: parent.width
            spacing: Style.space(10)

            PlainText {
              visible: monitoring.m === null
              width: parent.width
              text: lab.hostError !== "" ? lab.hostError : strings.t("loading")
              color: lab.hostError !== "" ? root.urgent : root.dim
              wrapMode: Text.WordWrap
            }

            // Key login refused: offer to install the key from a terminal.
            Column {
              visible: monitoring.m === null && /permission denied|publickey|host key verification/i.test(lab.hostError)
              width: parent.width
              spacing: Style.space(6)
              PlainText {
                width: parent.width
                wrapMode: Text.WordWrap
                color: root.dim
                font.pixelSize: Style.font.caption
                text: strings.t("host.sshKeyHelp")
              }
              Button {
                text: strings.t("host.sshKey")
                iconText: "󰌆"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                onClicked: { lab.setupSshKey(); root.close() }
              }
            }

            Column {
              visible: monitoring.m !== null
              width: parent.width
              spacing: Style.space(10)

              // Overview: the three numbers people look at first.
              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                StatTile {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.preferredWidth: 1
                  icon: "󰻠"
                  label: strings.t("metric.cpu")
                  value: monitoring.m && monitoring.m.cpu >= 0 ? root.fmt(monitoring.m.cpu, 0) + " %" : "–"
                  sub: monitoring.m ? strings.t("metric.threads").arg(monitoring.m.cpus) : ""
                  ratio: monitoring.m && monitoring.m.cpu >= 0 ? monitoring.m.cpu / 100 : -1
                  tooltip: monitoring.m ? monitoring.m.cpuModel : ""
                }
                StatTile {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.preferredWidth: 1
                  icon: "󰍛"
                  label: strings.t("metric.memory")
                  value: monitoring.m && monitoring.m.mem ? root.fmt(Model.percent(monitoring.m.mem.used, monitoring.m.mem.total), 0) + " %" : "–"
                  sub: monitoring.m && monitoring.m.mem ? Model.bytesPair(monitoring.m.mem.used, monitoring.m.mem.total, root.fmt) : ""
                  ratio: monitoring.m && monitoring.m.mem ? monitoring.m.mem.used / monitoring.m.mem.total : -1
                }
                StatTile {
                  readonly property var hottest: monitoring.m && monitoring.m.temps.length > 0
                      ? monitoring.m.temps.reduce(function(a, b) { return b.value > a.value ? b : a }) : null
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  Layout.preferredWidth: 1
                  icon: hottest ? "󰔏" : "󰅐"
                  label: hottest ? strings.t("metric.hottest") : strings.t("metric.uptime")
                  value: hottest ? root.fmt(hottest.value, 0) + " °C" : (monitoring.m ? Model.duration(monitoring.m.uptime) : "–")
                  sub: hottest ? hottest.name : ""
                  hot: hottest !== null && hottest.value >= 80
                }
              }

              Card {
                visible: monitoring.m !== null
                title: strings.t("section.resources")
                icon: "󰘚"
                trailing: monitoring.m ? strings.t("metric.load").arg(monitoring.m.load.map(function(v) { return root.fmt(v, 2) }).join("  ")) : ""

                Meter {
                  visible: monitoring.m && monitoring.m.swap !== null
                  label: strings.t("metric.swap")
                  ratio: monitoring.m && monitoring.m.swap ? monitoring.m.swap.used / monitoring.m.swap.total : 0
                  value: monitoring.m && monitoring.m.swap ? Model.bytesPair(monitoring.m.swap.used, monitoring.m.swap.total, root.fmt) : ""
                }
                Repeater {
                  model: monitoring.m ? monitoring.m.gpus : []
                  Meter {
                    required property var modelData
                    label: strings.t("metric.gpu")
                    tooltip: modelData.name
                    detail: (modelData.memTotal > 0 ? strings.t("metric.vram").arg(Model.bytes(modelData.memUsed, root.fmt)).arg(Model.bytes(modelData.memTotal, root.fmt)) : "")
                          + (modelData.temp >= 0 ? "  ·  " + root.fmt(modelData.temp, 0) + " °C" : "")
                    ratio: modelData.util / 100
                    value: root.fmt(modelData.util, 0) + " %"
                  }
                }
                InfoPair { visible: monitoring.m && monitoring.m.net !== null; label: strings.t("metric.network"); value: monitoring.m && monitoring.m.net ? "↓ " + Model.rate(monitoring.m.net.rx, root.fmt) + "   ↑ " + Model.rate(monitoring.m.net.tx, root.fmt) : "" }
              }

              Card {
                visible: monitoring.m && monitoring.m.disks.length > 0
                title: strings.t("section.storage")
                icon: "󰋊"
                trailing: monitoring.m ? strings.t("metric.disks").arg(monitoring.m.disks.length) : ""

                Repeater {
                  model: monitoring.m ? monitoring.m.disks : []
                  Meter {
                    required property var modelData
                    label: modelData.mount
                    ratio: modelData.used / modelData.total
                    value: Model.bytesPair(modelData.used, modelData.total, root.fmt)
                  }
                }
              }

              Card {
                visible: monitoring.m && monitoring.m.temps.length > 1
                title: strings.t("section.sensors")
                icon: "󰔏"

                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    model: monitoring.m ? monitoring.m.temps : []
                    Chip {
                      required property var modelData
                      text: modelData.name + "  " + root.fmt(modelData.value, 0) + " °C"
                      hot: modelData.value >= 80
                    }
                  }
                }
              }

              Card {
                title: strings.t("section.system")
                icon: "󰌢"
                trailing: monitoring.m ? strings.t("metric.upFor").arg(Model.duration(monitoring.m.uptime)) : ""

                InfoPair { visible: monitoring.m && monitoring.m.os !== ""; label: strings.t("metric.os"); value: monitoring.m ? monitoring.m.os : "" }
                InfoPair { label: strings.t("metric.kernel"); value: monitoring.m ? monitoring.m.kernel : "" }
                InfoPair { visible: monitoring.m && monitoring.m.cpuModel !== ""; label: strings.t("metric.cpu"); value: monitoring.m ? monitoring.m.cpuModel : "" }
              }

              Card {
                visible: root.watcher !== null
                title: strings.t("packages.title")
                icon: "󰏔"
                PackagesSection { width: parent.width }
              }

              PlainText {
                visible: lab.hostError !== ""
                width: parent.width
                text: lab.hostError
                color: root.urgent
                wrapMode: Text.WordWrap
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------- Docker ----------
          Column {
            id: dockerTab
            readonly property var d: lab.docker
            readonly property int running: d ? d.containers.filter(function(c) { return c.state === "running" }).length : 0
            readonly property var shown: {
              if (!d) return []
              var list = d.containers
              if (root.dockerState === "updates") list = list.filter(function(c) { return root.hasImageUpdate(c.name) })
              return Model.filterContainers(list, root.dockerQuery, root.dockerState === "updates" ? "all" : root.dockerState, root.dockerSort, root.dockerDesc)
            }
            visible: lab.host !== null && root.tab === "docker"
            width: parent.width
            spacing: Style.space(8)

            PlainText {
              visible: dockerTab.d === null || dockerTab.d.error !== "" || dockerTab.d.containers.length === 0
              width: parent.width
              wrapMode: Text.WordWrap
              color: dockerTab.d && dockerTab.d.error !== "" ? root.urgent : root.dim
              text: dockerTab.d === null ? strings.t("loading")
                  : dockerTab.d.error !== "" ? strings.t("docker.error." + dockerTab.d.error)
                  : strings.t("docker.none")
            }

            // Counts double as quick filters.
            RowLayout {
              readonly property int total: dockerTab.d ? dockerTab.d.containers.length : 0
              readonly property int updates: dockerTab.d ? dockerTab.d.containers.filter(function(c) { return root.hasImageUpdate(c.name) }).length : 0
              visible: total > 0
              width: parent.width
              spacing: Style.space(8)
              StatTile {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                icon: "󰐊"
                label: strings.t("docker.state.running")
                value: dockerTab.running + " / " + parent.total
                clickable: true
                selected: root.dockerState === "running"
                onClicked: root.dockerState = root.dockerState === "running" ? "all" : "running"
              }
              StatTile {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                icon: "󰓛"
                label: strings.t("docker.state.stopped")
                value: String(parent.total - dockerTab.running)
                hot: false
                clickable: true
                selected: root.dockerState === "stopped"
                onClicked: root.dockerState = root.dockerState === "stopped" ? "all" : "stopped"
              }
              StatTile {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                icon: "󰚰"
                label: strings.t("docker.state.updates")
                value: String(parent.updates)
                clickable: true
                selected: root.dockerState === "updates"
                onClicked: root.dockerState = root.dockerState === "updates" ? "all" : "updates"
              }
            }

            PlainText {
              visible: lab.loadingDocker || (dockerTab.d !== null && dockerTab.shown.length !== dockerTab.d.containers.length)
              width: parent.width
              color: root.dim
              font.pixelSize: Style.font.caption
              text: [dockerTab.d && dockerTab.shown.length !== dockerTab.d.containers.length ? strings.t("docker.shown").arg(dockerTab.shown.length) : "",
                     lab.loadingDocker ? strings.t("loading") : ""].filter(function(x) { return x !== "" }).join("  ·  ")
            }

            // Search + filter button
            RowLayout {
              visible: dockerTab.d !== null && dockerTab.d.containers.length > 0
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: dockerSearch
                Layout.fillWidth: true
                text: root.dockerQuery
                placeholderText: strings.t("docker.searchPlaceholder")
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                foreground: root.foreground
                horizontalPadding: Style.spacing.controlGap
                verticalPadding: Style.spacing.controlPaddingY
                onTextChanged: if (text !== root.dockerQuery) root.dockerQuery = text
                onActiveFocusChanged: root.inputFocused = activeFocus
                Keys.onEscapePressed: {
                  if (text !== "") text = ""
                  else { focus = false; if (panel.loadedContent) panel.loadedContent.forceActiveFocus() }
                }
              }
              PanelActionButton {
                iconText: "󰈲"
                tooltipText: strings.t("docker.filter")
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: root.dockerFiltersOpen || root.dockerFiltered
                onClicked: root.dockerFiltersOpen = !root.dockerFiltersOpen
              }
            }

            // Filter options
            Column {
              visible: root.dockerFiltersOpen && dockerTab.d !== null
              width: parent.width
              spacing: Style.space(8)
              topPadding: Style.space(4)
              bottomPadding: Style.space(6)

              FilterLabel { text: strings.t("docker.sortBy") }
              ButtonGroup {
                options: [
                  { value: "name", label: strings.t("docker.sort.name") },
                  { value: "created", label: strings.t("docker.sort.created") },
                  { value: "cpu", label: strings.t("docker.sort.cpu") },
                  { value: "memory", label: strings.t("docker.sort.memory") }
                ]
                value: root.dockerSort
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                focusable: false
                onChanged: function(v) { root.dockerSort = v }
              }

              FilterLabel { text: strings.t("docker.order") }
              ButtonGroup {
                options: [
                  { value: "asc", label: strings.t("docker.order.asc"), icon: "󰒼" },
                  { value: "desc", label: strings.t("docker.order.desc"), icon: "󰒽" }
                ]
                value: root.dockerDesc ? "desc" : "asc"
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                focusable: false
                onChanged: function(v) { root.dockerDesc = v === "desc" }
              }

              FilterLabel { text: strings.t("docker.stateFilter") }
              ButtonGroup {
                options: [
                  { value: "all", label: strings.t("docker.state.all") },
                  { value: "running", label: strings.t("docker.state.running") },
                  { value: "stopped", label: strings.t("docker.state.stopped") },
                  { value: "updates", label: strings.t("docker.state.updates") }
                ]
                value: root.dockerState
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                focusable: false
                onChanged: function(v) { root.dockerState = v }
              }

              Button {
                visible: root.dockerFiltered || root.dockerQuery !== ""
                text: strings.t("docker.resetFilters")
                iconText: "󰑐"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: {
                  root.dockerSort = "name"
                  root.dockerDesc = false
                  root.dockerState = "all"
                  root.dockerQuery = ""
                }
              }

              PanelSeparator { foreground: root.foreground }
            }

            PlainText {
              visible: dockerTab.d !== null && dockerTab.d.containers.length > 0 && dockerTab.shown.length === 0
              width: parent.width
              color: root.dim
              text: strings.t("docker.noMatch")
            }

            PlainText {
              visible: lab.actionError !== ""
              width: parent.width
              text: lab.actionError
              color: root.urgent
              wrapMode: Text.WordWrap
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: dockerTab.shown
              ContainerRow {
                required property var modelData
                width: dockerTab.width
                container: modelData
              }
            }
          }

          // ---------- Proxmox ----------
          ProxmoxView {
            visible: lab.host !== null && root.tab === "proxmox"
            width: parent.width
          }

          // ---------- Alerts & updates ----------
          AlertsView {
            visible: root.tab === "alerts"
            width: parent.width
          }

          // ---------- Services ----------
          ServicesView {
            visible: lab.host !== null && root.tab === "services"
            width: parent.width
          }

          // ---------- Links ----------
          Column {
            id: linksTab
            visible: lab.host !== null && root.tab === "links"
            width: parent.width
            spacing: Style.space(8)

            PlainText {
              visible: lab.host !== null && lab.host.links.length === 0
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              text: strings.t("links.none").arg(lab.configPath)
            }

            Repeater {
              model: lab.host ? lab.host.links : []
              LinkRow {
                required property var modelData
                width: linksTab.width
                link: modelData
              }
            }
          }
        }
      }
    }
  }

  function heroMeta() {
    if (!lab.host) return strings.t("subtitle")
    if (lab.hostError !== "") return strings.t("status.offline")
    var m = lab.metrics
    if (!m) return lab.host.target
    if (m.hostname === "" || m.hostname === lab.host.target) return lab.host.target
    return m.hostname + "  ·  " + lab.host.target
  }

  // ---------- components ----------

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: wrapMode === Text.NoWrap ? Text.ElideRight : Text.ElideNone
  }

  // Label and value on one line, optional detail under the label, then a
  // thin bar in the theme accent (urgent past 90 %).
  component Meter: Column {
    id: meter
    property string label: ""
    property string detail: ""
    property string value: ""
    property string tooltip: ""
    property real ratio: 0
    readonly property real clamped: Math.max(0, Math.min(1, isFinite(ratio) ? ratio : 0))
    readonly property color tint: clamped >= 0.9 ? root.urgent : root.foreground

    width: parent ? parent.width : 0
    spacing: Style.space(5)

    RowLayout {
      width: parent.width
      spacing: Style.space(8)
      PlainText {
        Layout.fillWidth: true
        text: meter.label
        font.pixelSize: Style.font.body
      }
      PlainText {
        text: meter.value
        color: meter.clamped >= 0.9 ? root.urgent : root.foreground
        font.pixelSize: Style.font.bodySmall
      }
    }
    PlainText {
      visible: meter.detail !== ""
      width: parent.width
      text: meter.detail
      color: root.dim
      font.pixelSize: Style.font.caption
    }

    Bar { width: parent.width; ratio: meter.clamped; tint: meter.tint }

    HoverHandler { id: meterHover }
    PanelToolTip {
      visible: meter.tooltip !== "" && meterHover.hovered
      text: meter.tooltip
      fontFamily: root.fontFamily
    }
  }

  component Bar: Rectangle {
    id: bar
    property real ratio: 0
    property color tint: root.foreground
    height: Style.space(4)
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
    Rectangle {
      width: bar.ratio > 0 ? Math.max(bar.height, bar.width * Math.min(1, bar.ratio)) : 0
      height: parent.height
      radius: parent.radius
      color: bar.tint
      Behavior on width { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
    }
  }

  // A grouped block on the shell's own control surface: same fill, border
  // and corner radius as the theme's buttons, so it follows every theme.
  component Card: BorderSurface {
    id: card
    default property alias content: cardBody.data
    property string title: ""
    property string icon: ""
    property string trailing: ""
    property color trailingColor: root.dim

    width: parent ? parent.width : 0
    implicitHeight: cardBody.implicitHeight + padding * 2
    padding: Style.spacing.xxxl
    color: Style.normalFillFor(root.foreground)
    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
    radius: Style.cornerRadius

    Column {
      id: cardBody
      x: card.padding
      y: card.padding
      width: card.width - card.padding * 2
      spacing: Style.space(10)

      SectionTitle {
        visible: card.title !== ""
        width: parent.width
        title: card.title
        icon: card.icon
        trailing: card.trailing
        trailingColor: card.trailingColor
      }
    }
  }

  // Icon + bold title + right-hand note, as used on top of cards and lists.
  component SectionTitle: RowLayout {
    id: st
    property string title: ""
    property string icon: ""
    property string trailing: ""
    property color trailingColor: root.dim
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    PlainText {
      visible: st.icon !== ""
      text: st.icon
      color: root.accent
      font.pixelSize: Style.font.icon
    }
    PlainText {
      Layout.fillWidth: true
      text: st.title
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }
    PlainText {
      visible: st.trailing !== ""
      text: st.trailing
      color: st.trailingColor
      font.pixelSize: Style.font.caption
    }
  }

  // Small rounded label for a state ("update", "healthy", "stopped").
  component StatusPill: Rectangle {
    id: pill
    property string text: ""
    property color tint: root.foreground
    implicitWidth: pillText.implicitWidth + Style.space(12)
    implicitHeight: pillText.implicitHeight + Style.space(4)
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.14)
    PlainText {
      id: pillText
      anchors.centerIn: parent
      text: pill.text
      color: pill.tint
      font.pixelSize: Style.font.caption
    }
  }

  // A list entry drawn as its own small card; the hover state is the
  // shell's own cursor fill and border.
  component ItemCard: CursorSurface {
    foreground: root.foreground
    color: hasCursor ? fill : Style.normalFillFor(root.foreground)
    borderSpec: Border.controlSpec(hasCursor ? "hover" : "normal", root.foreground, root.accent)
  }

  // Square glyph badge on the left of list entries.
  component IconTile: Rectangle {
    id: iconTile
    property string glyph: ""
    property color tint: root.foreground
    implicitWidth: Style.space(32)
    implicitHeight: implicitWidth
    radius: Style.cornerRadius
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.10)
    PlainText {
      anchors.centerIn: parent
      text: iconTile.glyph
      color: iconTile.tint
      font.pixelSize: Style.font.icon
    }
  }

  // One headline number with its label, a short detail and a bar.
  // Clickable tiles act as filters.
  component StatTile: BorderSurface {
    id: tile
    signal clicked()
    property bool clickable: false
    property bool selected: false
    property string icon: ""
    property string label: ""
    property string value: ""
    property string sub: ""
    property string tooltip: ""
    property real ratio: -1
    property bool hot: ratio >= 0.9
    implicitHeight: tileBody.implicitHeight + padding * 2
    padding: Style.spacing.xxl
    color: tile.selected ? Style.selectedFillFor(root.foreground, root.accent) : (tileHover.hovered && tile.clickable ? Style.hoverFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground))
    borderSpec: Border.controlSpec(tile.selected ? "selected" : (tileHover.hovered && tile.clickable ? "hover" : "normal"), root.foreground, root.accent)
    radius: Style.cornerRadius

    MouseArea {
      anchors.fill: parent
      enabled: tile.clickable
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }

    Column {
      id: tileBody
      x: tile.padding
      y: tile.padding
      width: tile.width - tile.padding * 2
      spacing: Style.space(4)
      RowLayout {
        width: parent.width
        spacing: Style.space(6)
        PlainText { text: tile.icon; color: root.accent; font.pixelSize: Style.font.bodySmall }
        PlainText { Layout.fillWidth: true; text: tile.label; color: root.dim; font.pixelSize: Style.font.caption }
      }
      PlainText {
        width: parent.width
        text: tile.value
        color: tile.hot ? root.urgent : root.foreground
        font.pixelSize: Style.font.display
        font.bold: true
      }
      PlainText {
        visible: tile.sub !== ""
        width: parent.width
        text: tile.sub
        color: root.dim
        font.pixelSize: Style.font.caption
      }
      Bar {
        visible: tile.ratio >= 0
        width: parent.width
        ratio: tile.ratio
        tint: tile.hot ? root.urgent : root.foreground
      }
    }

    HoverHandler { id: tileHover }
    PanelToolTip {
      visible: tile.tooltip !== "" && tileHover.hovered
      text: tile.tooltip
      fontFamily: root.fontFamily
    }
  }

  component FilterLabel: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Chip: Rectangle {
    id: chip
    property string text: ""
    property bool hot: false
    implicitWidth: chipText.implicitWidth + Style.space(16)
    implicitHeight: chipText.implicitHeight + Style.space(6)
    radius: Style.space(4)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
    border.width: 1
    border.color: chip.hot ? root.urgent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
    PlainText {
      id: chipText
      anchors.centerIn: parent
      text: chip.text
      color: chip.hot ? root.urgent : root.foreground
      font.pixelSize: Style.font.caption
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    PlainText { id: pairLabel; text: label; opacity: 0.6 }
    PlainText {
      width: parent.width - pairLabel.implicitWidth - parent.spacing
      horizontalAlignment: Text.AlignRight
      text: value
    }
  }

  component ServicesView: Column {
    id: sv
    readonly property var service: svc.service
    readonly property var vm: svc.view
    readonly property var cat: svc.catalog
    readonly property bool needsSecret: service !== null && (!svc.hasSecret(service) || (vm !== null && vm.state === "auth"))
    property bool editing: false
    readonly property bool showForm: service !== null && (needsSecret || editing)
    readonly property var search: service ? (svc.searchResults[service.key] || null) : null

    spacing: Style.space(10)
    onServiceChanged: editing = false

    PlainText {
      visible: svc.services.length === 0
      width: parent.width
      wrapMode: Text.WordWrap
      color: root.dim
      text: lab.docker === null ? strings.t("loading") : strings.t("services.none")
    }

    // Picker + service header
    RowLayout {
      visible: sv.service !== null
      width: parent.width
      spacing: Style.space(6)

      Dropdown {
        Layout.fillWidth: true
        showLabel: false
        options: svc.services.map(function(x) { return { value: x.id, label: x.name } })
        value: sv.service ? sv.service.id : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChanged: function(v) { svc.select(v) }
      }
      PanelActionButton {
        iconText: "󰑐"
        tooltipText: strings.t("action.refresh")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !svc.isLoading
        opacity: svc.isLoading ? 0.4 : 1
        onClicked: svc.refresh()
      }
      PanelActionButton {
        iconText: "󰌆"
        tooltipText: strings.t("service.credentials")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: sv.editing = !sv.editing
      }
      PanelActionButton {
        iconText: "󰏌"
        tooltipText: strings.t("action.openWeb")
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: { svc.openWeb(); root.close() }
      }
    }

    PlainText {
      visible: sv.service !== null
      width: parent.width
      color: root.dim
      font.pixelSize: Style.font.caption
      text: {
        if (!sv.service) return ""
        var parts = [sv.service.url]
        if (sv.vm && sv.vm.version !== "") parts.push("v" + sv.vm.version)
        if (!sv.service.running) parts.push(strings.t("services.stopped"))
        else if (sv.vm && sv.vm.state === "ok") parts.push(strings.t("status.online"))
        if (svc.isLoading) parts.push(strings.t("loading"))
        return parts.join("  ·  ")
      }
    }

    PlainText {
      visible: svc.notice !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      text: svc.notice
      color: svc.noticeError ? root.urgent : root.foreground
    }

    // Credentials form
    Card {
      visible: sv.showForm
      title: strings.t("service.credentials")
      icon: "󰌆"

      PlainText {
        width: parent.width
        wrapMode: Text.WordWrap
        color: sv.vm && sv.vm.state === "auth" && svc.hasSecret(sv.service) ? root.urgent : root.dim
        text: (sv.vm && sv.vm.state === "auth" && svc.hasSecret(sv.service) ? strings.t("service.rejected") + " " : "")
            + (sv.cat ? strings.t(sv.cat.help) : "")
      }

      Repeater {
        id: fieldRepeater
        model: sv.cat ? sv.cat.fields : []
        TextField {
          required property var modelData
          width: parent.width
          password: modelData.password
          placeholderText: strings.t(modelData.label)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          foreground: root.foreground
          horizontalPadding: Style.spacing.controlGap
          verticalPadding: Style.spacing.controlPaddingY
          onActiveFocusChanged: root.inputFocused = activeFocus
          onAccepted: sv.submit()
          Keys.onEscapePressed: { text = ""; sv.editing = false; focus = false }
        }
      }

      Flow {
        width: parent.width
        spacing: Style.space(6)
        Button {
          text: strings.t("service.save")
          iconText: "󰆓"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: sv.submit()
        }
        Button {
          visible: sv.cat !== null && sv.cat.fetchKey === true && sv.service.container !== ""
          text: strings.t("service.fetchKey")
          iconText: "󰆍"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: { svc.fetchKey(); sv.editing = false }
        }
        Button {
          visible: svc.hasSecret(sv.service)
          text: strings.t("service.forget")
          iconText: "󰩺"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: { svc.deleteSecret(); sv.editing = false }
        }
      }
    }

    function submit() {
      var values = {}
      for (var i = 0; i < fieldRepeater.count; i++) {
        var f = fieldRepeater.itemAt(i)
        values[f.modelData.key] = f.text
      }
      svc.saveSecret(values)
      for (var j = 0; j < fieldRepeater.count; j++) fieldRepeater.itemAt(j).text = ""
      root.inputFocused = false
      editing = false
      if (panel.loadedContent) panel.loadedContent.forceActiveFocus()
    }

    PlainText {
      visible: sv.vm !== null && (sv.vm.state === "down" || sv.vm.state === "error") && !sv.showForm
      width: parent.width
      wrapMode: Text.WordWrap
      color: root.urgent
      text: sv.vm ? sv.vm.error : ""
    }

    // Overview
    Column {
      visible: sv.vm !== null && sv.vm.state === "ok" && !sv.showForm
      width: parent.width
      spacing: Style.space(10)

      Repeater {
        model: sv.vm ? sv.vm.alerts : []
        PlainText {
          required property var modelData
          width: parent.width
          wrapMode: Text.WordWrap
          color: modelData.level === "error" ? root.urgent : root.foreground
          text: "󰀦  " + modelData.text
        }
      }

      GridLayout {
        visible: sv.vm !== null && sv.vm.stats.length > 0
        width: parent.width
        columns: 3
        columnSpacing: Style.space(8)
        rowSpacing: Style.space(8)
        Repeater {
          model: sv.vm ? sv.vm.stats : []
          StatTile {
            required property var modelData
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            label: modelData.label
            value: modelData.value
          }
        }
      }

      Flow {
        visible: sv.vm !== null && sv.vm.actions.length > 0
        width: parent.width
        spacing: Style.space(6)
        Repeater {
          model: sv.vm ? sv.vm.actions : []
          Button {
            required property var modelData
            text: modelData.label
            iconText: modelData.icon
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: svc.busyAction === ""
            opacity: svc.busyAction.indexOf(sv.service.key + "|" + modelData.id + "|") === 0 ? 0.5 : 1
            onClicked: svc.runAction(modelData.id, modelData)
          }
        }
      }

      // Local filter (Home Assistant entities)
      TextField {
        id: filterField
        visible: sv.cat !== null && sv.cat.filter === true
        width: parent.width
        placeholderText: sv.cat && sv.cat.filterPlaceholder ? strings.t(sv.cat.filterPlaceholder) : ""
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        foreground: root.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        onActiveFocusChanged: root.inputFocused = activeFocus
        onTextChanged: filterDebounce.restart()
        Keys.onEscapePressed: { if (text !== "") text = ""; else { focus = false; if (panel.loadedContent) panel.loadedContent.forceActiveFocus() } }
        Timer { id: filterDebounce; interval: 200; onTriggered: svc.setFilter(filterField.text) }
        Connections {
          target: sv
          function onServiceChanged() { filterField.text = svc.filter }
        }
      }

      // Prowlarr search
      Column {
        visible: sv.cat !== null && sv.cat.search === true
        width: parent.width
        spacing: Style.space(6)

        RowLayout {
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: strings.t("prowlarr.searchPlaceholder")
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onActiveFocusChanged: root.inputFocused = activeFocus
            onAccepted: svc.search(text)
            Keys.onEscapePressed: { if (text !== "") { text = ""; svc.clearSearch() } else { focus = false; if (panel.loadedContent) panel.loadedContent.forceActiveFocus() } }
          }
          PanelActionButton {
            iconText: "󰍉"
            tooltipText: strings.t("prowlarr.search")
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: svc.searching === ""
            onClicked: svc.search(searchField.text)
          }
        }

        PlainText {
          visible: svc.searching !== "" || (sv.search !== null && (sv.search.items.length === 0 || sv.search.error))
          width: parent.width
          color: sv.search && sv.search.error ? root.urgent : root.dim
          font.pixelSize: Style.font.caption
          text: svc.searching !== "" ? strings.t("prowlarr.searching")
              : sv.search && sv.search.error ? sv.search.error
              : strings.t("prowlarr.noResults")
        }

        Repeater {
          model: sv.search && svc.searching === "" ? sv.search.items : []
          ServiceItemRow {
            required property var modelData
            width: sv.width
            item: modelData
          }
        }
      }

      Repeater {
        model: sv.vm ? sv.vm.sections : []
        Card {
          required property var modelData
          width: sv.width
          title: modelData.title
          trailing: modelData.items.length > 0 ? String(modelData.items.length) : ""

          PlainText {
            visible: modelData.items.length === 0
            width: parent.width
            color: root.dim
            text: modelData.empty || ""
          }
          Repeater {
            model: modelData.items
            ServiceItemRow {
              required property var modelData
              width: parent.width
              item: modelData
            }
          }
        }
      }
    }
  }

  component ServiceItemRow: CursorSurface {
    id: itemRow
    property var item: null
    readonly property bool busy: item !== null && svc.service !== null && svc.busyAction.indexOf(svc.service.key + "|") === 0
                                 && svc.busyAction.slice(svc.busyAction.length - item.id.length - 1) === "|" + item.id
    readonly property var slider: item && item.slider ? item.slider : null

    foreground: root.foreground
    hasCursor: itemMouse.containsMouse
    implicitHeight: itemLayout.implicitHeight + Style.spacing.rowPaddingX
    opacity: busy ? 0.5 : 1

    MouseArea {
      id: itemMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: itemRow.item && itemRow.item.activate ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (itemRow.item && itemRow.item.activate) svc.runAction(itemRow.item.activate, itemRow.item)
    }

    RowLayout {
      id: itemLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Image {
        id: poster
        visible: source != "" && status === Image.Ready
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(30)
        Layout.preferredHeight: Style.space(44)
        source: itemRow.item && itemRow.item.image ? itemRow.item.image : ""
        sourceSize.height: 96
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
      }

      Rectangle {
        visible: !poster.visible && itemRow.item !== null && itemRow.item.on !== undefined
        Layout.alignment: Qt.AlignVCenter
        width: Style.space(8)
        height: width
        radius: width / 2
        color: itemRow.item && itemRow.item.on ? root.foreground : "transparent"
        border.width: 1
        border.color: root.foreground
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          PlainText {
            Layout.fillWidth: true
            text: itemRow.item ? itemRow.item.title : ""
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
          PlainText {
            visible: text !== ""
            text: itemRow.item ? itemRow.item.meta : ""
            color: itemRow.item && itemRow.item.warn ? root.urgent : root.dim
            font.pixelSize: Style.font.caption
          }
        }
        PlainText {
          visible: text !== ""
          Layout.fillWidth: true
          text: itemRow.item ? (itemRow.item.subtitle || "") : ""
          color: itemRow.item && itemRow.item.warn ? root.urgent : root.dim
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Rectangle {
          visible: itemRow.item !== null && itemRow.item.progress >= 0
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
          height: Style.space(4)
          radius: Style.cornerRadius > 0 ? height / 2 : 0
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          Rectangle {
            width: parent.width * Math.max(0, Math.min(1, itemRow.item ? itemRow.item.progress : 0))
            height: parent.height
            radius: parent.radius
            color: itemRow.item && itemRow.item.warn ? root.urgent : root.foreground
            opacity: 0.8
          }
        }
        RowLayout {
          visible: itemRow.slider !== null
          Layout.fillWidth: true
          spacing: Style.space(6)
          PanelSlider {
            id: itemSlider
            Layout.fillWidth: true
            bar: root.bar
            minimum: itemRow.slider ? itemRow.slider.min : 0
            maximum: itemRow.slider ? itemRow.slider.max : 1
            step: itemRow.slider ? itemRow.slider.step : 1
            integer: itemRow.slider ? itemRow.slider.step >= 1 : true
            value: itemRow.slider ? itemRow.slider.value : 0
            enabled: svc.busyAction === ""
            onReleased: function(v) { if (itemRow.slider) svc.runAction(itemRow.slider.id, itemRow.item, v) }
          }
          PlainText {
            Layout.minimumWidth: Style.space(44)
            horizontalAlignment: Text.AlignRight
            color: root.dim
            font.pixelSize: Style.font.caption
            text: itemRow.slider ? root.fmt(itemSlider.liveValue, itemRow.slider.decimals || 0) + itemRow.slider.unit : ""
          }
        }
      }

      Repeater {
        model: itemRow.item ? itemRow.item.actions : []
        PanelActionButton {
          required property var modelData
          iconText: modelData.icon
          tooltipText: modelData.tooltip
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: modelData.active === true
          enabled: svc.busyAction === ""
          onClicked: svc.runAction(modelData.id, itemRow.item)
        }
      }
    }
  }

  component ProxmoxView: Column {
    id: px
    readonly property var p: lab.pve
    readonly property bool ok: p !== null && p.error === ""
    readonly property var access: lab.metrics && lab.metrics.pve ? lab.metrics.pve.access : ""
    readonly property bool showToken: root.pveTokenOpen || (p !== null && (p.error === "noaccess" || p.error === "auth"))
    readonly property var shown: ok ? Proxmox.filterGuests(p.guests, root.pveQuery, root.pveState, root.pveKind) : []
    readonly property int vmsRunning: ok ? p.guests.filter(function(g) { return g.type === "qemu" && g.running }).length : 0
    readonly property int vms: ok ? p.guests.filter(function(g) { return g.type === "qemu" }).length : 0
    readonly property int ctsRunning: ok ? p.guests.filter(function(g) { return g.type === "lxc" && g.running }).length : 0
    readonly property int cts: ok ? p.guests.filter(function(g) { return g.type === "lxc" }).length : 0

    spacing: Style.space(8)

    // Header: version, transport, actions
    RowLayout {
      width: parent.width
      spacing: Style.space(6)
      PlainText {
        Layout.fillWidth: true
        color: root.dim
        font.pixelSize: Style.font.caption
        text: {
          var parts = ["Proxmox VE" + (px.p && px.p.version ? " " + px.p.version : (lab.metrics && lab.metrics.pve ? " " + lab.metrics.pve.version : ""))]
          if (px.p && px.p.via !== "") parts.push(strings.t("pve.via." + px.p.via))
          if (lab.loadingPve) parts.push(strings.t("loading"))
          else if (px.p) parts.push(root.ago(px.p.checkedAt))
          return parts.join("  ·  ")
        }
      }
      PanelActionButton {
        iconText: "󰑐"
        tooltipText: strings.t("action.refresh")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !lab.loadingPve
        onClicked: lab.refreshPve()
      }
      PanelActionButton {
        iconText: "󰌆"
        tooltipText: strings.t("pve.token")
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: root.pveTokenOpen
        onClicked: root.pveTokenOpen = !root.pveTokenOpen
      }
      PanelActionButton {
        iconText: "󰏌"
        tooltipText: strings.t("pve.openWeb")
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: { lab.openPveWeb(); root.close() }
      }
    }

    PlainText {
      visible: px.p === null && !lab.loadingPve
      width: parent.width
      color: root.dim
      text: strings.t("loading")
    }

    // Access problems and API token form
    PlainText {
      visible: px.p !== null && px.p.error !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      color: root.urgent
      text: px.p ? strings.t("pve.error." + px.p.error) : ""
    }

    Column {
      visible: px.showToken
      width: parent.width
      spacing: Style.space(6)

      PlainText {
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.dim
        font.pixelSize: Style.font.caption
        text: strings.t("pve.tokenHelp")
      }
      TextField {
        id: pveTokenId
        width: parent.width
        placeholderText: strings.t("pve.tokenId")
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        foreground: root.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        onActiveFocusChanged: root.inputFocused = activeFocus
        onAccepted: pveTokenSecret.forceActiveFocus()
      }
      TextField {
        id: pveTokenSecret
        width: parent.width
        password: true
        placeholderText: strings.t("pve.tokenSecret")
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        foreground: root.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        onActiveFocusChanged: root.inputFocused = activeFocus
        onAccepted: px.saveToken()
      }
      Flow {
        width: parent.width
        spacing: Style.space(6)
        Button {
          text: strings.t("service.save")
          iconText: "󰆓"
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: px.saveToken()
        }
        Button {
          visible: px.p !== null && px.p.via === "token"
          text: strings.t("pve.forgetToken")
          iconText: "󰩺"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: { lab.forgetPveToken(); root.pveTokenOpen = false }
        }
      }
      PlainText {
        visible: lab.pveNotice !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        font.pixelSize: Style.font.caption
        color: lab.pveNotice === "saved" ? root.foreground : root.urgent
        text: lab.pveNotice === "saved" ? strings.t("notice.saved") : lab.pveNotice
      }
    }

    function saveToken() {
      if (pveTokenId.text.trim() === "" || pveTokenSecret.text.trim() === "") return
      lab.savePveToken(pveTokenId.text, pveTokenSecret.text)
      pveTokenSecret.text = ""
      root.inputFocused = false
      root.pveTokenOpen = false
      if (panel.loadedContent) panel.loadedContent.forceActiveFocus()
    }

    Column {
      visible: px.ok
      width: parent.width
      spacing: Style.space(8)

      // Counts; the VM and LXC tiles filter the list below.
      RowLayout {
        width: parent.width
        spacing: Style.space(8)
        StatTile {
          readonly property int online: px.ok ? px.p.nodes.filter(function(n) { return n.online }).length : 0
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 1
          icon: "󰒋"
          label: strings.t("pve.nodes")
          value: online + " / " + (px.ok ? px.p.nodes.length : 0)
          hot: px.ok && online < px.p.nodes.length
        }
        StatTile {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 1
          icon: "󰍹"
          label: strings.t("pve.vms")
          value: px.vmsRunning + " / " + px.vms
          clickable: true
          selected: root.pveKind === "qemu"
          onClicked: root.pveKind = root.pveKind === "qemu" ? "all" : "qemu"
        }
        StatTile {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 1
          icon: "󰆧"
          label: strings.t("pve.cts")
          value: px.ctsRunning + " / " + px.cts
          clickable: true
          selected: root.pveKind === "lxc"
          onClicked: root.pveKind = root.pveKind === "lxc" ? "all" : "lxc"
        }
      }

      PlainText {
        visible: lab.pveActionError !== ""
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.urgent
        font.pixelSize: Style.font.caption
        text: lab.pveActionError
      }

      Card {
        title: strings.t("pve.nodes")
        icon: "󰒋"
        trailing: strings.t("pve.memory")
        Repeater {
          model: px.ok ? px.p.nodes : []
          Meter {
            required property var modelData
            label: (modelData.online ? "" : "󰅚 ") + modelData.name
            detail: modelData.online ? strings.t("pve.nodeDetail").arg(root.fmt(modelData.cpu * 100, 0)).arg(Model.duration(modelData.uptime)) : strings.t("pve.offline")
            ratio: modelData.maxmem > 0 ? modelData.mem / modelData.maxmem : 0
            value: Model.bytesPair(modelData.mem, modelData.maxmem, root.fmt)
          }
        }
      }

      // Guests: search + filters
      TextField {
        width: parent.width
        text: root.pveQuery
        placeholderText: strings.t("pve.searchPlaceholder")
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        foreground: root.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        onTextChanged: if (text !== root.pveQuery) root.pveQuery = text
        onActiveFocusChanged: root.inputFocused = activeFocus
        Keys.onEscapePressed: {
          if (text !== "") text = ""
          else { focus = false; if (panel.loadedContent) panel.loadedContent.forceActiveFocus() }
        }
      }
      Flow {
        width: parent.width
        spacing: Style.space(10)
        ButtonGroup {
          options: [
            { value: "all", label: strings.t("docker.state.all") },
            { value: "running", label: strings.t("docker.state.running") },
            { value: "stopped", label: strings.t("docker.state.stopped") }
          ]
          value: root.pveState
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          focusable: false
          onChanged: function(v) { root.pveState = v }
        }
      }

      PlainText {
        visible: px.ok && px.shown.length === 0
        width: parent.width
        color: root.dim
        text: px.ok && px.p.guests.length === 0 ? strings.t("pve.noGuests") : strings.t("docker.noMatch")
      }

      Repeater {
        model: px.shown
        Column {
          required property var modelData
          width: px.width
          spacing: Style.space(4)
          GuestRow {
            width: parent.width
            guest: modelData
          }
          Loader {
            active: root.pveAddKey === lab.guestKey(modelData)
            visible: active
            width: parent.width
            sourceComponent: GuestAddForm { guest: modelData }
          }
        }
      }

      Card {
        visible: px.ok && px.p.storages.length > 0
        title: strings.t("section.storage")
        icon: "󰋊"
        Repeater {
          model: px.ok ? px.p.storages : []
          Meter {
            required property var modelData
            label: modelData.storage
            detail: (modelData.shared ? strings.t("pve.shared") : modelData.node) + (modelData.kind ? "  ·  " + modelData.kind : "")
            ratio: modelData.used / modelData.total
            value: Model.bytesPair(modelData.used, modelData.total, root.fmt)
          }
        }
      }

      Card {
        visible: px.ok && px.p.failedTasks.length > 0
        title: strings.t("pve.failedTasksTitle")
        icon: "󰀦"
        trailing: px.ok ? String(px.p.failedTasks.length) : ""
        trailingColor: root.urgent
        Repeater {
          model: px.ok ? px.p.failedTasks : []
          Column {
            required property var modelData
            width: parent.width
            spacing: Style.space(2)
            PlainText {
              width: parent.width
              color: modelData.type === "vzdump" ? root.urgent : root.foreground
              text: (modelData.type === "vzdump" ? strings.t("pve.backup") : modelData.type) + (modelData.id ? "  ·  " + modelData.id : "") + "  ·  " + modelData.node
            }
            PlainText {
              width: parent.width
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              color: root.dim
              font.pixelSize: Style.font.caption
              text: modelData.status + "  ·  " + root.ago(modelData.endtime)
            }
          }
        }
      }
    }
  }

  component GuestRow: ItemCard {
    id: gr
    property var guest: null
    readonly property string key: guest ? guest.node + "/" + guest.type + "/" + guest.vmid : ""
    readonly property bool busy: lab.pvePending.indexOf(key + ":") === 0
    property string armed: ""            // action waiting for its confirming second click
    Timer { id: grDisarm; interval: 3000; onTriggered: gr.armed = "" }

    function act(action) {
      if (action === "start") { lab.pveAction(guest, "start"); return }
      if (armed !== action) { armed = action; grDisarm.restart(); return }
      armed = ""
      grDisarm.stop()
      lab.pveAction(guest, action)
    }

    readonly property bool showActions: hasCursor || armed !== "" || busy || root.pveAddKey === key

    hasCursor: grHover.hovered
    implicitHeight: grLayout.implicitHeight + Style.space(20)
    opacity: busy ? 0.5 : 1
    HoverHandler { id: grHover }

    RowLayout {
      id: grLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      IconTile {
        Layout.alignment: Qt.AlignTop
        glyph: gr.guest && gr.guest.type === "lxc" ? "󰆧" : "󰍹"
        tint: gr.guest && gr.guest.running ? root.foreground : root.dim
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          PlainText {
            Layout.fillWidth: true
            text: gr.guest ? gr.guest.name : ""
            font.pixelSize: Style.font.body
            font.bold: true
            opacity: gr.guest && gr.guest.running ? 1 : 0.6
          }
          StatusPill {
            visible: !gr.showActions
            text: gr.guest ? "#" + gr.guest.vmid : ""
            tint: root.dim
          }
        }
        PlainText {
          Layout.fillWidth: true
          color: root.dim
          font.pixelSize: Style.font.caption
          text: {
            var g = gr.guest
            if (!g) return ""
            if (gr.busy) return strings.t("pve.working")
            var parts = [strings.t("pve.status." + g.status) !== "pve.status." + g.status ? strings.t("pve.status." + g.status) : g.status]
            if (lab.pve && lab.pve.nodes.length > 1) parts.push(g.node)
            if (g.running) {
              parts.push(Model.duration(g.uptime))
              parts.push("CPU " + root.fmt(g.cpu * 100, 0) + " %")
              if (g.maxmem > 0) parts.push(Model.bytesPair(g.mem, g.maxmem, root.fmt))
            }
            if (g.lock) parts.push("󰌾 " + g.lock)
            return parts.join("  ·  ")
          }
        }
        PlainText {
          visible: gr.armed !== ""
          Layout.fillWidth: true
          color: root.urgent
          font.pixelSize: Style.font.caption
          text: gr.armed !== "" ? strings.t("pve.confirm." + gr.armed) : ""
        }
        Flow {
          visible: gr.armed === "" && gr.guest !== null && gr.guest.tags.length > 0
          Layout.fillWidth: true
          spacing: Style.space(4)
          Repeater {
            model: gr.guest ? gr.guest.tags : []
            StatusPill {
              required property var modelData
              text: modelData
              tint: root.foreground
            }
          }
        }
      }

      PanelActionButton {
        visible: gr.showActions && gr.guest !== null && !gr.guest.running
        iconText: "󰐊"
        tooltipText: strings.t("docker.start")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !gr.busy && lab.pvePending === ""
        onClicked: gr.act("start")
      }
      PanelActionButton {
        visible: gr.showActions && gr.guest !== null && gr.guest.running
        iconText: gr.armed === "shutdown" ? "󰄬" : "󰐥"
        tooltipText: gr.armed === "shutdown" ? strings.t("pve.confirm.shutdown") : strings.t("pve.shutdown")
        foreground: root.foreground
        hoverColor: root.urgent
        bordered: gr.armed === "shutdown"
        fontFamily: root.fontFamily
        enabled: !gr.busy && lab.pvePending === ""
        onClicked: gr.act("shutdown")
      }
      PanelActionButton {
        visible: gr.showActions && gr.guest !== null && gr.guest.running
        iconText: gr.armed === "reboot" ? "󰄬" : "󰜉"
        tooltipText: gr.armed === "reboot" ? strings.t("pve.confirm.reboot") : strings.t("docker.restart")
        foreground: root.foreground
        hoverColor: root.urgent
        bordered: gr.armed === "reboot"
        fontFamily: root.fontFamily
        enabled: !gr.busy && lab.pvePending === ""
        onClicked: gr.act("reboot")
      }
      PanelActionButton {
        visible: gr.showActions
        iconText: "󰆍"
        tooltipText: strings.t("pve.console")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: { lab.openPveConsole(gr.guest); root.close() }
      }
      PanelActionButton {
        readonly property int hostIndex: gr.guest ? lab.hostIndexForGuest(gr.guest) : -1
        visible: gr.showActions && gr.guest !== null && (hostIndex >= 0 || gr.guest.running)
        iconText: hostIndex >= 0 ? "󰁔" : "󰐕"
        tooltipText: hostIndex >= 0 ? strings.t("pve.openHost") : strings.t("pve.addHost")
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: root.pveAddKey === gr.key
        onClicked: {
          if (hostIndex >= 0) { lab.selectHost(hostIndex); root.selectTab("monitoring"); return }
          if (root.pveAddKey === gr.key) { root.pveAddKey = ""; return }
          root.pveAddKey = gr.key
          lab.hostAddNotice = ""
          if (lab.guestAddresses[gr.key] === undefined) lab.lookupGuestAddress(gr.guest)
        }
      }
    }
  }

  // Adds a Proxmox guest to the hosts file, optionally installing the SSH
  // key on it from a terminal right after.
  component GuestAddForm: Column {
    id: gf
    property var guest: null
    readonly property string key: lab.guestKey(guest)
    readonly property var ips: lab.guestAddresses[key]
    readonly property bool looking: lab.guestLookup === key
    readonly property string user: guest && guest.type === "lxc" ? "root" : (Quickshell.env("USER") || "root")
    property bool edited: false
    spacing: Style.space(6)
    leftPadding: Style.space(10)

    function suggested() { return ips && ips.length > 0 ? user + "@" + ips[0] : "" }
    onIpsChanged: if (!edited) gfTarget.text = suggested()
    Component.onCompleted: { gfName.text = guest ? guest.name : ""; gfTarget.text = suggested() }

    function submit(installKey) {
      lab.addHost(gfName.text, gfTarget.text, 22, guest, installKey)
    }

    PlainText {
      width: parent.width - gf.leftPadding
      wrapMode: Text.WordWrap
      color: root.dim
      font.pixelSize: Style.font.caption
      text: gf.looking ? strings.t("pve.add.lookup")
          : gf.ips && gf.ips.length > 0 ? strings.t("pve.add.found").arg(gf.ips.join(", "))
          : gf.ips ? strings.t("pve.add.none") : ""
    }
    TextField {
      id: gfName
      width: parent.width - gf.leftPadding
      placeholderText: strings.t("pve.add.name")
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      foreground: root.foreground
      horizontalPadding: Style.spacing.controlGap
      verticalPadding: Style.spacing.controlPaddingY
      onActiveFocusChanged: root.inputFocused = activeFocus
      onAccepted: gfTarget.forceActiveFocus()
    }
    TextField {
      id: gfTarget
      width: parent.width - gf.leftPadding
      placeholderText: strings.t("pve.add.target")
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      foreground: root.foreground
      horizontalPadding: Style.spacing.controlGap
      verticalPadding: Style.spacing.controlPaddingY
      onTextEdited: gf.edited = true
      onActiveFocusChanged: root.inputFocused = activeFocus
      onAccepted: gf.submit(true)
    }
    PlainText {
      width: parent.width - gf.leftPadding
      wrapMode: Text.WordWrap
      color: root.dim
      font.pixelSize: Style.font.caption
      text: strings.t("pve.add.help")
    }
    Flow {
      width: parent.width - gf.leftPadding
      spacing: Style.space(6)
      Button {
        text: strings.t("pve.add.withKey")
        iconText: "󰌆"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: Model.validTarget(gfTarget.text.trim())
        onClicked: gf.submit(true)
      }
      Button {
        text: strings.t("pve.add.only")
        iconText: "󰐕"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: Model.validTarget(gfTarget.text.trim())
        onClicked: gf.submit(false)
      }
      Button {
        text: strings.t("pve.add.cancel")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: { root.pveAddKey = ""; root.inputFocused = false }
      }
    }
    PlainText {
      visible: lab.hostAddNotice !== ""
      width: parent.width - gf.leftPadding
      wrapMode: Text.WordWrap
      font.pixelSize: Style.font.caption
      color: lab.hostAddNotice === "added" ? root.foreground : root.urgent
      text: {
        var n = lab.hostAddNotice
        return /^(added|exists|full|json|target)$/.test(n) ? strings.t("pve.add." + n) : n
      }
    }
  }

  component PackagesSection: Column {
    id: pk
    readonly property var w: root.watcher
    readonly property string hostKey: lab.host ? lab.host.key : ""
    readonly property var u: w && hostKey !== "" ? (w.updates[hostKey] || null) : null
    readonly property var os: u ? u.os : null
    readonly property bool checking: w !== null && (!!w.checking[hostKey] || !!w.checkingPackages[hostKey])
    readonly property double checkedAt: u ? (u.packagesCheckedAt || u.checkedAt || 0) : 0
    readonly property bool stale: os !== null && !os.fresh && os.listsAge > 2 * 86400
    readonly property bool multi: os !== null && os.managers !== undefined && os.managers.length > 1
    property bool expanded: false
    readonly property int limit: expanded ? 200 : 12

    visible: w !== null
    spacing: Style.space(6)

    PlainText {
      width: parent.width
      wrapMode: Text.WordWrap
      color: pk.os && pk.os.count > 0 ? root.foreground : root.dim
      text: {
        if (pk.checking) return strings.t("updates.checking")
        if (!pk.u) return strings.t("packages.notChecked")
        if (!pk.os) return strings.t("packages.unsupported")
        if (pk.os.count === 0) return pk.stale ? strings.t("packages.noneStale") : "󰄬  " + strings.t("packages.upToDate")
        return strings.t("updates.os").arg(pk.os.count)
            + (pk.os.security > 0 ? "  ·  " + strings.t("updates.security").arg(pk.os.security) : "")
      }
    }

    PlainText {
      visible: pk.os !== null
      width: parent.width
      wrapMode: Text.WordWrap
      font.pixelSize: Style.font.caption
      color: pk.stale ? root.urgent : root.dim
      text: !pk.os ? "" : (pk.multi ? pk.os.managers.map(function(m) { return m.manager + " " + m.count }).join(", ") : pk.os.manager)
          + (pk.os.fresh ? "  ·  " + strings.t("packages.fresh")
             : (pk.os.listsAge >= 0 ? "  ·  " + strings.t("packages.listsAge").arg(root.ago(pk.checkedAt - pk.os.listsAge * 1000)) : "  ·  " + strings.t("packages.notRefreshable")))
          + (pk.stale ? "  ·  " + strings.t("packages.staleFallback") : "")
          + "  ·  " + strings.t("updates.lastCheck").arg(root.ago(pk.checkedAt))
    }

    PlainText {
      visible: pk.u !== null && pk.u.busy === true
      width: parent.width
      wrapMode: Text.WordWrap
      color: root.foreground
      text: "󰑐  " + strings.t("packages.busy")
    }

    PlainText {
      visible: pk.u !== null && pk.u.reboot === true
      width: parent.width
      color: root.urgent
      text: "󰀦  " + strings.t("packages.reboot")
    }

    Flow {
      width: parent.width
      spacing: Style.space(6)
      Button {
        text: pk.checking ? strings.t("updates.checking") : strings.t("updates.check")
        iconText: "󰑐"
        iconSpinning: pk.checking
        tooltipText: strings.t("packages.checkHint")
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        enabled: !pk.checking
        onClicked: pk.w.checkPackages(pk.hostKey)
      }
      Button {
        visible: pk.os !== null && pk.os.count > 0
        text: strings.t("packages.upgrade")
        iconText: "󰆍"
        tooltipText: strings.t("updates.upgradeOs")
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        bordered: true
        onClicked: pk.w.upgradePackages(pk.hostKey)
      }
    }

    Repeater {
      model: pk.os ? pk.os.packages.slice(0, pk.limit) : []
      RowLayout {
        required property var modelData
        width: pk.width
        spacing: Style.space(8)
        PlainText {
          text: modelData.security ? "󰕥" : "󰏗"
          color: modelData.security ? root.urgent : root.dim
          font.pixelSize: Style.font.bodySmall
        }
        PlainText {
          Layout.fillWidth: true
          text: modelData.name
          font.pixelSize: Style.font.bodySmall
        }
        PlainText {
          Layout.maximumWidth: pk.width * 0.55
          horizontalAlignment: Text.AlignRight
          color: root.dim
          font.pixelSize: Style.font.caption
          text: (pk.multi && modelData.source !== "" ? modelData.source + "  ·  " : "")
              + (modelData.current !== "" ? modelData.current + "  →  " : "") + modelData.version
        }
      }
    }

    Button {
      visible: pk.os !== null && pk.os.packages.length > 12
      text: pk.expanded ? strings.t("packages.showLess") : strings.t("packages.showAll").arg(pk.os ? pk.os.packages.length : 0)
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      onClicked: pk.expanded = !pk.expanded
    }
  }

  component AlertsView: Column {
    id: av
    readonly property var w: root.watcher
    readonly property var imageUpdates: w ? w.updateList.filter(function(u) { return u.kind === "image" }) : []
    readonly property double lastCheck: {
      if (!w) return 0
      var oldest = 0
      for (var i = 0; i < lab.hosts.length; i++) {
        var u = w.updates[lab.hosts[i].key]
        var at = u ? u.checkedAt || 0 : 0
        if (i === 0 || at < oldest) oldest = at
      }
      return oldest
    }
    property bool armedAll: false
    Timer { id: disarmAll; interval: 3000; onTriggered: av.armedAll = false }

    spacing: Style.space(8)

    PlainText {
      visible: av.w === null
      width: parent.width
      wrapMode: Text.WordWrap
      color: root.dim
      text: strings.t("alerts.unavailable")
    }

    // Alerts
    SectionTitle {
      visible: av.w !== null
      title: strings.t("alerts.title")
      icon: "󰀦"
      trailing: av.w && av.w.alerts.length > 0 ? String(av.w.alerts.length) : ""
      trailingColor: av.w && av.w.hasErrors ? root.urgent : root.dim
    }
    Card {
      visible: av.w !== null && av.w.alerts.length === 0
      PlainText {
        width: parent.width
        color: root.dim
        text: "󰄬  " + strings.t("alerts.none")
      }
    }
    Repeater {
      model: av.w ? av.w.alerts : []
      AlertRow {
        required property var modelData
        width: av.width
        alert: modelData
      }
    }

    Item { width: 1; height: Style.space(6) }

    // Updates
    RowLayout {
      visible: av.w !== null
      width: parent.width
      spacing: Style.space(6)
      SectionTitle {
        Layout.fillWidth: true
        title: strings.t("updates.title")
        icon: "󰚰"
        trailing: av.w && av.w.updateList.length > 0 ? String(av.w.updateList.length) : ""
      }
      Button {
        text: av.w && av.w.checkingUpdates ? strings.t("updates.checking") : strings.t("updates.check")
        iconText: "󰑐"
        iconSpinning: av.w !== null && av.w.checkingUpdates
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        enabled: av.w !== null && !av.w.checkingUpdates
        onClicked: av.w.checkUpdates("")
      }
    }
    PlainText {
      visible: av.w !== null
      width: parent.width
      wrapMode: Text.WordWrap
      color: root.dim
      font.pixelSize: Style.font.caption
      text: strings.t("updates.lastCheck").arg(root.ago(av.lastCheck))
          + (av.w && av.w.checkingUpdates ? "  ·  " + strings.t("updates.checkingHint") : "")
    }
    PlainText {
      readonly property var counts: {
        var c = { errors: 0, limited: 0 }
        if (!av.w) return c
        for (var k in av.w.updates) {
          c.errors += av.w.updates[k].imageErrors || 0
          c.limited += av.w.updates[k].rateLimited || 0
        }
        return c
      }
      visible: counts.errors > 0
      width: parent.width
      wrapMode: Text.WordWrap
      color: counts.limited > 0 ? root.urgent : root.dim
      font.pixelSize: Style.font.caption
      text: counts.limited > 0 ? strings.t("updates.rateLimited").arg(counts.limited).arg(counts.errors)
                               : strings.t("updates.unchecked").arg(counts.errors)
    }
    Card {
      visible: av.w !== null && av.w.updateList.length === 0 && av.lastCheck > 0
      PlainText {
        width: parent.width
        color: root.dim
        text: "󰄬  " + strings.t("updates.none")
      }
    }
    Button {
      visible: av.imageUpdates.length > 1
      text: av.armedAll ? strings.t("updates.confirmAll") : strings.t("updates.allImages").arg(av.imageUpdates.length)
      iconText: av.armedAll ? "󰄬" : "󰇚"
      foreground: av.armedAll ? root.urgent : root.foreground
      fontFamily: root.fontFamily
      bordered: true
      onClicked: {
        if (!av.armedAll) { av.armedAll = true; disarmAll.restart(); return }
        av.armedAll = false
        root.updateAllImages()
      }
    }
    Repeater {
      model: av.w ? av.w.updateList : []
      UpdateRow {
        required property var modelData
        width: av.width
        update: modelData
      }
    }
  }

  component AlertRow: ItemCard {
    id: alertRow
    property var alert: null
    readonly property color tint: alert && alert.level === "error" ? root.urgent : root.foreground

    hasCursor: alertMouse.containsMouse
    implicitHeight: alertLayout.implicitHeight + Style.space(20)

    MouseArea {
      id: alertMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (alertRow.alert) root.goTo(alertRow.alert.hostKey, alertRow.alert.tab === "alerts" ? "monitoring" : alertRow.alert.tab)
    }

    RowLayout {
      id: alertLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      IconTile {
        Layout.alignment: Qt.AlignTop
        glyph: !alertRow.alert ? "" : alertRow.alert.level === "error" ? "󰅚" : alertRow.alert.level === "warning" ? "󰀦" : "󰋽"
        tint: alertRow.tint
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)
        PlainText {
          Layout.fillWidth: true
          text: alertRow.alert ? alertRow.alert.title : ""
          color: alertRow.tint
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.WordWrap
        }
        PlainText {
          visible: text !== ""
          Layout.fillWidth: true
          text: alertRow.alert ? alertRow.alert.body : ""
          color: root.dim
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        PlainText {
          Layout.fillWidth: true
          color: root.dim
          font.pixelSize: Style.font.caption
          text: alertRow.alert ? (lab.hosts.length > 1 ? alertRow.alert.host + "  ·  " : "") + root.ago(alertRow.alert.since) : ""
        }
      }
      PanelActionButton {
        visible: alertRow.hasCursor
        iconText: "󰅖"
        tooltipText: strings.t("alerts.dismiss")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: if (root.watcher && alertRow.alert) root.watcher.dismiss(alertRow.alert.id)
      }
    }
  }

  component UpdateRow: ItemCard {
    id: upRow
    property var update: null
    readonly property var host: update ? root.hostByKey(update.hostKey) : null
    readonly property bool isImage: update !== null && update.kind === "image"
    readonly property bool updating: isImage && lab.isUpdating(update.hostKey, update.container)
    readonly property bool queued: isImage && lab.isQueued(update.hostKey, update.container)
    readonly property string result: isImage ? lab.updateResult(update.hostKey, update.container) : ""
    property bool armed: false
    Timer { id: upDisarm; interval: 3000; onTriggered: upRow.armed = false }

    hasCursor: upHover.hovered
    implicitHeight: upLayout.implicitHeight + Style.space(20)
    HoverHandler { id: upHover }

    RowLayout {
      id: upLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      IconTile {
        Layout.alignment: Qt.AlignTop
        glyph: !upRow.update ? "" : upRow.update.kind === "os" ? "󰏗" : upRow.update.kind === "image" ? "󰡨" : "󰒓"
        tint: root.accent
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)
        PlainText {
          Layout.fillWidth: true
          font.pixelSize: Style.font.body
          font.bold: true
          text: {
            var u = upRow.update
            if (!u) return ""
            if (u.kind === "os") return strings.t("updates.os").arg(u.count) + (u.security > 0 ? "  ·  " + strings.t("updates.security").arg(u.security) : "")
            if (u.kind === "image") return u.container
            return u.name
          }
        }
        PlainText {
          visible: text !== ""
          Layout.fillWidth: true
          color: root.dim
          font.pixelSize: Style.font.caption
          wrapMode: upRow.update && (upRow.update.kind === "os" || upRow.result.indexOf("error") === 0) ? Text.WordWrap : Text.NoWrap
          maximumLineCount: 3
          text: {
            var u = upRow.update
            if (!u) return ""
            var prefix = lab.hosts.length > 1 && upRow.host ? upRow.host.name + "  ·  " : ""
            if (u.kind === "os") {
              var names = u.packages.slice(0, 8).map(function(p) { return p.name }).join(", ") + (u.packages.length > 8 ? "…" : "")
              var old = u.listsAge > 3 * 86400 ? "  ·  " + strings.t("updates.listsOld").arg(Math.floor(u.listsAge / 86400)) : ""
              return prefix + u.manager + "  ·  " + names + old
            }
            if (u.kind === "image") {
              if (upRow.updating) return prefix + strings.t("docker.updating")
              if (upRow.queued) return prefix + strings.t("docker.updateQueued")
              if (upRow.result !== "") return prefix + (upRow.result === "updated" ? strings.t("docker.updated")
                  : upRow.result === "uptodate" ? strings.t("docker.upToDate")
                  : strings.t("docker.updateError." + upRow.result.split(" ")[1]) + (lab.updateDetail(u.hostKey, u.container) !== "" ? "  ·  " + lab.updateDetail(u.hostKey, u.container) : ""))
              return prefix + (u.pulled ? strings.t("updates.pulled") + "  ·  " : "") + u.image
            }
            return prefix + (u.current !== "" ? u.current : "?") + "  →  " + (u.latest !== "" ? u.latest : strings.t("updates.newVersion"))
          }
        }
      }
      PanelActionButton {
        visible: upRow.update !== null && upRow.update.kind === "os"
        iconText: "󰆍"
        tooltipText: strings.t("updates.upgradeOs")
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: if (root.watcher && upRow.host) root.watcher.upgradePackages(upRow.host.key)
      }
      PanelActionButton {
        visible: upRow.isImage
        iconText: upRow.armed ? "󰄬" : "󰇚"
        tooltipText: upRow.armed ? strings.t("docker.updateConfirm") : strings.t("docker.update")
        foreground: root.foreground
        hoverColor: upRow.armed ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: !upRow.updating && !upRow.queued
        opacity: upRow.updating || upRow.queued ? 0.4 : 1
        onClicked: {
          if (!upRow.armed) { upRow.armed = true; upDisarm.restart(); return }
          upRow.armed = false
          lab.updateContainer(upRow.update.container, upRow.host)
        }
      }
      PanelActionButton {
        visible: upRow.update !== null && upRow.update.kind === "service" && upRow.update.url !== ""
        iconText: "󰏌"
        tooltipText: strings.t("action.openWeb")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: { lab.openUrl(upRow.update.url); root.close() }
      }
    }
  }

  component ContainerRow: ItemCard {
    id: row
    property var container: null
    readonly property bool running: container && container.state === "running"
    readonly property bool busy: container && lab.pendingAction.split(":")[1] === container.name
    readonly property bool updating: container !== null && lab.host !== null && lab.isUpdating(lab.host.key, container.name)
    readonly property bool queued: container !== null && lab.host !== null && lab.isQueued(lab.host.key, container.name)
    readonly property string updateResult: container && lab.host ? lab.updateResult(lab.host.key, container.name) : ""
    readonly property bool hasUpdate: container !== null && root.hasImageUpdate(container.name)
    // Recreating a container is disruptive: the first click arms, the second runs.
    property bool armed: false
    Timer { id: disarm; interval: 3000; onTriggered: row.armed = false }

    readonly property bool troubled: container !== null && (/restarting|dead/.test(container.state) || /\(unhealthy\)/.test(container.status))
    // Actions stay out of the way until the row is pointed at.
    readonly property bool showActions: hasCursor || armed || busy || updating || queued

    hasCursor: rowHover.hovered
    implicitHeight: rowLayout.implicitHeight + Style.space(20)

    HoverHandler { id: rowHover }

    RowLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      IconTile {
        Layout.alignment: Qt.AlignTop
        glyph: "󰡨"
        tint: row.troubled ? root.urgent : root.foreground
        opacity: row.running ? 1 : 0.5
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          PlainText {
            Layout.fillWidth: true
            text: row.container ? row.container.name : ""
            font.pixelSize: Style.font.body
            font.bold: true
            opacity: row.running ? 1 : 0.6
          }
          StatusPill {
            visible: !row.showActions && row.hasUpdate && row.updateResult === ""
            text: "󰚰 " + strings.t("docker.updateShort")
            tint: root.accent
          }
        }
        PlainText {
          Layout.fillWidth: true
          color: row.troubled ? root.urgent : root.dim
          font.pixelSize: Style.font.caption
          text: {
            if (!row.container) return ""
            if (row.updating) return strings.t("docker.updating")
            if (row.queued) return strings.t("docker.updateQueued")
            var parts = [row.container.status]
            if (row.container.cpu !== "") parts.push("CPU " + row.container.cpu)
            if (row.container.mem !== "") parts.push(row.container.mem)
            return parts.join("  ·  ")
          }
        }
        PlainText {
          Layout.fillWidth: true
          color: root.dim
          font.pixelSize: Style.font.caption
          text: {
            if (!row.container) return ""
            if (root.dockerSort !== "created" || !(row.container.created > 0)) return row.container.image
            return strings.t("docker.createdOn").arg(new Date(row.container.created).toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat))
                + "  ·  " + row.container.image
          }
        }
        PlainText {
          visible: row.updateResult !== ""
          Layout.fillWidth: true
          font.pixelSize: Style.font.caption
          color: row.updateResult.indexOf("error") === 0 ? root.urgent : root.foreground
          text: row.updateResult === "" ? ""
              : row.updateResult === "updated" ? strings.t("docker.updated")
              : row.updateResult === "uptodate" ? strings.t("docker.upToDate")
              : strings.t("docker.updateError." + row.updateResult.split(" ")[1])
        }
        PlainText {
          readonly property string detail: row.container && lab.host ? lab.updateDetail(lab.host.key, row.container.name) : ""
          visible: detail !== "" && row.updateResult.indexOf("error") === 0
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          font.pixelSize: Style.font.caption
          color: root.dim
          text: detail
        }
      }

      PanelActionButton {
        visible: row.showActions
        Layout.alignment: Qt.AlignVCenter
        iconText: row.running ? "󰓛" : "󰐊"
        tooltipText: row.running ? strings.t("docker.stop") : strings.t("docker.start")
        foreground: root.foreground
        hoverColor: row.running ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        enabled: !row.busy && lab.pendingAction === ""
        onClicked: root.containerAction(row.running ? "stop" : "start", row.container.name)
      }
      PanelActionButton {
        visible: row.showActions
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰜉"
        tooltipText: strings.t("docker.restart")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !row.busy && lab.pendingAction === ""
        opacity: row.busy ? 0.4 : 1
        onClicked: lab.containerAction("restart", row.container.name)
      }
      PanelActionButton {
        visible: row.showActions
        Layout.alignment: Qt.AlignVCenter
        iconText: row.armed ? "󰄬" : "󰇚"
        tooltipText: row.armed ? strings.t("docker.updateConfirm") : (row.hasUpdate ? strings.t("docker.updateAvailable") + " · " : "") + strings.t("docker.update")
        foreground: root.foreground
        hoverColor: row.armed ? root.urgent : root.foreground
        fontFamily: root.fontFamily
        bordered: row.armed || (row.hasUpdate && !row.updating && !row.queued)
        enabled: !row.updating && !row.queued
        opacity: row.updating || row.queued ? 0.4 : 1
        onClicked: {
          if (!row.armed) { row.armed = true; disarm.restart(); return }
          row.armed = false
          disarm.stop()
          lab.updateContainer(row.container.name)
        }
      }
      PanelActionButton {
        visible: row.showActions
        Layout.alignment: Qt.AlignVCenter
        iconText: "󰈙"
        tooltipText: strings.t("docker.logs")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: lab.openLogs(row.container.name)
      }
    }
  }

  component LinkRow: ItemCard {
    id: linkRow
    property var link: null

    hasCursor: linkMouse.containsMouse
    implicitHeight: linkLayout.implicitHeight + Style.space(20)

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (linkRow.link) { lab.openUrl(linkRow.link.url); root.close() }
    }

    RowLayout {
      id: linkLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(10)

      IconTile {
        glyph: linkRow.link && linkRow.link.icon !== "" ? linkRow.link.icon : "󰖟"
        tint: root.accent
        Layout.alignment: Qt.AlignVCenter
      }
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)
        PlainText {
          Layout.fillWidth: true
          text: linkRow.link ? linkRow.link.name : ""
          font.pixelSize: Style.font.body
          font.bold: true
        }
        PlainText {
          Layout.fillWidth: true
          text: linkRow.link ? linkRow.link.url : ""
          color: root.dim
          font.pixelSize: Style.font.caption
        }
      }
      PlainText {
        text: "󰏌"
        color: root.dim
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
