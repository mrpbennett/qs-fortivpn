.pragma library

var UNIT_NAME = "omarchy-fortivpn"
var HELPER_PATH = "/usr/local/libexec/omarchy-fortivpn-helper"
var CONTROLLER_INTERFACE_VERSION = "1"
// The controller release this plugin ships in scripts/. An older installed
// controller still works if the interface matches, but the panel offers an
// update.
var CONTROLLER_VERSION = "1.2.0"

// Strips anything that could break out of a single "key = value" config
// line (or a stdin read) so a stray newline in a form field can never
// smuggle in a second directive.
function sanitizeField(value) {
  return String(value == null ? "" : value).replace(/[\r\n]/g, "").trim()
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

// Installs or updates the root-owned controller from this plugin's scripts/.
// pkexec shows the standard polkit admin prompt; the installer reads the
// target user from pkexec's PKEXEC_UID, so no user name is passed here.
function installCommand(scriptPath) {
  return ["pkexec", "/usr/bin/bash", scriptPath, "--install-root"]
}

// Qt.resolvedUrl() yields a file:// URL; processes need a plain path.
function localPath(url) {
  return decodeURIComponent(String(url).replace(/^file:\/\//, ""))
}

// True when the installed controller is older than the one this plugin
// ships. Newer or unparsable versions never trigger an update offer.
function controllerUpdateAvailable(installedVersion) {
  var installed = String(installedVersion || "").split(".")
  var shipped = CONTROLLER_VERSION.split(".")
  for (var i = 0; i < shipped.length; i++) {
    var a = parseInt(installed[i] || "0", 10)
    var b = parseInt(shipped[i], 10)
    if (!isFinite(a)) return false
    if (a !== b) return a < b
  }
  return false
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
    CONTROLLER_VERSION: CONTROLLER_VERSION,
    installCommand: installCommand,
    localPath: localPath,
    controllerUpdateAvailable: controllerUpdateAvailable,
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
