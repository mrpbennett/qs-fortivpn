#!/usr/bin/env node
// Coverage for Model.parseGateways — empty, malformed, 1–5, and 6+ gateway inputs.
// Run: node tests/test_parseGateways.js
const fs = require("fs");
const assert = require("assert");
const path = require("path");

// ---- load Model.js without QML runtime ----
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8");

function sanitizeField(v) { return String(v == null ? "" : v).replace(/[\r\n]/g, "").trim(); }
function isValidHost(h) { if (!h || h.length > 255) return false; return /^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$/.test(h) && !/\.\./.test(h); }
function isValidPort(p) { if (!/^[0-9]{1,5}$/.test(p)) return false; const n = parseInt(p, 10); return n >= 1 && n <= 65535; }
var MAX_GATEWAYS = 5;

// Extract parseGateways definition and eval it (avoids needing QML engine).
const body = src.match(/function parseGateways[\s\S]*?\n\}/);
if (!body) { console.error("Could not find parseGateways in Model.js"); process.exit(1); }
eval(body[0]); // defines parseGateways in this scope

let passed = 0, failed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log(`  ok  ${name}`); }
  catch (e) { failed++; console.error(` fail ${name}\n      ${e.message}`); }
}
function eq(actual, expected, msg) { assert.deepStrictEqual(actual, expected, msg); }

console.log("parseGateways coverage");

// -- empty --
test("empty string → empty hosts, no error", () => {
  const r = parseGateways("", "443");
  eq(r.hosts, "");
  eq(r.error, "");
});
test("whitespace/separators only → empty hosts, no error", () => {
  const r = parseGateways("  , ;  ", "443");
  eq(r.hosts, "");
  eq(r.error, "");
});

// -- 1 gateway --
test("single host", () => {
  const r = parseGateways("vpn.example.com", "443");
  eq(r.hosts, "vpn.example.com");
  eq(r.error, "");
});
test("single host:port", () => {
  const r = parseGateways("vpn.example.com:8443", "443");
  eq(r.hosts, "vpn.example.com:8443");
  eq(r.error, "");
});
test("IP address", () => {
  const r = parseGateways("139.255.41.162", "4443");
  eq(r.hosts, "139.255.41.162");
  eq(r.error, "");
});

// -- 2–5 gateways --
test("two gateways", () => {
  const r = parseGateways("a.com, b.com", "443");
  eq(r.hosts, "a.com, b.com");
  eq(r.error, "");
});
test("two gateways with distinct ports preserved", () => {
  const r = parseGateways("a.com:443, b.com:8443", "443");
  eq(r.hosts, "a.com:443, b.com:8443");
  eq(r.error, "");
});
test("five gateways (max) → ok", () => {
  const r = parseGateways("a.com, b.com, c.com, d.com, e.com", "443");
  eq(r.hosts, "a.com, b.com, c.com, d.com, e.com");
  eq(r.error, "");
});
test("five gateways via mixed separators", () => {
  const r = parseGateways("a.com;b.com c.com,d.com;e.com", "443");
  eq(r.hosts, "a.com, b.com, c.com, d.com, e.com");
  eq(r.error, "");
});

// -- 6+ gateways --
test("six gateways → Too many", () => {
  const r = parseGateways("a.com, b.com, c.com, d.com, e.com, f.com", "443");
  assert.match(r.error, /Too many gateways/);
});
test("seven gateways → Too many", () => {
  const r = parseGateways("1.1.1.1, 2.2.2.2, 3.3.3.3, 4.4.4.4, 5.5.5.5, 6.6.6.6, 7.7.7.7", "443");
  assert.match(r.error, /Too many gateways/);
});

// -- malformed --
test("ftp:// → Unsupported protocol", () => {
  const r = parseGateways("ftp://vpn.example.com", "443");
  assert.match(r.error, /Unsupported protocol/);
});
test("ftps:// → Unsupported protocol", () => {
  const r = parseGateways("ftps://vpn.example.com", "443");
  assert.match(r.error, /Unsupported protocol/);
});
test("host:443:garbage → Malformed", () => {
  const r = parseGateways("vpn.example.com:443:garbage", "443");
  assert.match(r.error, /Malformed gateway entry/);
});
test("host/realm/extra → Malformed", () => {
  const r = parseGateways("vpn.example.com/realm/extra", "443");
  assert.match(r.error, /Malformed gateway entry/);
});
test("https://host/realm/extra → Malformed", () => {
  const r = parseGateways("https://vpn.example.com/realm/extra", "443");
  assert.match(r.error, /Malformed gateway entry/);
});
test("invalid host -bad → Invalid", () => {
  const r = parseGateways("good.com, -bad", "443");
  assert.match(r.error, /Invalid gateway host/);
});
test("double-dot vpn..example.com → Invalid", () => {
  const r = parseGateways("vpn..example.com", "443");
  assert.match(r.error, /Invalid gateway host/);
});
test("invalid port 99999 → Invalid port", () => {
  const r = parseGateways("vpn.example.com:99999", "443");
  assert.match(r.error, /Invalid port/);
});
test("shell syntax $(id) → Invalid", () => {
  const r = parseGateways("vpn.example.com, x$(id)", "443");
  assert.match(r.error, /Invalid gateway host/);
});

// -- supported forms still accepted --
test("https://vpn.example.com:443/vendor → host:port + realm", () => {
  const r = parseGateways("https://vpn.example.com:443/vendor", "443");
  eq(r.hosts, "vpn.example.com:443");
  eq(r.realm, "vendor");
  eq(r.error, "");
});
test("http://vpn.example.com → stripped", () => {
  const r = parseGateways("http://vpn.example.com", "443");
  eq(r.hosts, "vpn.example.com");
  eq(r.error, "");
});
test("vpn.example.com/vendor → host + realm", () => {
  const r = parseGateways("vpn.example.com/vendor", "443");
  eq(r.hosts, "vpn.example.com");
  eq(r.realm, "vendor");
  eq(r.error, "");
});
test("duplicate hosts deduped", () => {
  const r = parseGateways("a.com, a.com, b.com", "443");
  eq(r.hosts, "a.com, b.com");
  eq(r.error, "");
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
