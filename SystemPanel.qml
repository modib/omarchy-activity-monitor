import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// First-class Omarchy system popup panel displaying visual telemetry for CPU,
// GPU, Memory, and live CPU load history, with an interactive settings drawer.
KeyboardPanel {
  id: root

  required property QtObject hw
  property bool fahrenheit: false
  property int warnPercent: 70
  property int criticalPercent: 90
  property int warnTempC: 75
  property int criticalTempC: 90
  property int warnFanRpm: 3500
  property int criticalFanRpm: 5000

  property string mode: "icons"
  property bool showGpu: true
  property bool showCpu: true
  property bool showCpuTemp: true
  property bool showGpuTemp: false
  property bool showRam: true
  property bool showFan: true
  property bool showDisk: false
  property string ramFormat: "used/total"
  property string diskFormat: "percent"
  property string tempFormat: "degree-unit"
  property bool showGauges: true
  property bool showValues: false
  property bool settingsOpen: false

  // Process list state. Two fixed lists (Heaviest CPU, Heaviest Memory) each
  // capped at sectionRows (max 5); pending* is the one-shot confirm state for
  // a kill offered on a user-owned row only.
  property int topProcessCount: 5
  property int cpuThresholdPct: 10
  property int memThresholdMib: 0
  property int pendingPid: 0
  property string pendingSig: ""
  property string pendingComm: ""

  readonly property int sectionRows: Math.min(Math.max(root.topProcessCount, 1), 5)

  // memThresholdMib is the configured floor; 0 means "auto", which is 10% of
  // this machine's total RAM. memThresholdKib is the effective floor used by
  // the filter and memShowMib what the empty state reports.
  readonly property int memThresholdKib: root.memThresholdMib > 0
    ? root.memThresholdMib * 1024
    : Math.round(Math.max(root.totalMemKib, 1) * 0.1)
  readonly property int memShowMib: root.memThresholdMib > 0
    ? root.memThresholdMib
    : Math.round(Math.max(root.totalMemKib, 1) * 0.1 / 1024)
  readonly property int totalMemKib: hw.memory && hw.memory.totalKib > 0
    ? hw.memory.totalKib : 0

  // Heaviest CPU only counts processes pulling more than cpuThresholdPct% of a
  // core; Heaviest Memory only counts processes above the configured MiB floor
  // (default: 10% of total RAM), and both lists cap at sectionRows. The
  // thresholds keep a quiet machine's lists genuinely short — a row only
  // appears when its process is actually worth your attention.
  function sliceProcessList(report, key, filter) {
    var arr = report && report.ok ? report[key] : []
    if (arr === undefined || arr === null) arr = []
    var out = []
    for (var i = 0; i < arr.length && out.length < root.sectionRows; i++) {
      if (filter && !filter(arr[i])) continue
      out.push(arr[i])
    }
    return out
  }

  readonly property var processCpuList: sliceProcessList(hw.processReport, "cpu", function(e) {
    return e && isFinite(e.cpuPct) && e.cpuPct > root.cpuThresholdPct
  })
  readonly property var processMemList: sliceProcessList(hw.processReport, "mem", function(e) {
    return e && isFinite(e.rssKib) && e.rssKib > root.memThresholdKib
  })

  // Owner uid reported by proc-probe's meta line. Only a process owned by this
  // uid may ever be offered a Quit / Force action.
  readonly property int ownUid: hw.processReport && hw.processReport.uid !== undefined ? hw.processReport.uid : -1

  function requestAction(entry, signal) {
    if (!entry || entry.uid !== root.ownUid) return
    root.pendingPid = entry.pid
    root.pendingSig = signal
    root.pendingComm = entry.comm
  }

  function confirmAction() {
    if (root.pendingPid <= 0) return
    hw.killProcess(root.pendingPid, root.pendingSig)
    root.pendingPid = 0
    root.pendingSig = ""
    refreshTimer.restart()
  }

  function cancelAction() {
    root.pendingPid = 0
    root.pendingSig = ""
  }

  signal fahrenheitToggled()

  function persistSetting(key, value) {
    if (root.owner && typeof root.owner.persistSetting === "function") {
      root.owner.persistSetting(key, value)
    }
  }

  function toggleFahrenheit() {
    if (root.owner && typeof root.owner.toggleFahrenheit === "function") {
      root.owner.toggleFahrenheit()
    } else {
      root.fahrenheit = !root.fahrenheit
    }
  }

  readonly property color baseColor: root.bar ? root.bar.foreground : Color.foreground
  readonly property color hotColor: root.bar ? root.bar.urgent : Color.urgent
  readonly property color dimColor: Qt.darker(baseColor, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  function warm(from, amount) {
    if (!(amount > 0)) return from
    var t = Math.min(1, amount)
    return Qt.rgba(from.r + (hotColor.r - from.r) * t,
                   from.g + (hotColor.g - from.g) * t,
                   from.b + (hotColor.b - from.b) * t,
                   from.a)
  }

  function tempColor(tempC) {
    if (!isFinite(tempC) || tempC <= 0) return dimColor
    if (tempC <= warnTempC) return dimColor
    var t = Math.min(1, Math.max(0, (tempC - warnTempC) / Math.max(1, criticalTempC - warnTempC)))
    return Qt.rgba(baseColor.r + (hotColor.r - baseColor.r) * t,
                   baseColor.g + (hotColor.g - baseColor.g) * t,
                   baseColor.b + (hotColor.b - baseColor.b) * t,
                   baseColor.a)
  }

  function fanSeverity(rpm) {
    if (!isFinite(rpm) || rpm < 0) return 0
    return Math.min(1, Math.max(0, (rpm - warnFanRpm) / Math.max(1, criticalFanRpm - warnFanRpm)))
  }

  onOpenChanged: {
    if (open) {
      hw.sample()
      hw.refreshProcesses()
    } else {
      root.settingsOpen = false
      root.cancelAction()
    }
  }

  focusTarget: keyCatcher
  contentWidth: fittedContentWidth(Style.space(450))
  contentHeight: fittedContentHeight(panelColumn.implicitHeight + Style.space(16), Style.space(960))

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: root.close()
    // root.owner is the Panel widget root (Widget.qml sets owner: root).
    // Tab cycles the bar readout mode (the shell has no panel-switching API
    // on the owner); R resamples sensors and processes; C/F toggle units.
    onTabRequested: function(direction) {
      if (root.owner && typeof root.owner.cycleMode === "function") {
        root.owner.cycleMode()
      }
    }
    onTextKey: function(t) {
      if (t === "r" || t === "R") {
        hw.sample()
        hw.refreshProcesses()
      } else if (t === "c" || t === "C" || t === "f" || t === "F") {
        root.toggleFahrenheit()
      } else if (t === "s" || t === "S") {
        root.settingsOpen = !root.settingsOpen
      }
    }

    // One-shot confirmation of a kill action expires on its own, and the list
    // is re-polled shortly after an action so a dead app does not sit visible.
    Timer {
      id: refreshTimer
      interval: 900
      repeat: false
      onTriggered: hw.refreshProcesses()
    }

    Timer {
      id: pendingTimer
      interval: 6000
      repeat: false
      running: root.pendingPid > 0
      onTriggered: root.cancelAction()
    }

    Controls.ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
      Controls.ScrollBar.vertical.policy: panelColumn.implicitHeight > scrollArea.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff

      Binding {
        target: scrollArea.contentItem
        property: "interactive"
        value: panelColumn.implicitHeight > scrollArea.height
      }

      Column {
        id: panelColumn
        width: scrollArea.availableWidth
        spacing: Style.space(12)

        // 1. Header with Processor Name and Settings Gear
        Item {
          width: parent.width
          implicitHeight: Math.max(headerLeft.implicitHeight, settingsButton.implicitHeight)

          Row {
            id: headerLeft
            anchors.left: parent.left
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

Text {
                textFormat: Text.PlainText
                text: "\uF080"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                anchors.verticalCenter: parent.verticalCenter
              }

            Column {
              id: titleCol
              width: parent.width - Style.font.display - Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                id: headerTitle
                textFormat: Text.PlainText
                text: "Activity Monitor"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              // Single line, fully visible, never wrapped: the "@ clock" suffix
              // is dropped from the CPU model (live clock is sampled anyway)
              // and the size steps one below caption, so
              // "Model | X GiB RAM | X GiB Swap" fits the header column.
              // Elide stays only as a backstop for unusually long names.
              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                text: (hw.cpuInfo && hw.cpuInfo.model ? String(hw.cpuInfo.model).split(" @")[0] : "System Telemetry")
                  + (hw.memory && hw.memory.totalKib > 0
                     ? " | " + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + " GiB RAM"
                       + (hw.memory.swapTotalKib > 0
                          ? " | " + Model.formatGib(Model.gibFromKib(hw.memory.swapTotalKib)) + " GiB Swap"
                          : "")
                     : "")
                color: root.dimColor
                font.family: root.fontFamily
                font.pixelSize: Math.max(9, Style.font.caption - 1)
                font.bold: true
              }
            }
          }

          // Gear Icon for In-Panel Settings — a bare glyph pinned to the header's
          // top-right corner, title-sized in persistent foreground white like
          // the heading beside it. NOTE: this engine rejects anchor lines to
          // anything that is not a parent or sibling (the shell log shows
          // "Cannot anchor to an item that isn't a parent or sibling"), so the
          // gear is placed with an explicit y instead of anchoring to the
          // title. The -2 seats the baseline-sitting gear ink against the
          // title's cap height (pixel-verified on this machine's bar font).
          Item {
            id: settingsButton
            implicitWidth: Math.max(settingsGlyph.implicitWidth, Style.space(28))
            implicitHeight: Math.max(settingsGlyph.implicitHeight, Style.space(28))
            anchors.right: parent.right
            y: headerLeft.y + titleCol.y + headerTitle.y + (headerTitle.height - height) / 2 - 2

            Text {
              id: settingsGlyph
              anchors.centerIn: parent
              text: "\uF013"
              color: root.baseColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            MouseArea {
              id: settingsHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.settingsOpen = !root.settingsOpen
            }
          }
        }

        // Animated Settings Drawer
        Rectangle {
          width: parent.width
          visible: root.settingsOpen || height > 0
          height: root.settingsOpen ? settingsCol.implicitHeight + Style.space(20) : 0
          clip: true
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
          border.width: 1
          radius: Style.cornerRadius

          Behavior on height {
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
          }
          opacity: root.settingsOpen ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
          }

          Column {
            id: settingsCol
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.space(10)
            spacing: Style.space(10)

            // Settings Header
            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Top Bar Display Settings"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Readout Mode
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Mode"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "Icons"
                  selected: root.mode === "icons"
                  onPicked: root.persistSetting("mode", "icons")
                }
                ModeChip {
                  label: "Compact"
                  selected: root.mode === "compact"
                  onPicked: root.persistSetting("mode", "compact")
                }
                ModeChip {
                  label: "Full"
                  selected: root.mode === "full"
                  onPicked: root.persistSetting("mode", "full")
                }
                ModeChip {
                  label: "Labels"
                  selected: root.mode === "labels"
                  onPicked: root.persistSetting("mode", "labels")
                }
              }
            }

            // Show Components
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Show"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: " CPU"
                  selected: root.showCpu
                  onPicked: root.persistSetting("showCpu", !root.showCpu)
                }
                ModeChip {
                  label: " CPU Temp"
                  selected: root.showCpuTemp
                  onPicked: root.persistSetting("showCpuTemp", !root.showCpuTemp)
                }
                ModeChip {
                  label: "󰾲 GPU"
                  selected: root.showGpu
                  onPicked: root.persistSetting("showGpu", !root.showGpu)
                }
                ModeChip {
                  label: "󰔏 GPU Temp"
                  selected: root.showGpuTemp
                  onPicked: root.persistSetting("showGpuTemp", !root.showGpuTemp)
                }
                ModeChip {
                  label: " RAM"
                  selected: root.showRam
                  onPicked: root.persistSetting("showRam", !root.showRam)
                }
                ModeChip {
                  label: "\uDB80\uDE10 Fan"
                  selected: root.showFan
                  onPicked: root.persistSetting("showFan", !root.showFan)
                }
                ModeChip {
                  label: "󰋊 Disk"
                  selected: root.showDisk
                  onPicked: root.persistSetting("showDisk", !root.showDisk)
                }
              }
            }

            // RAM Format
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "RAM"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "Used/Total"
                  selected: root.ramFormat === "used/total"
                  onPicked: root.persistSetting("ramFormat", "used/total")
                }
                ModeChip {
                  label: "Used"
                  selected: root.ramFormat === "used"
                  onPicked: root.persistSetting("ramFormat", "used")
                }
                ModeChip {
                  label: "Percent"
                  selected: root.ramFormat === "percent"
                  onPicked: root.persistSetting("ramFormat", "percent")
                }
                ModeChip {
                  label: "Free"
                  selected: root.ramFormat === "free"
                  onPicked: root.persistSetting("ramFormat", "free")
                }
                ModeChip {
                  label: "Available"
                  selected: root.ramFormat === "available"
                  onPicked: root.persistSetting("ramFormat", "available")
                }
              }
            }

            // Disk Format
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Disk"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "Percent"
                  selected: root.diskFormat === "percent"
                  onPicked: root.persistSetting("diskFormat", "percent")
                }
                ModeChip {
                  label: "Used/Total"
                  selected: root.diskFormat === "used/total"
                  onPicked: root.persistSetting("diskFormat", "used/total")
                }
                ModeChip {
                  label: "Used"
                  selected: root.diskFormat === "used"
                  onPicked: root.persistSetting("diskFormat", "used")
                }
                ModeChip {
                  label: "Free"
                  selected: root.diskFormat === "free"
                  onPicked: root.persistSetting("diskFormat", "free")
                }
              }
            }

            // Temperature Unit
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Unit"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "°C  Celsius"
                  selected: !root.fahrenheit
                  onPicked: root.persistSetting("fahrenheit", false)
                }
                ModeChip {
                  label: "°F  Fahrenheit"
                  selected: root.fahrenheit
                  onPicked: root.persistSetting("fahrenheit", true)
                }
              }
            }

            // Temp Format
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Temp"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: root.fahrenheit ? "45°F" : "45°C"
                  selected: root.tempFormat === "degree-unit"
                  onPicked: root.persistSetting("tempFormat", "degree-unit")
                }
                ModeChip {
                  label: "45°"
                  selected: root.tempFormat === "degree"
                  onPicked: root.persistSetting("tempFormat", "degree")
                }
                ModeChip {
                  label: root.fahrenheit ? "45F" : "45C"
                  selected: root.tempFormat === "unit"
                  onPicked: root.persistSetting("tempFormat", "unit")
                }
                ModeChip {
                  label: root.fahrenheit ? "45f" : "45c"
                  selected: root.tempFormat === "unit-lower"
                  onPicked: root.persistSetting("tempFormat", "unit-lower")
                }
                ModeChip {
                  label: "45"
                  selected: root.tempFormat === "bare"
                  onPicked: root.persistSetting("tempFormat", "bare")
                }
              }
            }

            // Bar gauges — compact and full mode extras. Icons mode shows
            // figures instead, labels mode never draws gauges; the toggles
            // still persist for when the mode changes back.
            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(48)
                anchors.verticalCenter: parent.verticalCenter
                text: "Bars"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Flow {
                width: parent.width - Style.space(56)
                spacing: Style.space(4)

                ModeChip {
                  label: "Gauges"
                  selected: root.showGauges
                  onPicked: root.persistSetting("showGauges", !root.showGauges)
                }
                ModeChip {
                  label: "Figures"
                  selected: root.showValues
                  onPicked: root.persistSetting("showValues", !root.showValues)
                }
              }
            }
          }
        }

        // Two-column history block: CPU + Memory side by side on the first
        // line, Temperature + Fan speed on the second, so the whole trend view
        // reads as one compact 2x2 grid ahead of the process lists.
        Row {
          width: parent.width
          spacing: Style.space(12)

          HistoryGraph {
            title: "CPU"
            userWidth: (parent.width - parent.spacing) / 2
            seriesValues: hw.cpuHistory
            seriesSpec: [
              { key: "user",   label: "user",   color: Color.accent },
              { key: "system", label: "system", color: root.hotColor },
              { key: "iowait", label: "iowait", color: root.warm(root.baseColor, 0.65) }
            ]
            currentText: hw.cpuPercent >= 0 ? (Math.round(hw.cpuPercent) + "%") : "–"
            currentColor: root.warm(root.baseColor, Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent))
          }

          HistoryGraph {
            title: "Memory"
            userWidth: (parent.width - parent.spacing) / 2
            seriesValues: hw.memHistory
            seriesSpec: [
              { key: "apps",   label: "apps",   color: root.hotColor },
              { key: "cache",  label: "cache",  color: Color.accent },
              { key: "buffer", label: "buffers", color: root.warm(root.baseColor, 0.65) }
            ]
            currentText: hw.memory && hw.memory.usedPct >= 0 ? (Math.round(hw.memory.usedPct) + "%") : (hw.memPercent >= 0 ? (Math.round(hw.memPercent) + "%") : "–")
            currentColor: root.warm(root.baseColor, Model.severity(hw.memory ? hw.memory.usedPct : hw.memPercent, root.warnPercent, root.criticalPercent))
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(12)

          HistoryGraph {
            title: "Temperature"
            userWidth: (parent.width - parent.spacing) / 2
            values: hw.tempHistory
            placeholder: hw.hasTempSensor ? "collecting samples…" : "no temperature sensor"
            currentText: hw.cpuTempC > 0 ? Model.formatTemp(hw.cpuTempC, root.fahrenheit) : "–"
            currentColor: root.tempColor(hw.cpuTempC)
          }

          HistoryGraph {
            title: "Fan Speed"
            userWidth: (parent.width - parent.spacing) / 2
            values: hw.fanHistory
            placeholder: hw.hasFanSensor ? "collecting samples…" : "no fan sensor"
            currentText: hw.fanRpm >= 0 ? Model.formatRpm(hw.fanRpm) : "–"
            currentColor: root.warm(root.baseColor, root.fanSeverity(hw.fanRpm))
          }
        }

        // Graphics Telemetry Section (if GPU present)
        Rectangle {
          width: parent.width
          implicitHeight: gpuCol.implicitHeight + Style.space(24)
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
          border.width: 1
          radius: Style.cornerRadius
          visible: hw.hasGpu

          Column {
            id: gpuCol
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "󰾲"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: hw.gpuInfo && hw.gpuInfo.name ? hw.gpuInfo.name : "Graphics Adapter"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                wrapMode: Text.Wrap
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // VRAM Meter
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: hw.gpuVramTotalBytes > 0

              Row {
                width: parent.width

                Text {
                  id: vramLabel
                  textFormat: Text.PlainText
                  text: "VRAM"
                  color: Qt.darker(root.baseColor, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Item {
                  width: Math.max(0, parent.width - vramLabel.implicitWidth - vramValue.implicitWidth)
                  height: 1
                }

                Text {
                  id: vramValue
                  textFormat: Text.PlainText
                  text: hw.gpuVramTotalBytes > 0 ? (Model.formatGib(Model.gibFromBytes(hw.gpuVramUsedBytes)) + " / " + Model.formatGib(Model.gibFromBytes(hw.gpuVramTotalBytes)) + " GiB (" + Math.round(hw.gpuVramPercent) + "%)") : "–"
                  color: root.warm(root.baseColor, Model.severity(hw.gpuVramPercent, root.warnPercent, root.criticalPercent))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: height / 2
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  radius: parent.radius
                  color: root.warm(root.baseColor, Model.severity(hw.gpuVramPercent, root.warnPercent, root.criticalPercent))
                  width: hw.gpuVramPercent >= 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * (hw.gpuVramPercent / 100))) : 0
                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(16)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair { label: "Load"; value: hw.gpuPercent >= 0 ? Model.formatPercent(hw.gpuPercent) : "–" }
                InfoPair {
                  label: "Temperature"
                  value: hw.gpuTempC > 0 ? Model.formatTemp(hw.gpuTempC, root.fahrenheit) : "–"
                  valueColor: root.tempColor(hw.gpuTempC)
                }
                InfoPair { label: "Power"; value: hw.gpuWatts >= 0 ? Model.formatWatts(hw.gpuWatts) : "–" }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair { label: "Clock"; value: hw.gpuMhz > 0 ? Model.formatGhz(hw.gpuMhz) : "–" }
                InfoPair { label: "Fan"; value: hw.gpuRpm >= 0 ? Model.formatRpm(hw.gpuRpm) : "–" }
                InfoPair { label: "Driver"; value: hw.gpuInfo && hw.gpuInfo.kind ? String(hw.gpuInfo.kind) : "–" }
              }
            }
          }
        }

        // Storage Telemetry Section
        Rectangle {
          width: parent.width
          implicitHeight: diskCol.implicitHeight + Style.space(24)
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
          border.width: 1
          radius: Style.cornerRadius
          visible: hw.diskInfo && hw.diskInfo.root !== null

          Column {
            id: diskCol
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            Row {
              width: parent.width

              Row {
                spacing: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  textFormat: Text.PlainText
                  text: "󰋊"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Storage"
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Item {
                width: Math.max(0, parent.width - ioRow.implicitWidth - Style.space(90))
                height: 1
              }

              // Realtime I/O rate on the right of header
              Row {
                id: ioRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: "▲ " + Model.formatBytesRate(hw.diskReadBytesSec)
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  textFormat: Text.PlainText
                  text: "▼ " + Model.formatBytesRate(hw.diskWriteBytesSec)
                  color: root.baseColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Root partition meter
            Column {
              width: parent.width
              spacing: Style.space(4)
              property var rootMount: hw.diskInfo && hw.diskInfo.root ? hw.diskInfo.root : null
              readonly property real pct: rootMount ? rootMount.percent : 0

              Row {
                width: parent.width

                Text {
                  id: diskRootLabel
                  textFormat: Text.PlainText
                  text: "Root ( / )"
                  color: Qt.darker(root.baseColor, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Item {
                  width: Math.max(0, parent.width - diskRootLabel.implicitWidth - diskRootValue.implicitWidth)
                  height: 1
                }

                Text {
                  id: diskRootValue
                  textFormat: Text.PlainText
                  text: rootMount ? (Model.formatGib(Model.gibFromBytes(rootMount.usedBytes)) + " / " + Model.formatGib(Model.gibFromBytes(rootMount.totalBytes)) + " GiB (" + Math.round(pct) + "%)") : "–"
                  color: root.warm(root.baseColor, Model.severity(pct, root.warnPercent, root.criticalPercent))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: height / 2
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Math.max(height, parent.width * Math.min(100, Math.max(0, pct)) / 100)
                  radius: height / 2
                  color: root.warm(root.baseColor, Model.severity(pct, root.warnPercent, root.criticalPercent))
                }
              }
            }

            // Other mounted filesystems (if any)
            Repeater {
              model: hw.diskInfo && hw.diskInfo.mounts ? hw.diskInfo.mounts.filter(function(m) { return m.target !== "/" }) : []
              delegate: Column {
                required property var modelData
                width: parent.width
                spacing: Style.space(2)

                Row {
                  width: parent.width

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.target
                    color: Qt.darker(root.baseColor, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                    width: Math.min(implicitWidth, Style.space(160))
                  }

                  Item {
                    width: Math.max(0, parent.width - Style.space(160) - otherDiskVal.implicitWidth)
                    height: 1
                  }

                  Text {
                    id: otherDiskVal
                    textFormat: Text.PlainText
                    text: Model.formatGib(Model.gibFromBytes(modelData.usedBytes)) + " / " + Model.formatGib(Model.gibFromBytes(modelData.totalBytes)) + " GiB (" + Math.round(modelData.percent) + "%)"
                    color: root.warm(root.baseColor, Model.severity(modelData.percent, root.warnPercent, root.criticalPercent))
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(4)
                  radius: height / 2
                  color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)

                  Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.max(height, parent.width * Math.min(100, Math.max(0, modelData.percent)) / 100)
                    radius: height / 2
                    color: root.warm(root.baseColor, Model.severity(modelData.percent, root.warnPercent, root.criticalPercent))
                  }
                }
              }
            }
          }
        }

        // Two short process lists — Heaviest CPU, Heaviest Memory — are the
        // reason the panel exists. Only rows owned by the desktop user offer
        // consent-confirmed Quit / Force actions; OS rows carry a system tag.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.Wrap
          visible: !hw.processReport.ok
          text: "Process survey unavailable."
          color: root.dimColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ProcessSection {
          title: "Heaviest CPU"
          glyph: "\uF4BC"
          listModel: root.processCpuList
          scope: "cpu"
          emptyText: "No process is over " + root.cpuThresholdPct + "% core right now."
        }

        ProcessSection {
          title: "Heaviest Memory"
          glyph: "\uEFC5"
          listModel: root.processMemList
          scope: "mem"
          emptyText: "No process is over " + root.memShowMib + " MiB resident right now."
        }

        // Bottom breathing room spacer to guarantee zero clipping
        Item {
          width: parent.width
          height: Style.space(12)
        }
      }
    }
  }

  // Interactive settings chip
  component ModeChip: Rectangle {
    id: chip
    property string label: ""
    property bool selected: false
    property color activeColor: root.hotColor
    // When false the chip ignores its own hover so a surrounding row's hover
    // state stays authoritative (stops the show-on-hover toggling).
    property bool hoverable: true
    signal picked()

    implicitWidth: chipLabel.implicitWidth + Style.space(12)
    implicitHeight: chipLabel.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: chip.selected ? activeColor : (chipMouse.containsMouse ? Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.18) : Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10))
    border.color: chip.selected ? activeColor : (chipMouse.containsMouse ? Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.65) : Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.45))
    border.width: 1

    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on border.color { ColorAnimation { duration: 140 } }

    scale: chipMouse.pressed ? 0.95 : 1
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label
      color: chip.selected ? Color.foreground : root.baseColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: chip.selected
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: chip.hoverable
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.picked()
    }
  }

  // A titled, capped process list. Only user-owned rows offer
  // consent-confirmed Quit and Force actions; OS rows show a system tag.
  // The scope only changes which metric is highlighted.
  component ProcessSection: Rectangle {
    id: section
    property string title: ""
    property string glyph: ""
    property var listModel: []
    property string scope: "cpu"
    property string emptyText: ""

    width: parent.width
    implicitHeight: scCol.implicitHeight + Style.space(24)
    color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
    border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
    border.width: 1
    radius: Style.cornerRadius

    Column {
      id: scCol
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          id: secGlyph
          textFormat: Text.PlainText
          text: section.glyph
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: secTitle
          textFormat: Text.PlainText
          text: section.title
          color: root.baseColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Item {
          width: Math.max(0, parent.width
            - secGlyph.implicitWidth
            - secTitle.implicitWidth
            - parent.spacing * 2)
          height: 1
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        visible: hw.processReport.ok && section.listModel.length === 0
        text: section.emptyText
        color: root.dimColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Repeater {
        model: section.listModel
        delegate: ProcessRow {
          width: parent.width
          entry: modelData
          scope: section.scope
          pending: root.pendingPid === entry.pid
          pendingSignal: root.pendingSig
          pendingComm: root.pendingComm
          isUser: entry && entry.uid === root.ownUid
          baseColor: root.baseColor
          hotColor: root.hotColor
          fontFamily: root.fontFamily
          onQuitRequested: root.requestAction(entry, "term")
          onForceRequested: root.requestAction(entry, "kill")
          onConfirmed: root.confirmAction()
          onCancelled: root.cancelAction()
        }
      }
    }
  }

  // A titled history graph card used twice: CPU load and memory usage, shown as
  // a pair right above the process lists. Samples are 0-100 percent values
  // drawn as square pixel blocks shading from a translucent accent tint at
  // the baseline up to hot red at the top of a full column.
  component HistoryGraph: Rectangle {
    id: graph
    property string title: ""
    property var values: []
    // Stacked mode: `seriesValues` holds one object per sample with a numeric
    // field per series (say {user, system, iowait}), and `seriesSpec` lists
    // them bottom-up as {key, label, color}. Plain scalar mode uses `values`.
    property var seriesValues: null
    property var seriesSpec: null
    property string currentText: ""
    property color currentColor: Color.accent
    // Explicit width given by a grid cell; -1 keeps the old full-width look.
    property real userWidth: -1
    property string placeholder: "collecting samples…"

    readonly property bool stacked: graph.seriesValues !== null && graph.seriesValues !== undefined
      && graph.seriesSpec !== null && graph.seriesSpec !== undefined && graph.seriesSpec.length > 0

    width: graph.userWidth >= 0 ? graph.userWidth : parent.width
    implicitHeight: graphCol.implicitHeight + Style.space(24)
    color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
    border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
    border.width: 1
    radius: Style.cornerRadius

    Column {
      id: graphCol
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(8)

      Row {
        width: parent.width

        Text {
          id: hgTitle
          textFormat: Text.PlainText
          text: graph.title
          color: root.baseColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Item {
          width: Math.max(0, parent.width - hgTitle.implicitWidth - hgCur.implicitWidth)
          height: 1
        }

        Text {
          id: hgCur
          textFormat: Text.PlainText
          text: graph.currentText
          color: graph.currentColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      // Series legend — only the stacked load cards (CPU, memory) carry one;
      // temperature and fan are single-tone so a legend would be noise.
      Row {
        visible: graph.stacked
        spacing: Style.space(10)

        Repeater {
          model: graph.seriesSpec
          delegate: Row {
            spacing: Style.space(4)

            Rectangle {
              width: Style.space(6)
              height: Style.space(6)
              radius: 1.5
              color: modelData.color
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: root.dimColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Item {
        id: graphArea
        width: parent.width
        height: Style.space(55)

        readonly property int cols: graph.stacked
          ? (graph.seriesValues ? graph.seriesValues.length : 0)
          : (graph.values ? graph.values.length : 0)
        readonly property real colWidth: width / Math.max(1, cols)

        // Bottom-up ramp shared by every scalar column: a cool translucent
        // accent at the baseline rising to urgent red at the top, so a
        // taller column reads hotter than a short one — bright on top means
        // hotter/faster, cool at the bottom means idle.
        readonly property color barTop: root.hotColor
        readonly property color barBottom: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.6)
        readonly property int block: Math.max(2, Math.min(5, Math.floor(colWidth - 1)))
        readonly property int stride: block + 1
        readonly property int maxBlocks: Math.max(1, Math.floor(height / stride))

        // Square-pixel tint at a fraction up the column: cool accent at 0,
        // urgent red at 1.
        function rampColor(f) {
          var t = Math.max(0, Math.min(1, f))
          return Qt.rgba(barBottom.r + (barTop.r - barBottom.r) * t,
                          barBottom.g + (barTop.g - barBottom.g) * t,
                          barBottom.b + (barTop.b - barBottom.b) * t,
                          barBottom.a + (barTop.a - barBottom.a) * t)
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: graphArea.cols < 2
          text: graph.placeholder
          color: root.dimColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Square-pixel columns for every card. Scalar graphs (temperature, fan)
        // ramp a column from cool accent at the baseline to hot red at the
        // top; stacked graphs (CPU, memory)
        // colour each pixel by the series it belongs to — user/system/iowait or
        // apps/cache/buffers — so they share the exact look of the thermals.
        Repeater {
          width: graphArea.width
          height: graphArea.height
          model: graphArea.cols
          delegate: Item {
            id: col
            readonly property int colIndex: index
            readonly property real sample: {
              var raw = Number(graph.values[index] || 0)
              return Math.max(0, Math.min(100, raw))
            }
            readonly property int blocks: Math.round(graphArea.maxBlocks * col.sample / 100)

            // Stacked mode: a bottom-up list of pixel colours, one per square,
            // drawn in series order (series 0 at the baseline).
            readonly property var blockTints: (function () {
              if (!graph.stacked) return []
              var specs = graph.seriesSpec
              var entry = graph.seriesValues[colIndex]
              if (!entry) return []
              var tints = []
              for (var i = 0; i < specs.length; i++) {
                var p = Number(entry[specs[i].key])
                if (!isFinite(p)) p = 0
                var n = Math.min(
                  Math.round(graphArea.maxBlocks * Math.max(0, Math.min(100, p)) / 100),
                  Math.max(0, graphArea.maxBlocks - tints.length))
                var c = specs[i].color
                for (var b = 0; b < n; b++) tints.push(c)
              }
              return tints
            })()

            readonly property int totalBlocks: graph.stacked
              ? col.blockTints.length
              : Math.max(0, col.blocks)

            width: graphArea.colWidth
            height: graphArea.height
            x: index * graphArea.colWidth
            clip: true

            Repeater {
              model: col.totalBlocks
              delegate: Rectangle {
                width: graphArea.block
                height: graphArea.block
                x: Math.max(0, Math.floor((col.width - graphArea.block) / 2))
                y: graphArea.height - (index + 1) * graphArea.stride
                color: graph.stacked
                  ? col.blockTints[index]
                  : graphArea.rampColor((index + 0.5) / Math.max(1, col.totalBlocks))
              }
            }
          }
        }
      }
    }
  }

  component ProcessRow: Rectangle {
    id: prow
    property var entry: null
    property string scope: "cpu"
    property bool isUser: true
    property bool pending: false
    property string pendingSignal: ""
    property string pendingComm: ""
    property color baseColor: root.baseColor
    property color hotColor: root.hotColor
    property string fontFamily: root.fontFamily
    signal quitRequested()
    signal forceRequested()
    signal confirmed()
    signal cancelled()

    // Touch/keyboard path to the kill chips: tapping a user-owned row pins
    // its Quit / Force pair open, since hover alone never fires on touch.
    property bool pinned: false

    // Fixed width of the trailing action column (chips or the pending Yes/No).
    // A named constant keeps the elided args binding honest: the old
    // `parent.children[3].width` form resolved to zero because it evaluated
    // before child 3 existed, so the cmdline swallowed the whole row and the
    // chips were pushed past the panel's right edge.
    readonly property real actionsWidth: Style.space(88)

    implicitWidth: parent.width
    height: prowRow.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    // The row background plus the action column mark ownership: user-owned
    // rows stay neutral (brightening on hover) and reveal kill chips;
    // OS rows keep a constant faint tint, never gain chips, and carry a
    // dim "system" tag instead.
    color: prowMouse.containsMouse
      ? Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.06)
      : (prow.isUser ? "transparent" : Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04))
    Behavior on color { ColorAnimation { duration: 120 } }

    MouseArea {
      id: prowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      onClicked: {
        if (prow.isUser && !prow.pending) prow.pinned = !prow.pinned
      }
    }

    Row {
      id: prowRow
      anchors.fill: parent
      anchors.margins: Style.space(4)
      spacing: Style.space(10)

      // Scope-specific metric, highlighted: CPU% for the Heaviest CPU list,
      // resident memory for Heaviest Memory. Single line of type, name,
      // then cmdline.
      Text {
        textFormat: Text.PlainText
        width: Style.space(52)
        text: prow.metricText
        color: prow.warmByMetric
        font.family: prow.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: prowComm
        textFormat: Text.PlainText
        text: entry ? entry.comm : ""
        color: prow.baseColor
        font.family: prow.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        wrapMode: Text.NoWrap
        width: Math.max(0, parent.width
          - Style.space(52)
          - prowComm.implicitWidth
          - prow.actionsWidth
          - parent.spacing * 3)
        elide: Text.ElideRight
        text: entry && entry.args !== "" && entry.args !== entry.comm ? String(entry.args) : ""
        color: Qt.darker(prow.baseColor, 1.3)
        font.family: prow.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }

      // Action column: Quit / Force only exist for processes owned by the
      // desktop user — everything else is the OS's, not yours, and gets a
      // "system" tag instead of a kill affordance. The explicit implicitHeight
      // makes the row grow to fit the chips instead of letting them overflow
      // a text-height row.
      Item {
        id: prowAction
        width: prow.actionsWidth
        implicitHeight: Style.space(22)

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !prow.isUser && !prow.pending
          text: "system"
          color: Qt.darker(prow.baseColor, 1.5)
          font.family: prow.fontFamily
          font.pixelSize: Style.font.caption
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          // Only user-owned rows get kills, while the pointer rests on the
          // row or a tap pins them open — quiet rows stay clean and the
          // panel only flashes controls where you are actually looking.
          visible: prow.isUser && !prow.pending && (prowMouse.containsMouse || prow.pinned)

          ModeChip {
            label: "Quit"
            selected: false
            hoverable: false
            onPicked: prow.quitRequested()
          }
          ModeChip {
            label: "Force"
            selected: false
            activeColor: prow.hotColor
            hoverable: false
            onPicked: prow.forceRequested()
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          visible: prow.pending

          Text {
            textFormat: Text.PlainText
            text: (prow.pendingSignal === "kill" ? "Force " : "Quit ") + Model.clampText(prow.pendingComm, 10) + "?"
            color: prow.hotColor
            font.family: prow.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          ModeChip {
            label: "Yes"
            selected: true
            activeColor: prow.hotColor
            onPicked: prow.confirmed()
          }
          ModeChip {
            label: "No"
            selected: false
            onPicked: prow.cancelled()
          }
        }
      }
    }

    readonly property string metricText: {
      if (!entry) return "–"
      if (scope === "mem") {
        if (!isFinite(entry.rssKib) || entry.rssKib < 0) return "–"
        return Model.formatKib(entry.rssKib)
      }
      if (!isFinite(entry.cpuPct) || entry.cpuPct < 0) return "–"
      return entry.cpuPct.toFixed(1) + "%"
    }

    readonly property color warmByMetric: {
      if (!entry) return Qt.darker(baseColor, 1.4)
      var t = 0
      if (scope === "mem") {
        if (!isFinite(entry.rssKib) || entry.rssKib < 0) return Qt.darker(baseColor, 1.4)
        t = Math.min(1, Math.max(0, (entry.rssKib / 1048576 - 1) / 3))
      } else {
        if (!isFinite(entry.cpuPct) || entry.cpuPct < 0) return Qt.darker(baseColor, 1.4)
        t = Math.min(1, Math.max(0, (entry.cpuPct - 60) / 80))
      }
      return Qt.rgba(baseColor.r + (hotColor.r - baseColor.r) * t,
                     baseColor.g + (hotColor.g - baseColor.g) * t,
                     baseColor.b + (hotColor.b - baseColor.b) * t,
                     baseColor.a)
    }
  }

  component InfoPair: Row {
    id: infoPairRoot
    property string label: ""
    property string value: ""
    property color valueColor: root.baseColor

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: ipLabel
      textFormat: Text.PlainText
      text: infoPairRoot.label
      color: Qt.darker(root.baseColor, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Item {
      width: Math.max(0, parent.width - ipLabel.implicitWidth - ipValue.implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      id: ipValue
      textFormat: Text.PlainText
      text: infoPairRoot.value
      color: infoPairRoot.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }
}
