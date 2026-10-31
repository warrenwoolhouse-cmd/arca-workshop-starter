// The local site. Started (and restarted) by server/supervisor.js.
// Don't change this file: add your own endpoints in server/team-routes.js.

const http = require("http");
const config = require("./config");
const guard = require("./guard");
const core = require("./core");
const { writeTableFiles } = require("./table");

let teamRoutes = null;
try {
  teamRoutes = require("./team-routes");
} catch (err) {
  console.log(`server/team-routes.js has a mistake, so its endpoints are off until it's fixed: ${err.message}`);
}

async function handle(req, res) {
  // No caching anywhere, so a saved change is live within seconds.
  const writeHead = res.writeHead;
  res.writeHead = function (...args) {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("X-Content-Type-Options", "nosniff");
    return writeHead.apply(this, args);
  };

  if (!guard.allow(req, res)) return;

  const pathname = new URL(req.url, "http://site").pathname;
  try {
    if (await core.handleSave(req, res, pathname)) return;
    if (typeof teamRoutes === "function" && (await teamRoutes(req, res, { pathname, ...core, config }))) return;
    if (core.serveStatic(req, res, pathname)) return;
    core.notFound(res);
  } catch (err) {
    console.log(`Error on ${req.method} ${pathname}: ${err.stack || err}`);
    if (!res.headersSent) {
      res.writeHead(500, { "Content-Type": "text/html; charset=utf-8" });
      res.end(core.page("Something went wrong", "This page hit a problem. Ask Claude Code to look at the site's log in logs/server.log."));
    } else {
      res.end();
    }
  }
}

function listen(host) {
  return new Promise((resolve) => {
    const server = http.createServer(handle);
    let tries = 0;
    server.on("error", (err) => {
      // After a restart the old process may hold the port for a moment.
      if (err.code === "EADDRINUSE" && tries++ < 20) { setTimeout(() => server.listen(config.PORT, host), 500); return; }
      resolve({ host, ok: false, err });
    });
    server.listen(config.PORT, host, () => resolve({ host, ok: true }));
  });
}

async function main() {
  writeTableFiles();
  // Only the laptop itself can reach the site directly; the tunnel connects
  // from the laptop too. Both loopback addresses, because Windows may resolve
  // "localhost" to either.
  const results = await Promise.all([listen("127.0.0.1"), listen("::1")]);
  const up = results.filter((r) => r.ok).map((r) => r.host);
  if (!results[0].ok) {
    console.log(`The site couldn't start on port ${config.PORT}: ${results[0].err.message}`);
    process.exit(1);
  }
  console.log(`Site running on port ${config.PORT} (${up.join(", ")}) for ${config.TEAM ? `Table ${config.TEAM}` : "no table yet"}.`);
  guard.startPush();
}

// If the supervisor stops (even if it's killed), stop too. Otherwise, on
// Windows, an orphaned copy would keep port 8080 and serve old code.
if (process.send) process.on("disconnect", () => process.exit(0));

main();
