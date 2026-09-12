.pragma library

// Pure parsing and formatting for the hardware readouts. Everything here takes
// raw file text or numbers and returns plain values, so the sampling in
// Service.qml and the drawing in Widget.qml never have to agree on anything
// beyond these shapes.

var KIB_PER_GIB = 1048576
var BYTES_PER_GIB = 1073741824

function toNumber(value, fallback) {
  var n = Number(String(value).trim())
  return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

// ------------------------------------------------------------------- probe

function parseProbe(raw) {
  var empty = { ok: false, cpu: { model: "CPU", cores: 0, threads: 0 }, gpus: [], fan: null }
  var text = String(raw || "").trim()
  if (text === "") return empty
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return empty
    return {
      ok: true,
      cpu: parsed.cpu || empty.cpu,
      gpus: parsed.gpus instanceof Array ? parsed.gpus : [],
      fan: parsed.fan || null
    }
  } catch (e) {
    return empty
  }
}

// Pick which discovered card the widget reports on. `auto` prefers a
// discrete GPU when more than one card is present: hw-probe lists sysfs
// cards before NVIDIA (cheaper counters are probed first), so on an
// APU+dGPU hybrid the first entry is the integrated GPU nobody asked about.
// Single-GPU machines and an explicit preference are unaffected.
function pickGpu(gpus, preference) {
  if (!(gpus instanceof Array) || gpus.length === 0) return null
  var want = String(preference === undefined || preference === null ? "auto" : preference).trim().toLowerCase()
  if (want === "" || want === "auto") {
    if (gpus.length > 1) {
      for (var d = 0; d < gpus.length; d++) {
        if (String(gpus[d].kind || "").toLowerCase() === "nvidia") return gpus[d]
      }
    }
    return gpus[0]
  }

  var index = parseInt(want, 10)
  if (isFinite(index) && index >= 0 && index < gpus.length) return gpus[index]

  // Otherwise treat it as a substring match on card, kind, or name — so
  // "card1", "amdgpu", and "9070" all select the same GPU.
  for (var i = 0; i < gpus.length; i++) {
    var gpu = gpus[i]
    var haystack = [gpu.card, gpu.kind, gpu.name].join(" ").toLowerCase()
    if (haystack.indexOf(want) !== -1) return gpu
  }
  return gpus[0]
}

// The other GPU on a two-card machine, so the panel can show an integrated
// and a discrete card side by side instead of only whichever `pickGpu` chose.
// Reference identity, not a deep compare: `primary` is always one of `gpus`'s
// own entries.
function pickOtherGpu(gpus, primary) {
  if (!(gpus instanceof Array) || !primary) return null
  for (var i = 0; i < gpus.length; i++) {
    if (gpus[i] !== primary) return gpus[i]
  }
  return null
}

// --------------------------------------------------------------------- cpu

// The aggregate line of /proc/stat holds cumulative jiffies since boot:
// cpu user nice system idle iowait irq softirq steal guest guest_nice
function parseCpuJiffies(raw) {
  var text = String(raw || "")
  var end = text.indexOf("\n")
  var line = end === -1 ? text : text.substring(0, end)
  var parts = line.replace(/\s+/g, " ").split(" ")
  if (parts.length < 5 || parts[0] !== "cpu") return null

  var total = 0
  // Fields past `steal` are already counted inside user/nice, so stop at 8.
  for (var i = 1; i < parts.length && i <= 8; i++) total += toNumber(parts[i])
  // iowait is time with nothing to run, so it belongs with idle rather than
  // being charged to a process — this matches what top and btop report.
  var idle = toNumber(parts[4]) + toNumber(parts[5])
  // The stack the graph plots: user+nice is userland, system+irq+softirq is
  // the kernel, iowait is space waiting on the disk. Each is a delta share.
  return {
    total: total,
    idle: idle,
    user: toNumber(parts[1]) + toNumber(parts[2]),
    system: toNumber(parts[3]) + toNumber(parts[6]) + toNumber(parts[7]),
    iowait: toNumber(parts[5])
  }
}

// Usage is a ratio of jiffie deltas, not of wall-clock time, so an uneven
// sampling interval cannot skew it.
function cpuUsage(previous, current) {
  if (!previous || !current) return -1
  var totalDelta = current.total - previous.total
  var idleDelta = current.idle - previous.idle
  if (totalDelta <= 0) return -1
  return clamp(100 * (1 - idleDelta / totalDelta), 0, 100)
}

