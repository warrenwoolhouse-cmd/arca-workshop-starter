const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const { after, before, describe, test } = require("node:test");
const { TOKEN, startSite, startCentral, waitFor, sleep } = require("./helpers");

const VIA_TUNNEL = { "Cf-Connecting-IP": "203.0.113.9", "Cf-Ray": "abc123-SYD", "Cdn-Loop": "cloudflare" };

describe("serving and access", () => {
  let site;
  before(async () => { site = await startSite(); });
  after(async () => { await site.stop(); });

  test("creates a starting workshop.json and TABLE.md for this table", async () => {
    const w = JSON.parse(fs.readFileSync(path.join(site.dir, "workshop.json"), "utf8"));
    assert.equal(w.team, 7);
    assert.equal(w.name, "Test Table");
    assert.deepEqual(w.emails, []);
    const features = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "data", "features.json"), "utf8"));
    assert.deepEqual(w.features.map((f) => f.feature), features.map((f) => f.slug));
    assert.ok(w.features.every((f) => f.done === false));
    assert.match(w.updated, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+1[01]:00$/);
    const table = fs.readFileSync(path.join(site.dir, "TABLE.md"), "utf8");
    assert.match(table, /This laptop is Table 7: Test Table/);
    assert.match(table, /https:\/\/team7\.warrenwoolhouse\.com\/dashboard\.html/);
    assert.ok(!table.includes(TOKEN), "TABLE.md must not contain the key");
  });

  test("local requests need nothing, and nothing is cached", async () => {
    const w = await fetch(`${site.base}/workshop.json`);
    assert.equal(w.status, 200);
    assert.match(w.headers.get("content-type"), /^application\/json/);
    assert.equal(w.headers.get("cache-control"), "no-store");
    assert.equal(w.headers.get("access-control-allow-origin"), null);
    const d = await fetch(`${site.base}/dashboard.html`);
    assert.equal(d.status, 200);
    assert.equal(d.headers.get("cache-control"), "no-store");
    assert.match(await d.text(), /hasn't built its dashboard yet/);
    const css = await fetch(`${site.base}/tokens.css`);
    assert.equal(css.headers.get("cache-control"), "no-store");
    assert.match(css.headers.get("content-type"), /^text\/css/);
  });

  test("through the tunnel without the key: the 403 page and no data", async () => {
    for (const p of ["/workshop.json", "/dashboard.html", "/data/practice.json", "/api/save", "/"]) {
      const r = await fetch(`${site.base}${p}`, { headers: VIA_TUNNEL, redirect: "manual" });
      assert.equal(r.status, 403, p);
      const body = await r.text();
      assert.match(body, /This is Table 7's site\./);
      assert.match(body, /Open it from your team page/);
      assert.ok(!body.includes("Test Table"), "no data on the 403 page");
      assert.equal(r.headers.get("cache-control"), "no-store");
    }
  });

  test("any one Cloudflare header counts as the tunnel", async () => {
    for (const h of ["Cf-Connecting-IP", "Cf-Ray", "Cdn-Loop", "Cf-Visitor"]) {
      const r = await fetch(`${site.base}/workshop.json`, { headers: { [h]: "x" } });
      assert.equal(r.status, 403, h);
    }
  });

  test("the header or the cookie gets in; a wrong key doesn't", async () => {
    const ok = await fetch(`${site.base}/workshop.json`, { headers: { ...VIA_TUNNEL, "X-Workshop-Key": TOKEN } });
    assert.equal(ok.status, 200);
    assert.equal((await ok.json()).team, 7);
    const cookie = await fetch(`${site.base}/dashboard.html`, { headers: { ...VIA_TUNNEL, Cookie: `other=1; ww_key=${TOKEN}` } });
    assert.equal(cookie.status, 200);
    const wrong = await fetch(`${site.base}/workshop.json`, { headers: { ...VIA_TUNNEL, "X-Workshop-Key": TOKEN + "x" } });
    assert.equal(wrong.status, 403);
    const wrongCookie = await fetch(`${site.base}/workshop.json`, { headers: { ...VIA_TUNNEL, Cookie: "ww_key=nope" } });
    assert.equal(wrongCookie.status, 403);
  });

  test("?key= sets the cookie and redirects to the same address without the key", async () => {
    const r = await fetch(`${site.base}/dashboard.html?view=big&key=${TOKEN}`, { headers: VIA_TUNNEL, redirect: "manual" });
    assert.equal(r.status, 302);
    assert.equal(r.headers.get("location"), "/dashboard.html?view=big");
    const setCookie = r.headers.get("set-cookie");
    assert.match(setCookie, new RegExp(`^ww_key=${TOKEN};`));
    for (const attr of ["HttpOnly", "Secure", "SameSite=Lax", "Path=/"]) assert.ok(setCookie.includes(attr), attr);
    const bad = await fetch(`${site.base}/dashboard.html?key=wrong`, { headers: VIA_TUNNEL, redirect: "manual" });
    assert.equal(bad.status, 403);
    assert.equal(bad.headers.get("set-cookie"), null);
  });

  test("can't reach files outside site/ and data/", async () => {
    for (const p of ["/../package.json", "/%2e%2e/package.json", "/..%2fserver/guard.js", "/.git/config", "/data/../server/guard.js", "/TABLE.md", "/logs/push.json"]) {
      const r = await fetch(`${site.base}${p}`);
      assert.equal(r.status, 404, p);
    }
    const data = await fetch(`${site.base}/data/practice.json`);
    assert.equal(data.status, 200);
    assert.equal((await data.json()).length, 250);
  });

  test("saves: JSON from the site's own pages, read back, stored in saved/", async () => {
    const r = await fetch(`${site.base}/api/save/overrides`, {
      method: "POST", body: JSON.stringify({ P0001: { category: "general" } }),
      headers: { "Content-Type": "application/json", Origin: site.base, "Sec-Fetch-Site": "same-origin" },
    });
    assert.equal(r.status, 200);
    assert.deepEqual(await (await fetch(`${site.base}/api/save/overrides`)).json(), { P0001: { category: "general" } });
    assert.deepEqual(await (await fetch(`${site.base}/api/save`)).json(), ["overrides"]);
    assert.ok(fs.existsSync(path.join(site.dir, "saved", "overrides.json")));
    const scriptSave = await fetch(`${site.base}/api/save/notes`, { method: "PUT", body: "[1,2,3]" });
    assert.equal(scriptSave.status, 200);
  });

  test("saves refuse other sites, bad names, non-JSON, oversize, and the tunnel without the key", async () => {
    const post = (name, body, headers = {}) => fetch(`${site.base}/api/save/${name}`, { method: "POST", body, headers });
    assert.equal((await post("x", "{}", { Origin: "https://team5.warrenwoolhouse.com" })).status, 403);
    assert.equal((await post("x", "{}", { "Sec-Fetch-Site": "same-site" })).status, 403);
    assert.equal((await post("..%2Fworkshop", "{}")).status, 400);
    assert.equal((await post("a.b", "{}")).status, 400);
    assert.equal((await post("x", "not json")).status, 400);
    assert.equal((await post("x", JSON.stringify("a".repeat(2.1 * 1024 * 1024)))).status, 413);
    assert.equal((await post("x", "{}", VIA_TUNNEL)).status, 403);
    assert.equal((await fetch(`${site.base}/api/save/missing`)).status, 404);
  });

  test("a save from a phone through the tunnel works with the cookie", async () => {
    // fetch can't set Host, so use http.request to look like the tunnel.
    const status = await new Promise((resolve, reject) => {
      const req = require("http").request(`${site.base}/api/save/phone`, {
        method: "POST",
        headers: {
          ...VIA_TUNNEL, Host: "team7.warrenwoolhouse.com", Origin: "https://team7.warrenwoolhouse.com",
          "Sec-Fetch-Site": "same-origin", Cookie: `ww_key=${TOKEN}`, "Content-Type": "application/json",
        },
      }, (res) => { res.resume(); resolve(res.statusCode); });
      req.on("error", reject);
      req.end('{"P0002":{"priority":true}}');
    });
    assert.equal(status, 200);
  });
});

