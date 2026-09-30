.pragma library

var UNIT_NAME = "omarchy-fortivpn"
var HELPER_PATH = "/usr/local/libexec/omarchy-fortivpn-helper"
var CONTROLLER_INTERFACE_VERSION = "1"

// Strips anything that could break out of a single "key = value" config
// line (or a stdin read) so a stray newline in a form field can never
// smuggle in a second directive.
function sanitizeField(value) {
  return String(value == null ? "" : value).replace(/[\r\n]/g, "").trim()
}

function isValidHost(h) {
  if (!h || h.length > 255) return false
  return /^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$/.test(h) && !/\.\./.test(h)
}

function isValidPort(p) {
  if (!/^[0-9]{1,5}$/.test(p)) return false
  var num = parseInt(p, 10)
  return num >= 1 && num <= 65535
}

var MAX_GATEWAYS = 5

// Normalizes one or more gateway hosts (comma/space/semicolon-delimited),
// stripping protocol prefixes, preserving per-gateway ports, and validating
// host syntax. Returns { hosts, port, realm, error } — caller must check error.
function parseGateways(rawHost, defaultPort) {
  var raw = sanitizeField(rawHost)
  var items = raw.split(/[,;\s]+/)
  var cleaned = []
  var fallbackPort = defaultPort || "443"
  var detectedRealm = ""

  for (var i = 0; i < items.length; i++) {
    var item = items[i].trim()
    if (!item) continue
    var original = item
    // Reject unsupported protocols (only http:// and https:// are accepted as prefixes).
    if (item.indexOf("://") !== -1) {
      if (item.startsWith("https://")) item = item.substring(8)
      else if (item.startsWith("http://")) item = item.substring(7)
      else {
        return { hosts: "", port: fallbackPort, realm: "", error: "Unsupported protocol in gateway: " + original }
      }
    }
    // Accept at most one path segment as realm (e.g. /vendor); reject /realm/extra.
    if (item.indexOf("/") !== -1) {
      var slashParts = item.split("/")
      if (slashParts.length > 2) {
        return { hosts: "", port: fallbackPort, realm: "", error: "Malformed gateway entry: " + original }
      }
      item = slashParts[0]
      if (!detectedRealm && slashParts[1]) detectedRealm = sanitizeField(slashParts[1])
    }

    var hostPart = item
    var portPart = ""
    var colons = item.split(":")
    if (colons.length > 2) {
      return { hosts: "", port: fallbackPort, realm: "", error: "Malformed gateway entry: " + original }
    }
    if (colons.length === 2) {
      hostPart = colons[0]
      portPart = colons[1]
    }

    if (!isValidHost(hostPart)) {
      return { hosts: "", port: fallbackPort, realm: "", error: "Invalid gateway host: " + original }
    }

    if (portPart !== "") {
      if (!isValidPort(portPart)) {
        return { hosts: "", port: fallbackPort, realm: "", error: "Invalid port in gateway: " + original }
      }
      var hostEntry = hostPart + ":" + portPart
    } else {
      var hostEntry = hostPart
    }

    if (cleaned.indexOf(hostEntry) === -1) {
      cleaned.push(hostEntry)
    }
  }

  if (cleaned.length > MAX_GATEWAYS) {
    return { hosts: "", port: fallbackPort, realm: "", error: "Too many gateways (max " + MAX_GATEWAYS + ")." }
  }

  return {
    hosts: cleaned.join(", "),
    port: fallbackPort,
    realm: detectedRealm,
    error: ""
  }
}

// Secrets may legitimately begin or end with whitespace. Newlines are still
// forbidden because config writes use one stdin line per value.
function sanitizeSecret(value) {
  return String(value == null ? "" : value).replace(/[\r\n]/g, "")
}

// Configuration changes require polkit authentication. Values still travel
// over stdin so passwords never appear in the process list.
function configWriteCommand(keys) {
  return ["pkexec", HELPER_PATH, "write"].concat(keys)
}

function statusCommand() {
  return ["sudo", "-n", HELPER_PATH, "status"]
}

function journalCommand(sinceEpochMs) {
  return ["sudo", "-n", HELPER_PATH, "journal", (sinceEpochMs / 1000).toFixed(3)]
}

function stopCommand() {
  return ["sudo", "-n", HELPER_PATH, "stop"]
}

// A unit that exited non-zero (bad OTP, untrusted cert, ...) lingers in
// "failed" state and blocks reusing the same unit name, so this is run
// before every connect attempt. Harmless no-op when nothing is failed.
function resetFailedCommand() {
  return ["sudo", "-n", HELPER_PATH, "reset"]
}