// Per-component deltas as percentages of machine capacity, so the three
// values stack to roughly the busy figure. `busy` is the headline number.
function cpuStack(previous, current) {
  if (!previous || !current) return null
  var totalDelta = current.total - previous.total
  if (totalDelta <= 0) return null
  function share(a, b) {
    return clamp(100 * (b - a) / totalDelta, 0, 100)
  }
  return {
    user: share(previous.user, current.user),
    system: share(previous.system, current.system),
    iowait: share(previous.iowait, current.iowait),
    busy: cpuUsage(previous, current)
  }
}

// Average current clock across every thread. /proc/cpuinfo is the one place
// that reports it without globbing 32 cpufreq directories.
function averageMhz(raw) {
  var matches = String(raw || "").match(/^cpu MHz\s*:\s*([\d.]+)/gm)
  if (!matches || matches.length === 0) return 0
  var sum = 0
  for (var i = 0; i < matches.length; i++) sum += toNumber(matches[i].split(":")[1])
  return sum / matches.length
}

function parseLoadAverage(raw) {
  var parts = String(raw || "").trim().split(/\s+/)
  if (parts.length < 3) return null
  return { one: toNumber(parts[0]), five: toNumber(parts[1]), fifteen: toNumber(parts[2]) }
}

// ------------------------------------------------------------------ memory

// MemAvailable is the kernel's own estimate of what a new allocation can get
// without swapping, which is what "used" should be measured against — total
// minus free counts reclaimable page cache as used and always reads ~90%.
function parseMemory(raw) {
  var text = String(raw || "")
  function field(key) {
    var match = text.match(new RegExp("^" + key + ":\\s+(\\d+)", "m"))
    return match ? toNumber(match[1]) : 0
  }

  var total = field("MemTotal")
  var available = field("MemAvailable")
  if (total <= 0) return null
  if (available <= 0) available = field("MemFree") + field("Buffers") + field("Cached")

  var swapTotal = field("SwapTotal")
  var free = field("MemFree")
  var buffers = field("Buffers")
  var cached = field("Cached") + field("SReclaimable")
  // "apps" is what free calls used minus buffers/cache: anonymous pages that
  // only look cheap because the kernel can reclaim the file cache. The three
  // buckets below sum to about MemTotal; the spare is unmapped free memory.
  var apps = total - free - buffers - cached
  return {
    totalKib: total,
    availableKib: available,
    usedKib: Math.max(0, total - available),
    buffersKib: buffers,
    cachedKib: cached,
    usedAppsKib: Math.max(0, apps),
    swapTotalKib: swapTotal,
    swapUsedKib: Math.max(0, swapTotal - field("SwapFree")),
    percent: clamp(100 * (total - available) / total, 0, 100),
    usedPct: clamp(100 * apps / total, 0, 100),
    bufferPct: clamp(100 * buffers / total, 0, 100),
    cachePct: clamp(100 * cached / total, 0, 100)
  }
}

// ------------------------------------------------------------------ nvidia
//
// nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,
// memory.total,power.draw,clocks.current.graphics --format=csv,noheader,nounits
// Unsupported fields come back as "[N/A]". fan.speed is not queried: it is a
// percent, not an RPM, so it cannot feed the RPM readouts.

function parseNvidia(raw) {
  var line = String(raw || "").trim().split("\n")[0]
  if (!line) return null
  var parts = line.split(",")
  if (parts.length < 4) return null

  function value(index) {
    var text = String(parts[index] || "").trim()
    if (text === "" || text.indexOf("N/A") !== -1) return -1
    return toNumber(text, -1)
  }

  return {
    busy: value(0),
    tempC: value(1),
    vramUsedBytes: value(2) >= 0 ? value(2) * 1048576 : -1,
    vramTotalBytes: value(3) >= 0 ? value(3) * 1048576 : -1,
    watts: parts.length > 4 ? value(4) : -1,
    mhz: parts.length > 5 ? value(5) : -1
  }
}

// -------------------------------------------------------------- formatting

function gibFromKib(kib) {
  return kib / KIB_PER_GIB
}

function gibFromBytes(bytes) {
  return bytes / BYTES_PER_GIB
}

// One decimal below 10 GiB, none above: "9.4G" and "62G" both stay narrow,
// and the bar never reflows as memory crosses a rounding boundary.
function formatGib(gib) {
  if (!isFinite(gib) || gib < 0) return "–"
  if (gib === 0) return "0"
  if (gib < 10) return gib.toFixed(1)
  return String(Math.round(gib))
}

// One decimal always, for the label mode where the figure is the whole point
// and the column is wide enough to carry it.
function formatGibPrecise(gib) {
  if (!isFinite(gib) || gib < 0) return "–"
  return gib.toFixed(1)
}

