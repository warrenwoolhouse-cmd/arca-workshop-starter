// Serving files and saving data. Don't change this file: add your own
// endpoints in server/team-routes.js instead.

const fs = require("fs");
const path = require("path");
const config = require("./config");

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".csv": "text/csv; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
};

const MAX_SAVE_BYTES = 2 * 1024 * 1024;
const SAVE_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;

function page(title, text) {
  return `<!doctype html><html lang="en-AU"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>${title}</title>
<style>html{font-family:"Lexend","Helvetica Neue",Arial,system-ui,sans-serif;color:#1f2124}body{margin:48px 24px;max-width:36rem;font-size:17px;line-height:26px}h1{font-size:26px;line-height:32px;font-weight:600}</style>
</head><body><h1>${title}</h1><p>${text}</p></body></html>`;
}

function sendJson(res, status, value) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(value));
}

function notFound(res) {
  res.writeHead(404, { "Content-Type": "text/html; charset=utf-8" });
  res.end(page("Page not found", "There's nothing at this address yet. Check the link, or ask Claude Code to build it."));
}

// Resolves a request path inside base, or null if it would step outside it
// or touch a hidden file.
function safeJoin(base, urlPath) {
  let decoded;
  try { decoded = decodeURIComponent(urlPath); } catch { return null; }
  if (decoded.includes("\0")) return null;
  const parts = decoded.split(/[\\/]+/).filter(Boolean);
  if (parts.some((p) => p === ".." || p.startsWith("."))) return null;
  const full = path.join(base, ...parts);
  return full === base || full.startsWith(base + path.sep) ? full : null;
}

function serveFile(res, file, method) {
  let stat;
  try { stat = fs.statSync(file); } catch { return false; }
  if (stat.isDirectory()) return serveFile(res, path.join(file, "index.html"), method);
  if (!stat.isFile()) return false;
  const type = TYPES[path.extname(file).toLowerCase()] || "application/octet-stream";
  let body;
  try { body = fs.readFileSync(file); } catch { return false; }
  res.writeHead(200, { "Content-Type": type, "Content-Length": body.length });
  res.end(method === "HEAD" ? undefined : body);
  return true;
}

// Files are read from disk on every request: there's no build or publish step.
function serveStatic(req, res, pathname) {
  if (req.method !== "GET" && req.method !== "HEAD") return false;
  if (pathname === "/workshop.json") return serveFile(res, config.WORKSHOP_FILE, req.method);
  if (pathname === "/") {
    if (serveFile(res, path.join(config.SITE_DIR, "index.html"), req.method)) return true;
    res.writeHead(302, { Location: "/dashboard.html" });
    res.end();
    return true;
  }
  if (pathname.startsWith("/data/")) {
    const file = safeJoin(config.DATA_DIR, pathname.slice("/data/".length));
    return file ? serveFile(res, file, req.method) : false;
  }
  const file = safeJoin(config.SITE_DIR, pathname);
  return file ? serveFile(res, file, req.method) : false;
}

// Saves only come from this site's own pages (or from scripts on the
// laptop, which send no Origin). Every team site shares warrenwoolhouse.com,
// so without this a page on another table's site could save into this one.
function sameOrigin(req) {
  const site = req.headers["sec-fetch-site"];
  if (site && site !== "same-origin" && site !== "none") return false;
  const origin = req.headers.origin;
  if (!origin) return true;
  try { return new URL(origin).host === req.headers.host; } catch { return false; }
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      // Read past the limit (so the browser gets a proper answer), but stop
      // keeping it, and hang up on anything absurd.
      if (size > limit * 4) { req.destroy(); return; }
      if (size <= limit) chunks.push(c);
    });
    req.on("end", () => (size > limit ? reject(new Error("too big")) : resolve(Buffer.concat(chunks).toString("utf8"))));
    req.on("error", reject);
  });
}

// Writes the whole file to one side, then swaps it in, so a reader never
// sees half a file.
function writeFileAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(tmp, text);
  for (let attempt = 0; ; attempt++) {
    try { fs.renameSync(tmp, file); return; } catch (err) {
      // Windows can briefly lock a file that's being read.
      if (attempt >= 10 || !["EPERM", "EACCES", "EBUSY"].includes(err.code)) {
        try { fs.unlinkSync(tmp); } catch { /* ignore */ }
        throw err;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
}

// /api/save          GET: the names saved so far
// /api/save/<name>   GET: the saved JSON. POST or PUT: save JSON (up to 2 MB)
async function handleSave(req, res, pathname) {
  if (pathname === "/api/save" || pathname === "/api/save/") {
    if (req.method !== "GET") { sendJson(res, 405, { error: "Use GET to list saved data." }); return true; }
    let names = [];
    try { names = fs.readdirSync(config.SAVED_DIR).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5)); } catch { /* none yet */ }
    sendJson(res, 200, names.sort());
    return true;
  }
  if (!pathname.startsWith("/api/save/")) return false;

  const name = pathname.slice("/api/save/".length);
  if (!SAVE_NAME.test(name)) {
    sendJson(res, 400, { error: "Save names use letters, numbers, dashes and underscores only, up to 64 characters." });
    return true;
  }
  const file = path.join(config.SAVED_DIR, `${name}.json`);

  if (req.method === "GET" || req.method === "HEAD") {
    if (!serveFile(res, file, req.method)) sendJson(res, 404, { error: `Nothing has been saved as "${name}" yet.` });
    return true;
  }
  if (req.method !== "POST" && req.method !== "PUT") {
    sendJson(res, 405, { error: "Use POST or PUT to save, GET to read." });
    return true;
  }
  if (!sameOrigin(req)) {
    sendJson(res, 403, { error: "Saves only work from this site's own pages." });
    return true;
  }
  let text;
  try { text = await readBody(req, MAX_SAVE_BYTES); } catch {
    sendJson(res, 413, { error: "That's too much to save at once (the limit is 2 MB)." });
    return true;
  }
  let value;
  try { value = JSON.parse(text); } catch {
    sendJson(res, 400, { error: "Saves must be JSON." });
    return true;
  }
  writeFileAtomic(file, JSON.stringify(value, null, 2));
  sendJson(res, 200, { saved: name, at: new Date().toISOString() });
  return true;
}

module.exports = { serveStatic, handleSave, notFound, page, sendJson, readBody, writeFileAtomic, safeJoin, sameOrigin };
