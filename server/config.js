// Settings for the local site, all from the laptop's environment variables
// (set by the install script). Don't change this file.

const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const team = Number.parseInt(process.env.WORKSHOP_TEAM || "", 10);

module.exports = {
  ROOT,
  SITE_DIR: path.join(ROOT, "site"),
  DATA_DIR: path.join(ROOT, "data"),
  SAVED_DIR: path.join(ROOT, "saved"),
  LOGS_DIR: path.join(ROOT, "logs"),
  WORKSHOP_FILE: path.join(ROOT, "workshop.json"),
  TABLE_FILE: path.join(ROOT, "TABLE.md"),

  PORT: Number.parseInt(process.env.WORKSHOP_PORT || "8080", 10),
  TEAM: Number.isInteger(team) ? team : null,
  TEAM_NAME: process.env.WORKSHOP_TEAM_NAME || "",
  TOKEN: process.env.WORKSHOP_TEAM_TOKEN || "",
  SITE_URL: (process.env.WORKSHOP_SITE_URL || "").replace(/\/+$/, ""),
  CENTRAL_URL: (process.env.WORKSHOP_CENTRAL_URL || "").replace(/\/+$/, ""),

  // Push timings (CONTRACTS.md section 11). Tests shorten them.
  PUSH_SETTLE_MS: Number.parseInt(process.env.WORKSHOP_PUSH_SETTLE_MS || "2000", 10),
  PUSH_EVERY_MS: Number.parseInt(process.env.WORKSHOP_PUSH_EVERY_MS || "20000", 10),
  PUSH_RETRY_MS: Number.parseInt(process.env.WORKSHOP_PUSH_RETRY_MS || "3000", 10),
};
