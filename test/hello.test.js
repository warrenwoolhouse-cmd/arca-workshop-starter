const assert = require("node:assert/strict");
const { execFile } = require("child_process");
const fs = require("fs");
const path = require("path");
const { after, before, describe, test } = require("node:test");
const { TOKEN, startSite, startCentral } = require("./helpers");

// Runs npm run hello's script in the site's folder, with the site as its "public" address.
function hello(site, central, args = [], env = {}) {
  return new Promise((resolve) => {
    execFile(process.execPath, ["tools/hello.js", ...args], {
      cwd: site.dir,
      env: {
        ...process.env, WORKSHOP_TEAM: "7", WORKSHOP_TEAM_NAME: "Test Table", WORKSHOP_TEAM_TOKEN: TOKEN,
        WORKSHOP_SITE_URL: site.base, WORKSHOP_CENTRAL_URL: central.url, ...env,
      },
    }, (err, stdout) => resolve({ code: err ? err.code : 0, out: stdout }));
  });
}

describe("npm run hello", () => {
  let site, central;
  before(async () => { central = await startCentral(); site = await startSite({ central }); });
  after(async () => { await site.stop(); await central.stop(); });
  const file = () => path.join(site.dir, "workshop.json");

  test("sets the team name, keeps the labels, sends the file to the board and checks the site", async () => {
    const w = JSON.parse(fs.readFileSync(file(), "utf8"));
    w.emails = [{ id: "P0001", category: "general", priority: false }];
    fs.writeFileSync(file(), JSON.stringify(w));
    const before = central.received.length;
    const r = await hello(site, central, ["Fine", "Print"]);
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /Your team name is now "Fine Print"/);
    assert.match(r.out, /The board has your file/);
    assert.match(r.out, /Your site answers/);
    assert.match(r.out, /Hello from Fine Print, table 7/);
    const after = JSON.parse(fs.readFileSync(file(), "utf8"));
    assert.equal(after.name, "Fine Print");
    assert.equal(after.team, 7);
    assert.deepEqual(after.emails, w.emails);
    const sent = central.received.slice(before).find((x) => JSON.parse(x.body).name === "Fine Print");
    assert.ok(sent, "the board got the renamed file");
    assert.equal(sent.auth, `Bearer ${TOKEN}`);
    assert.ok(!r.out.includes(TOKEN), "never prints the key");
  });

  test("with no name, keeps the current one", async () => {
    const r = await hello(site, central);
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /Your team name is "Fine Print"/);
  });

  test("leaves a broken file alone and says how to fix it", async () => {
    const good = fs.readFileSync(file(), "utf8");
    fs.writeFileSync(file(), '{"team": 7, "emails": [');
    const r = await hello(site, central, ["Other Name"]);
    assert.equal(r.code, 1);
    assert.match(r.out, /workshop.json is broken, so I haven't changed it/);
    assert.equal(fs.readFileSync(file(), "utf8"), '{"team": 7, "emails": [');
    fs.writeFileSync(file(), good);
  });

  test("says plainly when the board refuses the key or the site can't be reached", async () => {
    central.status = 401;
    const r = await hello(site, central, [], { WORKSHOP_SITE_URL: "http://127.0.0.1:9" });
    central.status = 200;
    assert.equal(r.code, 1);
    assert.match(r.out, /didn't recognise this laptop's table key/);
    assert.match(r.out, /didn't answer/);
    assert.doesNotMatch(r.out, /ECONNREFUSED|TypeError|at .*\.js/);
  });

  test("a laptop that isn't set up is told to ask Warren", async () => {
    const r = await hello(site, central, [], { WORKSHOP_TEAM_TOKEN: "" });
    assert.equal(r.code, 1);
    assert.match(r.out, /hasn't been set up for the workshop yet/);
  });
});