describe("restarting itself", () => {
  let site;
  before(async () => { site = await startSite(); });
  after(async () => { await site.stop(); });

  test("picks up a change to its code within seconds", async () => {
    const routes = path.join(site.dir, "server", "team-routes.js");
    fs.writeFileSync(routes, `module.exports = async (req, res, t) => {
      if (t.pathname === "/api/hello") { t.sendJson(res, 200, { hello: "table" }); return true; }
      if (t.pathname === "/api/crash") { process.exit(3); }
      return false; };`);
    const started = Date.now();
    const r = await waitFor(async () => { const x = await fetch(`${site.base}/api/hello`); return x.ok && x.json(); });
    assert.deepEqual(r, { hello: "table" });
    assert.ok(Date.now() - started < 5000, `took ${Date.now() - started} ms`);
  });

  test("comes back after a crash", async () => {
    await fetch(`${site.base}/api/crash`).catch(() => {});
    const started = Date.now();
    await waitFor(() => fetch(`${site.base}/workshop.json`).then((r) => r.ok));
    assert.ok(Date.now() - started < 5000, `took ${Date.now() - started} ms`);
  });

  test("a mistake in team-routes.js switches those endpoints off but keeps the site up", async () => {
    fs.writeFileSync(path.join(site.dir, "server", "team-routes.js"), "module.exports = async (req, res) => { oops( };");
    await waitFor(() => fetch(`${site.base}/api/hello`).then((r) => r.status === 404));
    assert.equal((await fetch(`${site.base}/dashboard.html`)).status, 200);
    assert.match(site.output(), /team-routes\.js has a mistake/);
  });
});