function formatPercent(value) {
  if (!isFinite(value) || value < 0) return "–"
  return Math.round(value) + "%"
}

// Just the figure, for callers that want to choose their own unit marker.
function tempNumber(celsius, fahrenheit) {
  if (!isFinite(celsius) || celsius <= 0) return "–"
  return String(Math.round(fahrenheit ? celsius * 9 / 5 + 32 : celsius))
}

function formatTemp(celsius, fahrenheit) {
  if (!isFinite(celsius) || celsius <= 0) return "–"
  var deg = Math.round(fahrenheit ? celsius * 9 / 5 + 32 : celsius)
  return deg + "°" + (fahrenheit ? "F" : "C")
}

function formatGhz(mhz) {
  if (!isFinite(mhz) || mhz <= 0) return "–"
  return (mhz / 1000).toFixed(1) + " GHz"
}

function formatWatts(watts) {
  if (!isFinite(watts) || watts < 0) return "–"
  return Math.round(watts) + " W"
}

function formatRpm(rpm) {
  if (!isFinite(rpm) || rpm < 0) return "–"
  return rpm === 0 ? "idle" : Math.round(rpm) + " rpm"
}

// ----------------------------------------------------------------- processes
//
// Process accounting is a few hundred directories in /proc, so the widget hands
// that to proc-probe — a short bash script that takes two /proc snapshots one
// second apart and emits a tab-separated report:
//
//   meta\t<unix-ts>\t<ncpus>\t<active-pid>\t<owner-uid>
//   cpu\t<pid>\t<comm>\t<cpu%>\t<rssKib>\t<uid>\t<args>
//   mem\t[...]

function parseProcessReport(raw) {
  var out = {
    ok: false,
    at: 0,
    nproc: 0,
    activePid: 0,
    uid: -1,
    cpu: [],
    mem: []
  }
  var text = String(raw || "")
  if (text === "") return out

  var lines = text.split("\n")
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var cells = lines[i].split("\t")
    var tag = cells[0]
    if (cells.length < 7 && tag !== "meta") continue

    if (tag === "meta") {
      seen.meta = true
      out.at = toNumber(cells[1])
      out.nproc = toNumber(cells[2])
      out.activePid = toNumber(cells[3])
      out.uid = toNumber(cells[4], -1)
    } else if (tag === "cpu" || tag === "mem") {
      var pid = toNumber(cells[1])
      if (pid <= 0) continue
      seen[tag] = true
      out[tag].push({
        pid: pid,
        comm: cells[2] || "?",
        cpuPct: toNumber(cells[3]),
        rssKib: toNumber(cells[4]),
        uid: toNumber(cells[5], -1),
        args: cells[6] || ""
      })
    }
  }
  out.ok = seen.meta === true && seen.cpu === true
  return out
}

// The shortest reading that still signals magnitude: 862M, 4.1G, 48K.
function formatKib(kib) {
  if (!isFinite(kib) || kib < 0) return "–"
  if (kib >= KIB_PER_GIB) {
    var g = kib / KIB_PER_GIB
    return (g < 10 ? g.toFixed(1) : String(Math.round(g))) + "G"
  }
  if (kib >= 1024) return Math.round(kib / 1024) + "M"
  return Math.round(kib) + "K"
}

// Truncate without splitting a final word mid-way, so rows stay one line.
function clampText(text, width) {
  var out = String(text || "")
  if (out.length <= width) return out
  var cut = out.substring(0, width)
  var space = Math.max(cut.lastIndexOf(" "), cut.lastIndexOf("/"), cut.lastIndexOf("-"))
  if (space >= width * 0.5) cut = cut.substring(0, space)
  return cut + "…"
}

// ----------------------------------------------------------------- severity
//
// 0 while a reading is unremarkable, ramping to 1 as it crosses from `warn` to
// `critical`. Widget.qml mixes the theme foreground toward urgent by this
// amount, so a busy machine warms up gradually instead of flipping to red.

function severity(value, warn, critical) {
  if (!isFinite(value) || value < 0) return 0
  if (value <= warn) return 0
  return clamp((value - warn) / Math.max(1, critical - warn), 0, 1)
}

// Monospace digits are all the same width, so left-padding a reading to the
// width of its widest realistic value keeps the bar from reflowing every time
// a number gains or loses a digit. Values past that width still render — they
// just push the widget wider, which for 100% or 100°C is rare enough to accept.
function padLeft(text, width) {
  var out = String(text)
  while (out.length < width) out = " " + out
  return out
}
