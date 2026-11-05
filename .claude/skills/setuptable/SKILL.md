---
name: setuptable
description: Set up this table on the workshop board: sets the team's name and checks this laptop is connected. Use when the table names or renames the team, or asks whether they're connected to the board.
argument-hint: "[team name]"
allowed-tools: Bash(npm run setuptable) Bash(npm run setuptable *)
---

Set up this table on the board.

1. Work out the team name: $ARGUMENTS
   If that's empty, use the name the table has just given in this conversation, if any. If there's no name, don't ask for one: the current name is kept.
2. Run `npm run setuptable -- "<team name>"`, or `npm run setuptable` with no name. Keep the name as the table wrote it, up to 40 characters.
3. Tell the table what happened in one or two short sentences of plain English: their team name, and either "look for your tile on the big screen" or exactly what to fix. Don't show the command or its output. If a line says to ask Warren, tell them to put a hand up for Warren.
