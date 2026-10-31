// Keeps the local site running: starts server/main.js, restarts it within a
// second or two if it stops, and restarts it when any file in server/ changes.
// Don't change this file. Start it with `npm start`.

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const config = require("./config");

const MAIN = path.join(__dirname, "main.js");
const LOG_FILE = path.join(config.LOGS_DIR, "server.log");
const MAX_LOG_BYTES = 1024 * 1024;

fs.mkdirSync(config.LOGS_DIR, { recursive: true });
try { if (fs.statSync(LOG_FILE).size > MAX_LOG_BYTES) fs.renameSync(LOG_FILE, `${LOG_FILE}.old`); } catch { /* no log yet */ }
const log = fs.createWriteStream(LOG_FILE, { flags: "a" });

function note(line) {
  const text = `${new Date().toISOString()} ${line}\n`;
  process.stdout.write(text);
  log.write(text);
}

let child = null;
let restartForChange = false;
let quickExits = 0;

function start() {
  const startedAt = Date.now();
  child = spawn(process.execPath, [MAIN], { cwd: config.ROOT, stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
  for (const stream of [child.stdout, child.stderr]) {
    stream.on("data", (chunk) => { process.stdout.write(chunk); log.write(chunk); });
  }
  child.on("exit", (code, signal) => {
    child = null;
    if (restartForChange) {
      restartForChange = false;
      note("Restarting the site because its code changed.");
      start();
      return;
    }
    // A crash: restart quickly, backing off if it keeps crashing straight away.
    quickExits = Date.now() - startedAt < 5000 ? quickExits + 1 : 0;
    const wait = Math.min(1000 * 2 ** Math.max(0, quickExits - 1), 10000);
    note(`The site stopped (${signal || `exit ${code}`}). Starting it again in ${wait / 1000} s.`);
    setTimeout(start, wait);
  });
}

let changeTimer = null;
fs.watch(__dirname, (event, filename) => {
  if (filename && !filename.endsWith(".js")) return;
  clearTimeout(changeTimer);
  changeTimer = setTimeout(() => {
    if (child) { restartForChange = true; child.kill(); } else { quickExits = 0; }
  }, 300);
});

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    if (child) { child.removeAllListeners("exit"); child.kill(); }
    process.exit(0);
  });
}

start();
