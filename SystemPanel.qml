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

  property string mode: "icons"
  property bool showGpu: true
  property bool showCpu: true
  property bool showCpuTemp: true
  property bool showGpuTemp: false
  property bool showRam: true
  property bool showFan: true
  property string ramFormat: "used/total"
  property string tempFormat: "degree-unit"
  property bool settingsOpen: false

  // Process list state. Three fixed lists (Heaviest CPU, Heaviest Memory,
  // Idle Apps) each capped at a handful of rows; pending* is the one-shot
  // confirm state for a kill offered on any row.
  property int topProcessCount: 15
  property int pendingPid: 0
  property string pendingSig: ""
  property string pendingComm: ""

  readonly property int sectionRows: Math.min(Math.max(root.topProcessCount, 1), 5)

  // Heaviest CPU only counts processes pulling more than 10% of a core;
  // Heaviest Memory only counts processes above 200 MiB resident. Both lists
  // still cap rows so the panel stays short.
  //
  // `topup` guarantees the section never renders empty: when fewer processes
  // pass the filter, the remaining slots are filled with the top rows anyway.
  // That keeps at least one Quit / Force affordance on screen no matter how
  // idle the machine is.
  function sliceProcessList(report, key, filter, topup) {
    var arr = report && report.ok ? report[key] : []
    if (arr === undefined || arr === null) arr = []
    var out = []
    for (var i = 0; i < arr.length && out.length < root.sectionRows; i++) {
      if (filter && !filter(arr[i])) continue
      out.push(arr[i])
    }
    if (topup && arr.length > out.length) {
      var seen = {}
      for (var j = 0; j < out.length; j++) seen[out[j].pid] = 1
      for (var k = 0; k < arr.length && out.length < root.sectionRows; k++) {
        if (seen[arr[k].pid]) continue
        out.push(arr[k])
      }
    }
    return out
  }

  readonly property var processCpuList: sliceProcessList(hw.processReport, "cpu", function(e) {
    return e && isFinite(e.cpuPct) && e.cpuPct > 10
  }, true)
  readonly property var processMemList: sliceProcessList(hw.processReport, "mem", function(e) {
    return e && isFinite(e.rssKib) && e.rssKib > 204800
  }, true)
  readonly property var processIdleList: sliceProcessList(hw.processReport, "idle")

  // Owner uid reported by proc-probe's meta line. Only a process owned by this
  // uid may ever be offered a Quit / Force action.
  readonly property int ownUid: hw.processReport && hw.processReport.uid !== undefined ? hw.processReport.uid : -1

  readonly property int idleCount: hw.processReport && hw.processReport.ok ? hw.processReport.idle.length : -1

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
    if (tempC < 50) return dimColor
    var t = Math.min(1, Math.max(0, (tempC - 50) / Math.max(1, criticalTempC - 50)))
    return Qt.rgba(baseColor.r + (hotColor.r - baseColor.r) * t,
                   baseColor.g + (hotColor.g - baseColor.g) * t,
                   baseColor.b + (hotColor.b - baseColor.b) * t,
                   baseColor.a)
  }

  onOpenChanged: {
    if (open) {
      hw.sample()
      hw.refreshProcesses()
    } else {
      root.settingsOpen = false
      root.pendingPid = 0
    }
  }

  focusTarget: keyCatcher
  contentWidth: fittedContentWidth(Style.space(450))
  contentHeight: fittedContentHeight(panelColumn.implicitHeight + Style.space(16), Style.space(960))

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: root.close()
    // root.owner is the Panel widget root (Widget.qml sets owner: root),
    // which is what Bar.switchPanelFrom expects.
    onTabRequested: function(direction) {
      if (root.owner && typeof root.owner.switchPanel === "function") {
        root.owner.switchPanel(direction)
      }
    }
    onTextKey: function(t) {
      if (t === "r" || t === "R") {
        hw.sample()
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
      onTriggered: root.pendingPid = 0
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
              width: parent.width - Style.font.display - Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "Activity Monitor"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                text: (hw.cpuInfo && hw.cpuInfo.model ? hw.cpuInfo.model : "System Telemetry")
                  + (hw.memory && hw.memory.totalKib > 0
                     ? " | " + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + " GiB RAM"
                       + (hw.memory.swapTotalKib > 0
                          ? " | " + Model.formatGib(Model.gibFromKib(hw.memory.swapTotalKib)) + " GiB Swap"
                          : "")
                     : "")
                color: root.dimColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          // Gear Icon for In-Panel Settings
          ModeChip {
            id: settingsButton
            label: "\uF013"
            selected: root.settingsOpen
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onPicked: root.settingsOpen = !root.settingsOpen
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
                  label: "45"
                  selected: root.tempFormat === "bare"
                  onPicked: root.persistSetting("tempFormat", "bare")
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
            currentText: hw.fanRpm > 0 ? Model.formatRpm(hw.fanRpm) : "–"
            currentColor: root.warm(root.baseColor, hw.hasFan ? 0.5 : 0)
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

        // Three short process lists — Heaviest CPU, Heaviest Memory, Idle Apps — are
        // the reason the panel exists. Every row offers consent-confirmed
        // Quit / Force actions.
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
          emptyText: "No running processes."
        }

        ProcessSection {
          title: "Heaviest Memory"
          glyph: "\uEFC5"
          listModel: root.processMemList
          scope: "mem"
          emptyText: "No resident processes."
        }

        ProcessSection {
          title: "Idle Apps"
          glyph: "\uF2A3"
          listModel: root.processIdleList
          scope: "idle"
          emptyText: "Nothing qualifies right now — idle apps need ≤1% core, ≥150 MiB RAM, a window, no focus, and no terminal."
          showMeta: true
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
    property color activeColor: Color.accent
    signal picked()

    implicitWidth: chipLabel.implicitWidth + Style.space(12)
    implicitHeight: chipLabel.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: chip.selected ? activeColor : (chipMouse.containsMouse ? Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.20) : Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12))
    border.color: chip.selected ? activeColor : (chipMouse.containsMouse ? Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.80) : Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.55))
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
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.picked()
    }
  }

  // A titled, capped process list. Every row offers consent-confirmed Quit and
  // Force actions; the scope only changes which metric is highlighted.
  component ProcessSection: Rectangle {
    id: section
    property string title: ""
    property string glyph: ""
    property var listModel: []
    property string scope: "cpu"
    property string emptyText: ""
    property bool showMeta: false

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
            - secCount.implicitWidth
            - parent.spacing * 3)
          height: 1
        }

        Text {
          id: secCount
          textFormat: Text.PlainText
          text: section.showMeta && root.idleCount > 0 ? (root.idleCount + " idle") : ""
          color: root.idleCount > 0 ? root.warm(root.baseColor, 0.5) : root.dimColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
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
  // drawn as square pixel blocks shading from hot red at the baseline up to a
  // translucent accent tint at the top of a full column.
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
    readonly property int sampleCount: graph.stacked
      ? (graph.seriesValues ? graph.seriesValues.length : 0)
      : (graph.values ? graph.values.length : 0)

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

      Item {
        id: graphArea
        width: parent.width
        height: Style.space(55)

        readonly property int cols: graph.stacked
          ? (graph.seriesValues ? graph.seriesValues.length : 0)
          : (graph.values ? graph.values.length : 0)
        readonly property real colWidth: width / Math.max(1, cols)

        // Stacked helpers: `stackPct` clamps one series to 0..100% of machine
        // capacity, `stackBasePx` sums the pixel height of every series below
        // `upTo` in the *column* named by `colIndex`.
        function stackPct(colIndex, key) {
          var samples = graph.seriesValues
          if (!samples || colIndex < 0 || colIndex >= samples.length) return 0
          var entry = samples[colIndex]
          if (!entry) return 0
          var v = Number(entry[key])
          return isFinite(v) ? Math.max(0, Math.min(100, v)) : 0
        }
        function stackBasePx(colIndex, upTo) {
          var hgt = 0
          var specs = graph.seriesSpec
          for (var i = 0; i < upTo && i < specs.length; i++) {
            hgt += Math.round(graphArea.height * graphArea.stackPct(colIndex, specs[i].key) / 100)
          }
          return hgt
        }

        // Bottom-up ramp shared by every column: the base of a column is the
        // urgent red, fading up through orange into a translucent accent tint,
        // so a taller column reads hotter than a short one.
        readonly property color barTop: root.hotColor
        readonly property color barBottom: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.6)
        readonly property int block: Math.max(2, Math.min(5, Math.floor(colWidth - 1)))
        readonly property int stride: block + 1
        readonly property int maxBlocks: Math.max(1, Math.floor(height / stride))

        // Square-pixel tint at a fraction up the column: red at 0, accent at 1.
        function rampColor(f) {
          var t = Math.max(0, Math.min(1, f))
          return Qt.rgba(barTop.r + (barBottom.r - barTop.r) * t,
                         barTop.g + (barBottom.g - barTop.g) * t,
                         barTop.b + (barBottom.b - barTop.b) * t,
                         barTop.a + (barBottom.a - barTop.a) * t)
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

        // Two renderers share this area. Stacked mode draws each series as a
        // full-width horizontal segment per column (used by the CPU and memory
        // graphs); scalar mode keeps the square-pixel columns (temperature,
        // fan speed). No shaders, no per-column animation — a few flat rects.
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

            width: graphArea.colWidth
            height: graphArea.height
            x: index * graphArea.colWidth
            clip: true

            Repeater {
              visible: !graph.stacked
              model: Math.max(0, col.blocks)
              delegate: Rectangle {
                width: graphArea.block
                height: graphArea.block
                x: Math.max(0, Math.floor((col.width - graphArea.block) / 2))
                y: graphArea.height - (index + 1) * graphArea.stride
                color: graphArea.rampColor((index + 0.5) / Math.max(1, col.blocks))
              }
            }

            Repeater {
              visible: graph.stacked
              model: graph.stacked ? graph.seriesSpec.length : 0
              delegate: Rectangle {
                readonly property int sIndex: index
                readonly property real sPct: graphArea.stackPct(col.colIndex, graph.seriesSpec[sIndex].key)
                readonly property real cBase: graphArea.stackBasePx(col.colIndex, sIndex)
                readonly property color sc: graph.seriesSpec[sIndex].color

                width: col.width
                x: 0
                height: Math.max(0, Math.round(graphArea.height * sPct / 100) - (sIndex > 0 ? 1 : 0))
                y: graphArea.height - cBase - height
                visible: height >= 1
                color: Qt.rgba(sc.r, sc.g, sc.b, 0.9)
              }
            }
          }
        }
      }

      // Compact legend for stacked graphs only; scalar graphs stay clean.
      Row {
        width: parent.width
        visible: graph.stacked
        spacing: Style.space(10)
        Repeater {
          model: graph.stacked ? graph.seriesSpec : 0
          delegate: Row {
            spacing: Style.space(4)
            Rectangle {
              width: Style.space(7)
              height: Style.space(7)
              radius: 2
              anchors.verticalCenter: parent.verticalCenter
              color: modelData.color
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.label || modelData.key
              color: root.dimColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }
    }
  }

  component ProcessRow: Rectangle {
    id: prow
    property var entry: null
    property string scope: "idle"
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

    // Fixed width of the trailing action column (chips or the pending Yes/No).
    // A named constant keeps the elided args binding honest: the old
    // `parent.children[3].width` form resolved to zero because it evaluated
    // before child 3 existed, so the cmdline swallowed the whole row and the
    // chips were pushed past the panel's right edge.
    readonly property real actionsWidth: Style.space(88)

    implicitWidth: parent.width
    height: prowRow.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: prowMouse.containsMouse ? Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.06) : "transparent"
    Behavior on color { ColorAnimation { duration: 120 } }

    MouseArea {
      id: prowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    Row {
      id: prowRow
      anchors.fill: parent
      anchors.margins: Style.space(4)
      spacing: Style.space(10)

      // Scope-specific metric, highlighted: CPU% for the Heaviest CPU and Idle Apps
      // lists, resident memory for Heaviest Memory. Single line of type, name,
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

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          visible: prow.isUser && !prow.pending

          ModeChip {
            label: "Quit"
            selected: false
            onPicked: prow.quitRequested()
          }
          ModeChip {
            label: "Force"
            selected: false
            activeColor: prow.hotColor
            onPicked: prow.forceRequested()
          }
        }

        Rectangle {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: sysTag.implicitWidth + Style.space(10)
          implicitHeight: sysTag.implicitHeight + Style.space(6)
          radius: Style.cornerRadius
          visible: !prow.isUser
          color: "transparent"
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.35)
          border.width: 1

          Text {
            id: sysTag
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "system"
            color: root.baseColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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
