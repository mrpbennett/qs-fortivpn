import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// All state for the FortiVPN widget. Passwords and the OTP are never
// persisted; they are cleared promptly after handoff to a Process's stdin.
//
// Connection lifecycle is delegated to systemd (`systemd-run --system`
// launches openfortivpn as a transient root unit; `systemctl is-active`
// polls it; `systemctl stop` tears it down) so there is no pidfile or
// process-tree bookkeeping to get wrong here. See README.md for why.
Item {
  id: root

  property var settings: ({})

  property bool installed: false
  property bool checkedInstalled: false
  property string controllerCode: "incompatible"
  property string controllerMessage: "FortiVPN controller needs installation or update."
  property string configState: "missing"
  // disconnected | connecting | connected | disconnecting | failed
  property string state: "disconnected"
  property bool refreshing: false
  property string lastError: ""
  property string actionStatus: ""
  // Non-empty while a connect attempt is blocked on an unrecognized
  // gateway certificate, holding the sha256 digest openfortivpn reported.
  property string pendingTrustDigest: ""

  readonly property string host: setting("host", "")
  readonly property string port: setting("port", "443")
  readonly property string username: setting("username", "")
  readonly property string realm: setting("realm", "")
  readonly property bool hasPassword: setting("hasPassword", false) === true
  readonly property string trustedCertDigest: setting("trustedCertDigest", "")
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 60)

  readonly property bool configured: configState === "ready"
  readonly property bool connected: state === "connected"
  readonly property bool busy: statusProcess.running || startProcess.running ||
    stopProcess.running || journalProcess.running || writeProcess.running || resetFailedProcess.running
  readonly property bool canConfigure: installed && !busy
  readonly property bool canConnect: installed && controllerCode === "ready" && configured && !busy && state !== "connected" && state !== "connecting"
  // Stop remains available during a controller upgrade so an outdated widget
  // cannot strand an active tunnel.
  readonly property bool canDisconnect: !busy && (state === "connected" || state === "connecting" || !installed)

  signal passwordSaved()
  signal passwordForgotten()
  signal detailsSaved(string host, string port, string username, string realm)
  signal certTrusted(string digest)

  property string _pendingOtp: ""
  property real _attemptStartedAt: 0
  property string _statusOutput: ""
  property string _startOutput: ""
  property string _startError: ""
  property string _writeStdout: ""
  property string _writeStderr: ""
  property string _stopStdout: ""
  property string _stopStderr: ""
  property string _resetStdout: ""
  property string _resetStderr: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // The root-owned controller is the source of truth for dependency,
  // configuration, and lifecycle readiness.
  function refresh() {
    refreshStatus()
  }

  function refreshStatus() {
    if (statusProcess.running) return
    refreshing = true
    _statusOutput = ""
    statusProcess.command = Model.statusCommand()
    statusProcess.running = true
  }

  function fetchFailureDetail() {
    if (journalProcess.running) return
    journalProcess.command = Model.journalCommand(_attemptStartedAt)
    journalProcess.running = true
  }

  function connect(otp) {
    if (!canConnect) return
    pendingTrustDigest = ""
    lastError = ""
    actionStatus = "Connecting…"
    state = "connecting"
    _attemptStartedAt = Date.now()
    _pendingOtp = otp
    _resetStdout = ""
    _resetStderr = ""
    resetFailedProcess.command = Model.resetFailedCommand()
    resetFailedProcess.running = true
  }

  function disconnect() {
    if (!canDisconnect) return
    actionStatus = "Disconnecting…"
    state = "disconnecting"
    _stopStdout = ""
    _stopStderr = ""
    stopProcess.command = Model.stopCommand()
    stopProcess.running = true
  }

  function trustCertificate(digest) {
    if (!canConfigure || digest === "") return
    actionStatus = "Trusting certificate…"
    _runWrite(["trusted-cert"], [digest], function() {
      root.certTrusted(digest)
      root.pendingTrustDigest = ""
      root.actionStatus = "Certificate trusted — press Connect to retry."
    })
  }

  function saveConnectionDetails(hostValue, portValue, usernameValue, realmValue) {
    if (!canConfigure) return
    var parsed = Model.parseGateways(hostValue, Model.sanitizeField(portValue))
    if (parsed.error) {
      lastError = parsed.error
      return
    }
    var h = parsed.hosts
    var p = parsed.port || "443"
    var u = Model.sanitizeField(usernameValue)
    var r = Model.sanitizeField(realmValue) || parsed.realm
    if (h === "" || u === "") {
      lastError = "Host and username are required."
      return
    }
    actionStatus = "Saving connection details…"
    var keys = ["host", "port", "username", "realm"]
    var values = [h, p, u, r]
    _runWrite(keys, values, function() {
      root.detailsSaved(h, p, u, r)
      root.actionStatus = "Connection details saved."
    })
  }

  function dismissTrust() {
    pendingTrustDigest = ""
  }

  function setPassword(password) {
    if (!canConfigure) return
    var pw = Model.sanitizeSecret(password)
    if (pw === "") {
      lastError = "Enter a password first."
      return
    }
    actionStatus = "Saving password…"
    _runWrite(["password"], [pw], function() {
      root.passwordSaved()
      root.actionStatus = "Password saved."
    })
  }

  function forgetPassword() {
    if (!canConfigure || !hasPassword) return
    actionStatus = "Removing saved password…"
    _runWrite(["password"], [""], function() {
      root.passwordForgotten()
      root.actionStatus = "Password removed."
    })
  }

  function _runWrite(keys, values, onSuccessFn) {
    writeProcess.onSuccess = onSuccessFn
    writeProcess._payload = values.join("\n") + "\n"
    writeProcess.command = Model.configWriteCommand(keys)
    writeProcess.running = true
  }

  function _handleStatus(raw) {
    var status = Model.parseStatus(raw)
    checkedInstalled = true
    if (!status) {
      installed = false
      controllerCode = "incompatible"
      controllerMessage = "FortiVPN controller needs installation or update."
      configState = "missing"
      state = "disconnected"
      return
    }
    installed = true
    controllerCode = status.code
    controllerMessage = status.message
    configState = status.configState
    var next = Model.normalizeActiveState(status.unitState)
    var enteredFailed = next === "failed" && state !== "failed"
    state = next
    if (enteredFailed) {
      fetchFailureDetail()
    } else if (next === "connected") {
      actionStatus = ""
      lastError = ""
      pendingTrustDigest = ""
    }
  }

  function _handleJournal(text) {
    var digest = Model.parseCertDigest(text)
    if (digest !== "" && digest !== trustedCertDigest) {
      pendingTrustDigest = digest
      lastError = ""
    } else {
      pendingTrustDigest = ""
      lastError = Model.parseFailureSummary(text) || "openfortivpn failed to connect."
    }
    actionStatus = ""
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  // Polls quickly right after a connect attempt so the icon/hero catch the
  // activating→active (or →failed) transition without waiting a full
  // refreshIntervalSec tick.
  Timer {
    id: startupRamp
    property int ticks: 0
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refreshStatus()
      if (root.state === "connected" || root.state === "failed" || ticks >= 25) running = false
    }
    onRunningChanged: if (running) ticks = 0
  }

  Timer {
    id: delayedRefresh
    interval: 500
    repeat: false
    onTriggered: root.refreshStatus()
  }

  Component.onCompleted: root.refreshStatus()

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    onExited: function(exitCode) {
      root._handleStatus(exitCode === 0 ? root._statusOutput : "")
      root.refreshing = false
    }
  }

  Process {
    id: journalProcess
    running: false
    command: []
    stdout: StdioCollector { id: journalStdout; waitForEnd: true; onStreamFinished: root._handleJournal(text) }
  }

  Process {
    id: resetFailedProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._pendingOtp = ""
        root.state = "failed"
        root.lastError = Model.sanitizeField(root._resetStderr || root._resetStdout)
          || "Failed to prepare the VPN unit."
        root.actionStatus = ""
        delayedRefresh.restart()
        return
      }
      root._startOutput = ""
      root._startError = ""
      startProcess.command = Model.startCommand(root._pendingOtp)
      root._pendingOtp = ""
      startProcess.running = true
    }
    stdout: StdioCollector { id: resetStdout; waitForEnd: true; onStreamFinished: root._resetStdout = text }
    stderr: StdioCollector { id: resetStderr; waitForEnd: true; onStreamFinished: root._resetStderr = text }
  }

  Process {
    id: startProcess
    running: false
    command: []
    stdout: StdioCollector { id: startStdout; waitForEnd: true; onStreamFinished: root._startOutput = text }
    stderr: StdioCollector { id: startStderr; waitForEnd: true; onStreamFinished: root._startError = text }
    onExited: function(exitCode) {
      command = []
      if (exitCode !== 0) {
        root.state = "failed"
        root.lastError = Model.sanitizeField(root._startError || root._startOutput) || "Failed to start the VPN unit."
        root.actionStatus = ""
        // state is already "failed", so the status poll won't see a
        // transition; pull the journal now to replace systemd's generic text.
        root.fetchFailureDetail()
      } else {
        startupRamp.restart()
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: stopProcess
    running: false
    command: []
    stdout: StdioCollector { id: stopStdout; waitForEnd: true; onStreamFinished: root._stopStdout = text }
    stderr: StdioCollector { id: stopStderr; waitForEnd: true; onStreamFinished: root._stopStderr = text }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.actionStatus = ""
        root.lastError = ""
      } else {
        root.actionStatus = ""
        root.lastError = Model.sanitizeField(root._stopStderr || root._stopStdout)
          || "Failed to disconnect the VPN."
      }
      delayedRefresh.restart()
    }
  }

  // Root-privileged config writes go through the installed fixed-purpose
  // helper. Values still travel over stdin instead of the command line.
  Process {
    id: writeProcess
    property var onSuccess: null
    property string _payload: ""
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: writeStdout; waitForEnd: true; onStreamFinished: root._writeStdout = text }
    stderr: StdioCollector { id: writeStderr; waitForEnd: true; onStreamFinished: root._writeStderr = text }
    onStarted: {
      write(_payload)
      _payload = ""
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        if (onSuccess) onSuccess()
        delayedRefresh.restart()
      } else {
        root.lastError = Model.sanitizeField(root._writeStderr || root._writeStdout) || "Failed to update the saved configuration."
        root.actionStatus = ""
      }
      _payload = ""
      onSuccess = null
    }
  }
}
