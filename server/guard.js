// The guard: who may use this site, and sending workshop.json to the board.
// DON'T CHANGE THIS FILE. It keeps other tables out of your site and keeps
// your score live on the board. (CONTRACTS.md sections 4 and 11.)

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const config = require("./config");

// ---------------------------------------------------------------- access

// Cloudflare adds these to every request that comes through the tunnel.
// A request on the laptop itself has none of them. The site only listens on
// the laptop's own loopback address, so nothing else can reach it directly.
const CLOUDFLARE_HEADERS = ["cf-connecting-ip", "cf-ray", "cdn-loop", "cf-visitor"];

function isLocal(req) {
  return !CLOUDFLARE_HEADERS.some((h) => h in req.headers);
}

function keyMatches(candidate) {
  if (!config.TOKEN || typeof candidate !== "string" || candidate === "") return false;
  const a = crypto.createHash("sha256").update(candidate).digest();
  const b = crypto.createHash("sha256").update(config.TOKEN).digest();
  return crypto.timingSafeEqual(a, b);
}

function cookieValue(req, name) {
  for (const part of (req.headers.cookie || "").split(";")) {
    const i = part.indexOf("=");
    if (i > 0 && part.slice(0, i).trim() === name) {
      try { return decodeURIComponent(part.slice(i + 1).trim()); } catch { return ""; }
    }
  }
  return "";
}

function refusedPage() {
  const table = config.TEAM ? `Table ${config.TEAM}` : "a table";
  return `<!doctype html>
<html lang="en-AU"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${table}'s site</title>
<style>
  html { color-scheme: light; font-family: "Lexend", "Helvetica Neue", Arial, system-ui, sans-serif; color: #1f2124; background: #fff; }
  body { margin: 0; }
  header { background: #3e4245; color: #f1f1f0; padding: 48px 24px; }
  p.eyebrow { margin: 0 0 12px; font-size: 12px; font-weight: 700; letter-spacing: 0.08em; color: #5fd6ca; }
  h1 { margin: 0; font-size: 32px; line-height: 38px; font-weight: 600; letter-spacing: -0.025em; max-width: 36rem; }
  main { padding: 24px; font-size: 17px; line-height: 26px; max-width: 36rem; }
</style></head>
<body>
<header><p class="eyebrow">WW LOANS WORKSHOP</p><h1>This is ${table}'s site.</h1></header>
<main><p>Open it from your team page. The link there lets your phone in.</p></main>
</body></html>`;
}

function refuse(res) {
  res.writeHead(403, { "Content-Type": "text/html; charset=utf-8" });
  res.end(refusedPage());
}

// Returns true if the request may go ahead. Otherwise it has already answered.
function allow(req, res) {
  if (isLocal(req)) return true;

  const url = new URL(req.url, "http://site");
  if (url.searchParams.has("key")) {
    if (!keyMatches(url.searchParams.get("key"))) { refuse(res); return false; }
    url.searchParams.delete("key");
    res.writeHead(302, {
      "Set-Cookie": `ww_key=${encodeURIComponent(config.TOKEN)}; Path=/; Max-Age=1209600; HttpOnly; Secure; SameSite=Lax`,
      Location: url.pathname + url.search,
    });
    res.end();
    return false;
  }

  if (keyMatches(req.headers["x-workshop-key"]) || keyMatches(cookieValue(req, "ww_key"))) return true;

  refuse(res);
  return false;
}

// ---------------------------------------------------------------- push

const PUSH_STATUS_FILE = path.join(config.LOGS_DIR, "push.json");
const push = { lastChange: null, timer: null, sending: false, again: false, lastSentHash: null, status: {} };

function recordPush(fields) {
  Object.assign(push.status, fields);
  try {
    fs.mkdirSync(config.LOGS_DIR, { recursive: true });
    fs.writeFileSync(PUSH_STATUS_FILE, JSON.stringify(push.status, null, 2));
  } catch { /* status is only for the self-check */ }
}

function schedule(ms) {
  clearTimeout(push.timer);
  push.timer = setTimeout(sendNow, ms);
}

async function sendNow() {
  if (push.sending) { push.again = true; return; }
  push.sending = true;
  let retry = false;
  try {
    let text;
    try { text = fs.readFileSync(config.WORKSHOP_FILE, "utf8"); } catch {
      recordPush({ last_skip: new Date().toISOString(), skip_reason: "workshop.json is missing" });
      return;
    }
    try { JSON.parse(text); } catch {
      // Half-written or broken: skip it. The next good version is sent.
      recordPush({ last_skip: new Date().toISOString(), skip_reason: "workshop.json isn't valid JSON" });
      return;
    }
    const hash = crypto.createHash("sha256").update(text).digest("hex");
    recordPush({ last_attempt: new Date().toISOString() });
    const response = await fetch(`${config.CENTRAL_URL}/api/team/workshop`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${config.TOKEN}` },
      body: text,
      signal: AbortSignal.timeout(10000),
    });
    const reply = (await response.text()).slice(0, 500);
    if (response.ok) {
      push.lastSentHash = hash;
      recordPush({ last_ok: new Date().toISOString(), last_ok_hash: hash, last_error: null });
    } else {
      recordPush({ last_error: `The board said ${response.status}: ${reply}`, last_error_at: new Date().toISOString() });
      // A file the board rejects is retried at the next change or the next
      // regular send; anything else (busy, down) is retried soon.
      retry = response.status !== 400;
    }
  } catch (err) {
    recordPush({ last_error: `Couldn't reach the board (${err.name})`, last_error_at: new Date().toISOString() });
    retry = true;
  } finally {
    push.sending = false;
    if (push.again) { push.again = false; schedule(0); } else if (retry) schedule(config.PUSH_RETRY_MS);
  }
}

function startPush() {
  if (!config.CENTRAL_URL || !config.TOKEN) {
    recordPush({ disabled: "WORKSHOP_CENTRAL_URL or WORKSHOP_TEAM_TOKEN isn't set" });
    console.log("Not sending workshop.json to the board: this laptop isn't set up for a table yet.");
    return;
  }
  push.status = { disabled: null };
  let seen = null;
  const look = () => {
    let now = null;
    try { const s = fs.statSync(config.WORKSHOP_FILE); now = `${s.mtimeMs}:${s.size}`; } catch { /* missing */ }
    if (now !== seen) { seen = now; if (now) schedule(config.PUSH_SETTLE_MS); }
  };
  look();
  setInterval(look, 1000).unref();
  setInterval(() => schedule(0), config.PUSH_EVERY_MS).unref();
}

module.exports = { allow, isLocal, startPush };