describe("pushing workshop.json to the board", () => {
  let site, central;
  before(async () => { central = await startCentral(); site = await startSite({ central }); });
  after(async () => { await site.stop(); await central.stop(); });

  const file = () => path.join(site.dir, "workshop.json");
  const latest = () => central.received.at(-1);

  test("sends on start, with the team's key", async () => {
    await waitFor(() => central.received.length >= 1);
    assert.equal(latest().auth, `Bearer ${TOKEN}`);
    assert.equal(JSON.parse(latest().body).team, 7);
  });

  test("sends a change within a few seconds", async () => {
    const w = JSON.parse(fs.readFileSync(file(), "utf8"));
    w.emails = [{ id: "P0001", category: "correction", priority: false }];
    const changedAt = Date.now();
    fs.writeFileSync(file(), JSON.stringify(w));
    await waitFor(() => latest() && JSON.parse(latest().body).emails.length === 1);
    assert.ok(latest().at - changedAt < 4000, `took ${latest().at - changedAt} ms`);
  });

  test("skips a broken file and sends the next good one", async () => {
    const before = central.received.length;
    fs.writeFileSync(file(), '{"team": 7, "emails": [');
    await sleep(1500);
    assert.equal(central.received.length, before, "a broken file isn't sent");
    const push = JSON.parse(fs.readFileSync(path.join(site.dir, "logs", "push.json"), "utf8"));
    assert.match(push.skip_reason, /isn't valid JSON/);
    fs.writeFileSync(file(), JSON.stringify({ team: 7, name: "Fixed", emails: [], features: [] }));
    await waitFor(() => latest() && JSON.parse(latest().body).name === "Fixed");
  });

  test("keeps retrying while the board is down, then sends only the newest", async () => {
    central.status = 503;
    for (const name of ["v1", "v2", "v3"]) {
      fs.writeFileSync(file(), JSON.stringify({ team: 7, name, emails: [], features: [] }));
      await sleep(400);
    }
    await sleep(1000);
    const failed = central.received.length;
    central.status = 200;
    await waitFor(() => central.received.length > failed);
    await sleep(800);
    assert.equal(JSON.parse(latest().body).name, "v3");
    const push = JSON.parse(fs.readFileSync(path.join(site.dir, "logs", "push.json"), "utf8"));
    assert.ok(push.last_ok);
    assert.ok(!JSON.stringify(push).includes(TOKEN), "the push log never holds the key");
  });

  test("npm run check reports the board has the latest version", async () => {
    fs.writeFileSync(file(), JSON.stringify({ team: 7, name: "Check", updated: "2026-11-11T15:52:10+11:00", emails: [], features: [] }));
    await waitFor(() => latest() && JSON.parse(latest().body).name === "Check");
    await sleep(200);
    const { execFileSync } = require("child_process");
    const out = execFileSync(process.execPath, ["tools/check.js"], { cwd: site.dir, env: { ...process.env, WORKSHOP_TEAM: "7" } }).toString();
    assert.match(out, /The board last received your file \d+ seconds ago, and it has this version/);
  });
});

describe("stopping", () => {
  test("the site stops when its supervisor is killed, freeing the port", async () => {
    const site = await startSite();
    site.child.kill("SIGKILL");
    await waitFor(async () => {
      try { await fetch(`${site.base}/workshop.json`, { signal: AbortSignal.timeout(500) }); return false; } catch { return true; }
    }, { timeout: 5000 });
    require("fs").rmSync(site.dir, { recursive: true, force: true });
  });
});
