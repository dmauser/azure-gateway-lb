# SKILL: README ↔ Deploy Script Env Contract Sync

**Category:** Documentation / Maintenance Discipline  
**Discovered:** 2026-05-09T19:20:21-05:00  
**Author:** Flynn (Lead / Azure Architect)  
**Trigger:** Round 4 deploy blocker — `OPN_BOOTSTRAP_URI` missing from README caused operators to
miss a required pre-deploy action, halting the live deploy.

---

## Problem Class

The README documents environment variables for a bash deploy script. Over time, new env vars are
added to the script (or defaults change) without a corresponding update to the README. Operators
miss required variables, causing confusing deploy failures.

---

## Rule

**Every environment variable that `deploy.azcli` reads must have a corresponding row in the
README prerequisites table, with: name, required-vs-optional, default value, and description.**

---

## Audit Command

Run this after any deploy script change to find gaps:

```bash
# Extract all env vars referenced in deploy.azcli with defaults:
grep -E '\$\{[A-Z_]+:-' deploy.azcli | grep -oE '\$\{[A-Z_]+:-[^}]+\}' | sort -u

# Cross-check against README:
grep -E '^\| `[A-Z_]+`' README.md | awk -F'`' '{print $2}' | sort
```

Any var in the first list but not the second is a documentation gap.

---

## Required Table Format

```markdown
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `VAR_NAME` | yes/no | `default` or — | What it controls; behavior note |
```

For each var, document:
- **Required:** yes if the script exits without it; no if it has a default
- **Default:** the exact default value from the script (not paraphrased)
- **Description:** what the var controls AND any important caveats (e.g., "must point to a pushed
  branch — cloud-init fetches this URL at first boot")

---

## When to Apply

- Before merging any PR that adds/changes/removes an env var in the deploy script
- Before any live deploy by a new operator who hasn't run the script before
- As part of the documentation review checklist in PR review

---

## Applied In

- `README.md` — updated prerequisites table to include `OPN_BOOTSTRAP_URI` with its "must point to
  pushed code" caveat (Round 4 lesson)
- `.squad/decisions/inbox/flynn-docs-improvement.md` — principle formally stated
