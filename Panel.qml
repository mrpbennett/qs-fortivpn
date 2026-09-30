import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "mrpbennett.fortivpn"
  ipcTarget: "mrpbennett.fortivpn"
  manageIpc: false

  property string hostText: ""
  property string portText: "443"
  property string usernameText: ""
  property string realmText: ""
  property string passwordText: ""
  property string otpText: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string statusText: {
    if (!service.checkedInstalled) return "Checking…"
    if (!service.installed) return "Controller update required"
    if (service.controllerCode === "dependency_missing") return "openfortivpn missing"
    if (service.controllerCode === "config_invalid") return "Configuration needs repair"
    if (service.pendingTrustDigest !== "") return "Unrecognized certificate"
    if (service.state === "connected") return "Connected"
    if (service.state === "connecting") return "Connecting…"
    if (service.state === "disconnecting") return "Disconnecting…"
    if (service.state === "failed") return "Connection failed"
    return service.configured ? "Disconnected" : "Not configured"
  }

  readonly property color iconColor: service.connected ? foreground : dim
  readonly property color barIconColor: service.connected ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool iconWarning: service.pendingTrustDigest !== "" || service.state === "failed"
  readonly property bool iconSpinning: service.state === "connecting" || service.state === "disconnecting"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      hostText = service.host
      portText = service.port
      usernameText = service.username
      realmText = service.realm
      passwordText = ""
      otpText = ""
      service.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      passwordText = ""
      otpText = ""
    }
  }

  // Mirrors the non-secret half of what Service just wrote to the
  // root-owned config file back into this widget's shell.json entry, so
  // the panel can pre-fill fields and show status without ever reading
  // the config file (which needs root) or the password (which isn't
  // persisted here at all).
  function persist(patch) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    for (var k in patch) entry[k] = patch[k]
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function connect() {
    if (!service.canConnect) return
    var otp = otpText
    otpText = ""
    service.connect(otp)
  }

  function savePassword() {
    if (service.busy || passwordText.length === 0) return
    var password = passwordText
    passwordText = ""
    service.setPassword(password)
  }

  Service {
    id: service
    settings: root.settings
  }

  Connections {
    target: service
    function onDetailsSaved(h, p, u, r) { root.persist({ host: h, port: p, username: u, realm: r }); root.hostText = h; root.portText = p; root.usernameText = u; root.realmText = r }
    function onPasswordSaved() { root.persist({ hasPassword: true }); root.passwordText = "" }
    function onPasswordForgotten() { root.persist({ hasPassword: false }) }
    function onCertTrusted(digest) { root.persist({ trustedCertDigest: digest }) }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(); return "ok" }
    function up(): string { root.otpText = ""; service.connect(""); return "ok" }
    function down(): string { service.disconnect(); return "ok" }
    function status(): string { return service.state }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        FortiIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          badgeColor: root.urgent
          connected: service.connected
          connecting: root.iconSpinning
          warning: root.iconWarning
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (service.canDisconnect) service.disconnect()
        else if (service.canConnect) root.connect()
      } else if (buttonCode === Qt.MiddleButton) {
        service.refresh()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: hostField.activeFocus || portField.activeFocus || usernameField.activeFocus ||
        realmField.activeFocus || passwordField.activeFocus || otpField.activeFocus || service.pendingTrustDigest !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

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

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "FortiVPN"
              meta: root.statusText
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: service.connected ? 1.0 : 0.6
              iconComponent: Component {
                FortiIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                  badgeColor: root.urgent
                  connected: service.connected
                  connecting: root.iconSpinning
                  warning: root.iconWarning
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  visible: service.canDisconnect || service.state === "disconnecting" || (service.installed && service.configured)
                  checked: service.connected || service.state === "connecting"
                  busy: service.busy || service.state === "disconnecting"
                  foreground: hero.foreground
                  onToggled: {
                    if (service.canDisconnect) service.disconnect()
                    else if (service.canConnect) root.connect()
                  }

                  PanelToolTip {
                    text: service.canDisconnect ? "Disconnect" : "Connect"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            visible: service.actionStatus !== "" || service.lastError !== ""
            width: parent.width
            text: service.actionStatus !== "" ? service.actionStatus : service.lastError
            color: service.lastError !== "" && service.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          CursorSurface {
            visible: service.checkedInstalled && !service.installed
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
            text: service.controllerCode === "dependency_missing"
              ? service.controllerMessage + " Install it with: sudo pacman -S openfortivpn"
              : service.controllerMessage + " Run ./scripts/install-passwordless-helper.sh after updating the plugin."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "CONNECTION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: hostField
              width: parent.width
              placeholderText: "Gateway host(s) (e.g. host1, host2)"
              text: root.hostText
              foreground: root.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextChanged: root.hostText = text
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: portField
                width: (parent.width - Style.space(8)) * 0.32
                placeholderText: "443"
                text: root.portText
                foreground: root.foreground
                horizontalPadding: Style.spacing.controlGap
                verticalPadding: Style.spacing.controlPaddingY
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onTextChanged: root.portText = text
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }

              TextField {
                id: usernameField
                width: parent.width - portField.width - Style.space(8)
                placeholderText: "Username"
                text: root.usernameText
                foreground: root.foreground
                horizontalPadding: Style.spacing.controlGap
                verticalPadding: Style.spacing.controlPaddingY
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onTextChanged: root.usernameText = text
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }
            }
            TextField {
              id: realmField
              width: parent.width
              placeholderText: "Realm (e.g. vendor, optional)"
              text: root.realmText
              foreground: root.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextChanged: root.realmText = text
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              PanelActionButton {
                iconText: "󰆓"
                tooltipText: "Save connection details"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: service.canConfigure && root.hostText.trim() !== "" && root.usernameText.trim() !== ""
                onClicked: service.saveConnectionDetails(root.hostText, root.portText, root.usernameText, root.realmText)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Save connection details"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            TextField {
              id: passwordField
              width: parent.width
              password: true
              placeholderText: service.hasPassword ? "•••••••• (saved — type to change)" : "Password"
              text: root.passwordText
              foreground: root.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextChanged: root.passwordText = text
              onAccepted: root.savePassword()
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              PanelActionButton {
                iconText: "󰆓"
                tooltipText: "Save password"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: service.canConfigure && root.passwordText.length > 0
                onClicked: root.savePassword()
              }

              PanelActionButton {
                visible: service.hasPassword
                iconText: "󰛌"
                tooltipText: "Forget saved password"
                hoverColor: root.urgent
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: service.canConfigure
                onClicked: service.forgetPassword()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: service.hasPassword ? "Password saved" : "No password saved"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "FORTITOKEN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: otpField
              width: parent.width
              enabled: service.canConnect
              placeholderText: "6-digit code (leave blank for push approval)"
              text: root.otpText
              foreground: root.foreground
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextChanged: root.otpText = text
              onAccepted: root.connect()
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }

            Text {
              width: parent.width
              text: "Entered fresh each connection — never saved. Leave blank if your FortiToken app uses push approval instead of a typed code."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }

    // Gateway certificates are pinned on trust-on-first-use — never
    // auto-accepted. This only opens right after openfortivpn itself
    // reported this exact digest as unrecognized.
    ConfirmDialog {
      anchors.fill: parent
      opened: service.pendingTrustDigest !== ""
      message: "Trust this gateway certificate?\n\nSHA-256 fingerprint:\n" + service.pendingTrustDigest +
        "\n\nOnly continue if this matches what your VPN administrator gave you — confirming pins it permanently."
      cancelText: "Cancel"
      confirmText: "Trust"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onConfirmed: service.trustCertificate(service.pendingTrustDigest)
      onCanceled: service.dismissTrust()
    }
  }
}
