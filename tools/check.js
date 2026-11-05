// npm run check: is workshop.json ready for the board?
// Checks the file against the workshop's rules and says, in plain English,
// what's right and what to fix. It doesn't score: the board does that.

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const read = (p) => fs.readFileSync(path.join(ROOT, p), "utf8");

const problems = [];
const warnings = [];
const good = [];

function finish() {
  const line = (mark, text) => console.log(`  ${mark} ${text}`);
  console.log("\nChecking workshop.json\n");
  good.forEach((t) => line("OK  ", t));
  warnings.forEach((t) => line("NOTE", t));
  problems.forEach((t) => line("FIX ", t));
  console.log(problems.length
    ? `\n${problems.length} thing${problems.length === 1 ? "" : "s"} to fix before the board can use everything.\n`
    : "\nworkshop.json is ready for the board.\n");
  process.exitCode = problems.length ? 1 : 0;
}

function main() {
  const categories = JSON.parse(read("data/categories.json"));
  const slugs = new Set(categories.map((c) => c.slug));
  const byName = new Map(categories.map((c) => [c.name.toLowerCase(), c.slug]));
  const features = JSON.parse(read("data/features.json"));
  const featureSlugs = new Set(features.map((f) => f.slug));
  // The table downloads the morning's emails as its first step, so they may not be here yet.
  try {
    const morning = JSON.parse(read("data/practice.json"));
    if (Array.isArray(morning) && morning.length === 250) good.push("The morning's 250 emails are in data/practice.json.");
    else warnings.push(`data/practice.json has ${Array.isArray(morning) ? morning.length : "no list of"} emails, not 250. Ask Claude Code to download the morning's emails again.`);
  } catch (err) {
    warnings.push(err.code === "ENOENT"
      ? "The morning's emails aren't on this laptop yet. Tell Claude Code where they are, and it will save them as data/practice.json."
      : "data/practice.json isn't a readable list of emails. Ask Claude Code to download the morning's emails again.");
  }
  const inBatch = (id, letter) => new RegExp(`^${letter}\\d{4}$`).test(id) && Number(id.slice(1)) >= 1 && Number(id.slice(1)) <= 250;

  let text;
  try { text = read("workshop.json"); } catch {
    problems.push("There's no workshop.json yet. Start the site (it creates one), or ask Claude Code to write it.");
    return finish();
  }
  let w;
  try { w = JSON.parse(text); } catch (err) {
    problems.push(`workshop.json isn't valid JSON, so the board can't read it (${err.message}). Ask Claude Code to fix it.`);
    return finish();
  }
  if (!w || typeof w !== "object" || Array.isArray(w)) {
    problems.push("workshop.json should be one object with team, name, updated, emails and features.");
    return finish();
  }

  // Team
  const envTeam = Number.parseInt(process.env.WORKSHOP_TEAM || "", 10);
  if (!Number.isInteger(w.team)) problems.push(`"team" should be your table number as a plain number, like 4.`);
  else if (Number.isInteger(envTeam) && w.team !== envTeam) problems.push(`"team" says ${w.team}, but this laptop is Table ${envTeam}.`);
  else good.push(`Table ${w.team}${w.name ? `: ${w.name}` : ""}.`);
  if (typeof w.name !== "string" || !w.name.trim()) problems.push(`"name" should be your team's name.`);
  if (w.updated !== undefined && (typeof w.updated !== "string" || Number.isNaN(Date.parse(w.updated)))) {
    warnings.push(`"updated" isn't a date and time the board can read. It's only for people, so this won't affect your score.`);
  }

  // Emails
  if (!Array.isArray(w.emails)) {
    problems.push(`"emails" should be a list, even if it's empty.`);
  } else {
    const seen = new Set();
    const dupes = new Set();
    const bad = { id: [], category: [], priority: [], displayName: [] };
    let morning = 0, afternoon = 0, flaggedMorning = 0, flaggedAfternoon = 0;
    for (const e of w.emails) {
      const id = e && typeof e.id === "string" ? e.id : null;
      const known = id && (inBatch(id, "P") || inBatch(id, "H"));
      if (!known) { bad.id.push(id ?? JSON.stringify(e && e.id)); continue; }
      if (seen.has(id)) dupes.add(id);
      seen.add(id);
      const cat = typeof e.category === "string" ? e.category : "";
      if (!slugs.has(cat)) {
        if (byName.has(cat.trim().toLowerCase())) bad.displayName.push(id);
        else bad.category.push(`${id} ("${cat}")`);
      }
      if (typeof e.priority !== "boolean") bad.priority.push(id);
      if (id.startsWith("P")) { morning++; if (e.priority === true) flaggedMorning++; }
      else { afternoon++; if (e.priority === true) flaggedAfternoon++; }
    }
    const list = (ids) => ids.slice(0, 8).join(", ") + (ids.length > 8 ? ` and ${ids.length - 8} more` : "");

    const morningLine = `Morning emails labelled: ${morning} of 250.`;
    if (morning === 250) good.push(morningLine);
    else if (afternoon === 0) warnings.push(`${morningLine} Missing ones score nothing.`);
    if (afternoon > 0) (afternoon === 250 ? good : warnings).push(`Afternoon emails labelled: ${afternoon} of 250.`);
    if (morning) good.push(`Flagged as priority: ${flaggedMorning} of ${morning} morning emails.`);
    if (afternoon) good.push(`Flagged as priority: ${flaggedAfternoon} of ${afternoon} afternoon emails.`);

    if (bad.id.length) problems.push(`These ids aren't emails in the workshop, so they're ignored: ${list(bad.id)}. Ids look like P0001 or H0001.`);
    if (bad.category.length) problems.push(`These categories aren't in data/categories.json, so they score nothing: ${list(bad.category)}.`);
    if (bad.displayName.length) warnings.push(`${bad.displayName.length} email${bad.displayName.length === 1 ? " uses" : "s use"} a category's full name instead of its short name (${list(bad.displayName)}). The board accepts it, but the short name (like "third_party") is safer.`);
    if (bad.priority.length) problems.push(`"priority" must be true or false (no quotes) for: ${list(bad.priority)}.`);
    if (dupes.size) problems.push(`These emails appear more than once, so the board might use either answer: ${list([...dupes])}.`);
  }

  // Features
  if (!Array.isArray(w.features)) {
    problems.push(`"features" should be a list, even if it's empty.`);
  } else {
    const done = [];
    for (const f of w.features) {
      if (!f || !featureSlugs.has(f.feature)) { warnings.push(`"${f && f.feature}" isn't one of the features in data/features.json, so it won't score.`); continue; }
      if (typeof f.done !== "boolean") { problems.push(`Feature "${f.feature}": "done" must be true or false.`); continue; }
      if (!f.done) continue;
      if (typeof f.url !== "string" || !f.url.startsWith("/")) { problems.push(`Feature "${f.feature}" is marked done but has no "url" showing where to see it, like "/dashboard.html".`); continue; }
      const page = f.url.split(/[?#]/)[0];
      const file = page === "/workshop.json" ? path.join(ROOT, "workshop.json") : path.join(ROOT, "site", page.endsWith("/") ? page + "index.html" : page);
      if (!fs.existsSync(file)) problems.push(`Feature "${f.feature}" points to ${f.url}, but there's no such page in site/ yet.`);
      else done.push(f.feature);
    }
    good.push(done.length ? `Features marked done: ${done.join(", ")}.` : "No features marked done yet.");
  }

  // Size
  const kb = Math.round(Buffer.byteLength(text) / 1024);
  if (kb > 1024) problems.push(`workshop.json is ${kb} KB. Keep it under 1 MB: leave out email text and long notes.`);

  // Nothing secret where the internet can see it
  const secrets = [process.env.ANTHROPIC_API_KEY, process.env.WORKSHOP_TEAM_TOKEN].filter((s) => s && s.length >= 12);
  const leaks = [];
  const scan = (file) => {
    let body;
    try { body = fs.readFileSync(file, "utf8"); } catch { return; }
    if (secrets.some((s) => body.includes(s)) || /sk-ant-[A-Za-z0-9_-]{10,}/.test(body)) leaks.push(path.relative(ROOT, file));
  };
  const walk = (dir) => {
    let entries = [];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const ent of entries) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) walk(p); else if (fs.statSync(p).size < 5 * 1024 * 1024) scan(p);
    }
  };
  scan(path.join(ROOT, "workshop.json"));
  walk(path.join(ROOT, "site"));
  walk(path.join(ROOT, "saved"));
  if (leaks.length) problems.push(`A secret key is in a file the site shows to the internet: ${leaks.join(", ")}. Remove it now.`);

  // Has the board heard from us?
  try {
    const s = JSON.parse(fs.readFileSync(path.join(ROOT, "logs", "push.json"), "utf8"));
    if (s.disabled) warnings.push("This laptop isn't set up to send to the board yet. Ask Warren.");
    else if (s.last_ok) {
      const ago = Math.round((Date.now() - Date.parse(s.last_ok)) / 1000);
      const latest = s.last_ok_hash === require("crypto").createHash("sha256").update(text).digest("hex");
      (ago < 60 ? good : warnings).push(`The board last received your file ${ago} seconds ago${latest ? ", and it has this version" : ""}.`);
    } else if (s.last_error) warnings.push(`The board hasn't received your file yet: ${s.last_error}.`);
  } catch {
    warnings.push("The site hasn't tried to send your file to the board yet. Is it running?");
  }

  finish();
}

main();
