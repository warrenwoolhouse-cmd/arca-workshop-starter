// npm run hello [team name]: say hello to the board.
// Sets the team's name in workshop.json (keeping everything else in it), sends
// the file straight to the board, and checks the table's site answers at its
// public address. Says, in plain English, what worked and what didn't.
// The /hello skill in Claude Code runs this.

const fs = require("fs");
const config = require("../server/config");
const { startingWorkshop, sydneyIso } = require("../server/table");

const UA = "arca-workshop-hello/1.0";
const results = [];
const ok = (text) => results.push(["OK  ", text]);
const fix = (text) => results.push(["FIX ", text]);

function finish(name) {
  console.log("\nSaying hello to the board\n");
  for (const [mark, text] of results) console.log(`  ${mark} ${text}`);
  const failed = results.some(([mark]) => mark === "FIX ");
  console.log(failed
    ? "\nNot everything worked yet. Fix the lines marked FIX, then say hello again.\n"
    : `\nHello from ${name}, table ${config.TEAM}. Look for your tile on the big screen.\n`);
  process.exitCode = failed ? 1 : 0;
}

async function main() {
  const name = process.argv.slice(2).join(" ").replace(/\s+/g, " ").trim().slice(0, 40);
  if (!config.TEAM || !config.TOKEN || !config.CENTRAL_URL || !config.SITE_URL) {
    fix("This laptop hasn't been set up for the workshop yet: its table settings are missing. Ask Warren.");
    return finish(name);
  }

  // 1. The name, in workshop.json. A broken file is left alone: the table's tool owns it.
  let w;
  let text = null;
  try { text = fs.readFileSync(config.WORKSHOP_FILE, "utf8"); } catch { /* missing: start one */ }
  if (text === null) w = startingWorkshop();
  else {
    try { w = JSON.parse(text); } catch { w = null; }
    if (!w || typeof w !== "object" || Array.isArray(w)) {
      fix("workshop.json is broken, so I haven't changed it. Run npm run check to see where it breaks, fix it, then say hello again.");
      return finish(name);
    }
  }
  if (name) w.name = name;
  if (typeof w.name !== "string" || !w.name.trim()) w.name = config.TEAM_NAME || `Table ${config.TEAM}`;
  w.team = config.TEAM;
  w.updated = sydneyIso();
  const out = JSON.stringify(w, null, 2) + "\n";
  fs.writeFileSync(`${config.WORKSHOP_FILE}.tmp`, out);
  fs.renameSync(`${config.WORKSHOP_FILE}.tmp`, config.WORKSHOP_FILE);
  ok(name ? `Your team name is now "${w.name}".` : `Your team name is "${w.name}". To change it, say hello again with the new name.`);

  // 2. Straight to the board.
  try {
    const res = await fetch(`${config.CENTRAL_URL}/api/team/workshop`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${config.TOKEN}`, "User-Agent": UA },
      body: out,
      signal: AbortSignal.timeout(10000),
    });
    if (res.ok) ok("The board has your file.");
    else if (res.status === 401 || res.status === 403) fix("The board didn't recognise this laptop's table key. Ask Warren.");
    else fix(`The board couldn't take your file (it answered ${res.status}). Try again in a minute; if it keeps happening, ask Warren.`);
  } catch {
    fix("Couldn't reach the board. Check this laptop is on the wifi, then try again.");
  }

  // 3. The table's site, through the internet: what phones and the board's pictures use.
  try {
    const res = await fetch(`${config.SITE_URL}/workshop.json`, {
      headers: { "X-Workshop-Key": config.TOKEN, "Cache-Control": "no-store", "User-Agent": UA },
      signal: AbortSignal.timeout(10000),
    });
    if (res.ok) ok(`Your site answers at ${config.SITE_URL}, so phones and the board can see it.`);
    else fix(`Your site at ${config.SITE_URL} isn't reachable from the internet yet (it answered ${res.status}). Phones and the board's pictures won't work until it is. Restarting the laptop usually fixes it; if not, ask Warren.`);
  } catch {
    fix(`Your site at ${config.SITE_URL} didn't answer. Phones and the board's pictures won't work until it does. Restarting the laptop usually fixes it; if not, ask Warren.`);
  }
  finish(w.name);
}

main();
