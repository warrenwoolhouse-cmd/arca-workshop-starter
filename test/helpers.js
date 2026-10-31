// Test helpers: run the site from a throwaway copy of this folder, and a
// stand-in for the central site's push endpoint.

const { spawn } = require("child_process");
const fs = require("fs");
const http = require("http");
const net = require("net");
const os = require("os");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const TOKEN = "test-token-0123456789abcdef";

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer().listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, { timeout = 10000, every = 100 } = {}) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    try { last = await fn(); if (last) return last; } catch (err) { last = err; }
    await sleep(every);
  }
  throw new Error(`Timed out waiting (last: ${last})`);
}

function copyStarter() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "starter-test-"));
  for (const item of ["server", "site", "data", "tools", "package.json"]) {
    fs.cpSync(path.join(ROOT, item), path.join(dir, item), { recursive: true });
  }
  return dir;
}

// A stand-in for POST /api/team/workshop on the central site.
async function startCentral() {
  const port = await freePort();
  const central = { port, received: [], status: 200, url: `http://127.0.0.1:${port}` };
  central.server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      if (req.url === "/api/team/workshop" && req.method === "POST") {
        central.received.push({ at: Date.now(), auth: req.headers.authorization, body });
        if (central.status !== 200) { res.writeHead(central.status); res.end('{"error":"stand-in says no"}'); return; }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ received: new Date().toISOString() }));
      } else { res.writeHead(404); res.end(); }
    });
  });
  await new Promise((r) => central.server.listen(port, "127.0.0.1", r));
  central.stop = () => new Promise((r) => central.server.close(r));
  return central;
}

async function startSite({ central, env = {} } = {}) {
  const dir = copyStarter();
  const port = await freePort();
  const child = spawn(process.execPath, ["server/supervisor.js"], {
    cwd: dir,
    env: {
      ...process.env,
      WORKSHOP_PORT: String(port),
      WORKSHOP_TEAM: "7",
      WORKSHOP_TEAM_NAME: "Test Table",
      WORKSHOP_TEAM_TOKEN: TOKEN,
      WORKSHOP_SITE_URL: "https://team7.warrenwoolhouse.com",
      WORKSHOP_CENTRAL_URL: central ? central.url : "",
      WORKSHOP_PUSH_SETTLE_MS: "300",
      WORKSHOP_PUSH_EVERY_MS: "60000",
      WORKSHOP_PUSH_RETRY_MS: "300",
      ...env,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (c) => (output += c));
  child.stderr.on("data", (c) => (output += c));
  const site = { dir, port, child, base: `http://127.0.0.1:${port}`, output: () => output };
  site.stop = async () => {
    child.kill();
    await new Promise((r) => (child.exitCode !== null ? r() : child.on("exit", r)));
    fs.rmSync(dir, { recursive: true, force: true });
  };
  await waitFor(() => fetch(`${site.base}/workshop.json`).then((r) => r.ok));
  return site;
}

module.exports = { TOKEN, startSite, startCentral, waitFor, sleep };