// No --collect: a failed unit needs to stay observable as "failed" long
// enough for the next is-active poll to see it and pull the journal (that's
// how the untrusted-cert digest gets surfaced). resetFailedCommand() clears
// it explicitly before the next connect instead.
function startCommand(otp) {
  var args = ["sudo", "-n", HELPER_PATH, "start"]
  var code = sanitizeField(otp)
  if (code !== "") args.push(code)
  return args
}

// Normalizes `systemctl is-active` output into a small state enum the
// Service/Panel can switch on directly.
function normalizeActiveState(raw) {
  var text = sanitizeField(raw).toLowerCase()
  if (text === "active") return "connected"
  if (text === "activating" || text === "reloading") return "connecting"
  if (text === "deactivating") return "disconnecting"
  if (text === "failed") return "failed"
  return "disconnected"
}

function parseStatus(text) {
  var fields = {}
  var lines = String(text || "").split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var separator = lines[i].indexOf("=")
    if (separator <= 0) continue
    fields[lines[i].substring(0, separator)] = lines[i].substring(separator + 1)
  }
  if (fields.interfaceVersion !== CONTROLLER_INTERFACE_VERSION || !fields.controllerVersion || !fields.message ||
      fields.dependencyPath === undefined || !/^(true|false)$/.test(fields.trustedCertificate || "") ||
      !/^(ready|not_configured|dependency_missing|config_invalid)$/.test(fields.code || "") ||
      !/^(missing|incomplete|ready|invalid)$/.test(fields.configState || "") ||
      !/^(active|activating|deactivating|failed|inactive)$/.test(fields.unitState || "")) return null
  return fields
}

// openfortivpn's own hint text for an unpinned gateway cert always includes
// the literal flag it wants you to rerun with, followed by the sha256
// digest — match on that shape rather than the surrounding wording, which
// has changed across versions.
function parseCertDigest(text) {
  var body = String(text || "")
  var m = body.match(/--trusted-cert[=\s]+([0-9a-fA-F]{64})(?:[^0-9a-fA-F]|$)/)
  if (m) return m[1].toLowerCase()
  m = body.match(/certificate[^\n]{0,40}sha256[^\n]{0,20}([0-9a-fA-F]{64})(?:[^0-9a-fA-F]|$)/i)
  if (m) return m[1].toLowerCase()
  m = body.match(/sha256\s+digest\s*:[\s\S]{0,80}?([0-9a-fA-F]{64})(?:[^0-9a-fA-F]|$)/i)
  if (m) return m[1].toLowerCase()
  return ""
}

// Best-effort one-line summary of the most recent journal entry for the
// unit, for surfacing under the status line when a connect attempt fails.
function parseFailureSummary(text) {
  var lines = String(text || "").split(/\r?\n/).map(function(l) { return l.trim() }).filter(function(l) { return l !== "" })
  if (lines.length === 0) return ""
  var errorLine = ""
  // openfortivpn's own "ERROR:" line carries the real cause; systemd's
  // trailing "Failed to start …" lines would otherwise win the scan below.
  for (var i = lines.length - 1; i >= 0; i--) {
    var m = lines[i].match(/^ERROR:\s*(.+)$/)
    if (m) { errorLine = m[1]; break }
  }
  for (i = lines.length - 1; errorLine === "" && i >= 0; i--) {
    if (/error|fail|denied|invalid|expired|refused/i.test(lines[i])) errorLine = lines[i]
  }
  var line = errorLine !== "" ? errorLine : lines[lines.length - 1]
  return line.length > 160 ? line.substring(0, 157) + "…" : line
}

if (typeof module !== "undefined") {
  module.exports = {
    UNIT_NAME: UNIT_NAME,
    CONTROLLER_INTERFACE_VERSION: CONTROLLER_INTERFACE_VERSION,
    sanitizeField: sanitizeField,
    sanitizeSecret: sanitizeSecret,
    configWriteCommand: configWriteCommand,
    statusCommand: statusCommand,
    journalCommand: journalCommand,
    stopCommand: stopCommand,
    resetFailedCommand: resetFailedCommand,
    startCommand: startCommand,
    normalizeActiveState: normalizeActiveState,
    parseStatus: parseStatus,
    parseCertDigest: parseCertDigest,
    parseFailureSummary: parseFailureSummary
  }
}
