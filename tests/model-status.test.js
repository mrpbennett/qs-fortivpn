const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\n/, "");
const moduleForTest = { exports: {} };
new Function("module", source)(moduleForTest);
const model = moduleForTest.exports;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const ready = [
  "interfaceVersion=1",
  "controllerVersion=1.2.0",
  "code=ready",
  "message=FortiVPN is ready.",
  "dependencyPath=/usr/bin/openfortivpn",
  "configState=ready",
  "trustedCertificate=false",
  "unitState=active"
].join("\n");

assert(model.statusCommand().join(" ") === "sudo -n /usr/local/libexec/omarchy-fortivpn-helper status", "status must use the privileged controller");
assert(model.parseStatus(ready).code === "ready", "valid controller status must parse");
assert(model.parseStatus(ready.replace("interfaceVersion=1", "interfaceVersion=2")) === null, "incompatible interface must be rejected");
assert(model.parseStatus(ready.replace("configState=ready", "configState=unknown")) === null, "unknown config state must be rejected");

const authFailureJournal = [
  "Starting Omarchy FortiVPN...",
  "INFO:   Connected to gateway.",
  "ERROR:  Could not authenticate to gateway. Please check the password, client certificate, etc.",
  "INFO:   Closed connection to gateway.",
  "INFO:   Logged out.",
  "omarchy-fortivpn.service: Main process exited, code=exited, status=1/FAILURE",
  "omarchy-fortivpn.service: Failed with result 'exit-code'.",
  "Failed to start Omarchy FortiVPN."
].join("\n");
assert(model.parseFailureSummary(authFailureJournal) === "Could not authenticate to gateway. Please check the password, client certificate, etc.",
  "failure summary must prefer openfortivpn's ERROR line over systemd's unit lifecycle lines");

const helperPath = "/home/u/plugins/forti vpn/scripts/install-passwordless-helper.sh";
assert(model.localPath("file:///home/u/plugins/forti%20vpn/scripts/install-passwordless-helper.sh") === helperPath,
  "plugin URLs must become plain, decoded paths");
assert(JSON.stringify(model.installCommand(helperPath)) ===
  JSON.stringify(["pkexec", "/usr/bin/bash", helperPath, "--install-root"]),
  "setup must run the installer through pkexec without a caller-supplied user");

const shipped = model.CONTROLLER_VERSION.split(".").map(Number);
const older = [shipped[0], shipped[1], shipped[2] - 1].join(".");
const newer = [shipped[0], shipped[1] + 10, 0].join(".");
assert(shipped[2] === 0 || model.controllerUpdateAvailable(older), "an older controller must offer an update");
assert(model.controllerUpdateAvailable("0.9.9"), "an older major/minor controller must offer an update");
assert(!model.controllerUpdateAvailable(model.CONTROLLER_VERSION), "the shipped controller must not offer an update");
assert(!model.controllerUpdateAvailable(newer), "a newer controller must not offer a downgrade");
assert(!model.controllerUpdateAvailable("garbage"), "an unparsable version must not offer an update");

const helperSource = fs.readFileSync(path.join(__dirname, "..", "scripts", "omarchy-fortivpn-helper"), "utf8");
assert(helperSource.includes(`CONTROLLER_VERSION=${model.CONTROLLER_VERSION}\n`),
  "Model.CONTROLLER_VERSION must match the controller shipped in scripts/");
