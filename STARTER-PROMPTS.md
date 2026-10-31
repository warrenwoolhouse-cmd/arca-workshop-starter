# Starter prompts

Paste them in order. Change the words to suit your table.

## 1. Get triage working

> Read CLAUDE.md. Build a tool that labels all 250 emails in data/practice.json with a category and a priority flag, following the labelling rule, and writes the answers into workshop.json. Then check it against the 75 known answers in data/practice-key.csv and tell us, in plain English, how many it got right and which ones it got wrong.

## 2. Learn from the mistakes

> Look at the emails our tool got wrong in the known answers. Explain each mistake in a sentence, suggest changes to the classification instructions, make the changes, re-run, and show us whether the score improved.

## 3. Our supervisor's dashboard

> Build our supervisor's dashboard at site/dashboard.html: volumes by category, how many are priority, a "deal with these first" list with the reason for each, and the oldest emails. Make it clean and readable from across a room. When it meets the scoring sheet, mark supervisor_view as done in workshop.json, and give us the address to open it.

## 4. Be ready for 4:05

> At 4:05pm a new batch of 250 emails will appear at https://warrenwoolhouse.com/batch2. Make one command that fetches them, labels them with our tool and adds them to workshop.json. Test it now on a copy of 20 morning emails, then tell us exactly what to type at 4:05.

## If you're stuck

> Something isn't working. Stop, and tell us in plain English where things stand. Then get the simplest version working: a category and priority flag for every email in workshop.json, even if they're rough.
