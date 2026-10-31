// Writes the files that depend on which table this laptop is: TABLE.md (read
// by Claude Code through CLAUDE.md) on every start, and a starting
// workshop.json if there isn't one yet. Don't change this file.

const fs = require("fs");
const path = require("path");
const config = require("./config");

// ISO 8601 in Australia/Sydney time, e.g. 2026-11-11T15:52:10+11:00
function sydneyIso(date = new Date()) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-AU", {
      timeZone: "Australia/Sydney", hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
    }).formatToParts(date).map((p) => [p.type, p.value]),
  );
  const local = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
  const offset = Math.round((local - Math.floor(date.getTime() / 1000) * 1000) / 60000);
  const sign = offset >= 0 ? "+" : "-";
  const hh = String(Math.floor(Math.abs(offset) / 60)).padStart(2, "0");
  const mm = String(Math.abs(offset) % 60).padStart(2, "0");
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}${sign}${hh}:${mm}`;
}

function tableNotes() {
  if (!config.TEAM) {
    return `# This laptop isn't set up for a table yet

The install script hasn't set WORKSHOP_TEAM on this laptop. Tell the table to ask Warren, and don't guess a table number.
`;
  }
  const n = config.TEAM;
  const site = config.SITE_URL || `https://team${n}.warrenwoolhouse.com`;
  const central = config.CENTRAL_URL || "https://workshop.warrenwoolhouse.com";
  const name = config.TEAM_NAME || `Table ${n}`;
  return `# This laptop is Table ${n}: ${name}

Written by the local site each time it starts, from this laptop's settings. Don't edit it; it's rewritten.

- **Table number:** ${n}. \`workshop.json\` must say \`"team": ${n}\`. The board shows this table as Table ${n}.
- **Team name:** ${name}. That's the name the laptop was set up with. If the table picks a new name, change \`"name"\` in \`workshop.json\` and the board picks it up.
- **The table's site:** ${site}. Give this address whenever you tell people where to look, with the page on the end, for example ${site}/dashboard.html. Never mention localhost or a port.
- **Phones:** people get into ${site} through the link on their team page. Through the internet the site needs the team's key, which is in \`WORKSHOP_TEAM_TOKEN\`. Never show, print or save the key anywhere.
- **The board** at ${central} reads this table's \`workshop.json\` a few seconds after every change.
- **Hand labels from phones:** \`GET ${central}/api/team/labels\` with the header \`Authorization: Bearer <WORKSHOP_TEAM_TOKEN>\`. Read the key from the environment variable in code; never type it out.
- **The afternoon's emails:** https://warrenwoolhouse.com/batch2 from 4:05pm.
`;
}

function startingWorkshop() {
  let features = [];
  try {
    features = JSON.parse(fs.readFileSync(path.join(config.DATA_DIR, "features.json"), "utf8"))
      .map((f) => ({ feature: f.slug, done: false }));
  } catch { /* data/features.json missing: start with none */ }
  return {
    team: config.TEAM,
    name: config.TEAM_NAME || (config.TEAM ? `Table ${config.TEAM}` : ""),
    updated: sydneyIso(),
    emails: [],
    features,
  };
}

function writeTableFiles() {
  fs.writeFileSync(config.TABLE_FILE, tableNotes());
  if (!fs.existsSync(config.WORKSHOP_FILE)) {
    fs.writeFileSync(config.WORKSHOP_FILE, JSON.stringify(startingWorkshop(), null, 2) + "\n");
  }
}

module.exports = { writeTableFiles, sydneyIso, startingWorkshop, tableNotes };
