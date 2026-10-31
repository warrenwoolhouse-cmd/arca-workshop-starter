# WW Loans inbox triage: workshop starter

The starting folder for each table at Warren Woolhouse's hands-on workshop, ARCA Credit Summit, 11 November 2026. Everything in it is fictitious: WW Loans, Kestrel Credit Reporting and every person in the emails.

If you're at a table, you don't need this page: open Claude Code with the Start workshop shortcut and tell it what you want to build.

## What's here

| Path | What it is |
| --- | --- |
| `CLAUDE.md` | Instructions for the table's Claude Code. It imports `TABLE.md`, which the site writes for this laptop's table each time it starts |
| `data/` | The morning's 250 emails, 75 answers, the categories and the bonus features. The scoring sheet is on paper in the table pack |
| `site/` | The table's site. `dashboard.html` starts as a placeholder |
| `server/` | The local site (Node, no other packages). `team-routes.js` is the only file tables change |
| `tools/check.js` | `npm run check`: is `workshop.json` ready for the board? |
| `setup/` | Laptop setup, starting with the network check |

## Running the site

`npm start` runs the site on port 8080. The install script starts it at logon and publishes it through the table's Cloudflare tunnel at `https://teamN.warrenwoolhouse.com`. It reads these environment variables, all set by the install script:

| Variable | Used for |
| --- | --- |
| `WORKSHOP_TEAM`, `WORKSHOP_TEAM_NAME` | The starting `workshop.json` and `TABLE.md` |
| `WORKSHOP_TEAM_TOKEN` | The site's key through the tunnel, and sending `workshop.json` to the board |
| `WORKSHOP_SITE_URL`, `WORKSHOP_CENTRAL_URL` | Addresses in `TABLE.md`, and where to send `workshop.json` |
| `ANTHROPIC_API_KEY` | The table's own tools |
| `WORKSHOP_PORT` | Optional; 8080 unless set (for testing only) |

How the site behaves:
- **No publish step:** it reads files from disk on every request, and every response says `Cache-Control: no-store`.
- **It keeps itself running:** `server/supervisor.js` restarts it if it stops, and reloads it when anything in `server/` changes.
- **It only listens on the laptop itself** (127.0.0.1 and ::1). Requests that come through the tunnel carry Cloudflare's headers and need the team's key:
  - the `X-Workshop-Key` header, or
  - the `ww_key` cookie, which opening any page with `?key=` sets.

  Requests from the laptop itself need nothing.
- **It sends `workshop.json` to the board** about 2 seconds after each change, and every 20 seconds as well.

`npm test` checks all of this.
