# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Bicep / ARM templates | Clu | Edit `bicep/`, `ARM/`, parameters, API versions |
| OPNsense / scripts / VXLAN | Ram | `scripts/*.sh|xml|py`, `linux-vxlan.azcli` |
| Architecture / network design | Flynn | Topology, NSGs, routing, README accuracy |
| Code review | Flynn | Review PRs, gate risky changes |
| Testing / validation | Quorra | `bicep build`, `deployment validate`, traffic tests |
| OPNsense bootstrap mechanism (extension/customData/script glue) | Beck | end-to-end ownership of first-boot bootstrap, may author across bicep+scripts+deploy.azcli within that scope |
| In-VM diagnostics / serial console | Dumont | SSH/serial-console into deployed VMs, gather evidence, author debug runbooks |
| Scope & priorities | Flynn | What to build next, trade-offs, decisions |
| Session logging | Scribe | Automatic — never needs routing |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Lead |
| `squad:{name}` | Pick up issue and complete the work | Named member |

### How Issue Assignment Works

1. When a GitHub issue gets the `squad` label, the **Lead** triages it — analyzing content, assigning the right `squad:{member}` label, and commenting with triage notes.
2. When a `squad:{member}` label is applied, that member picks up the issue in their next session.
3. Members can reassign by removing their label and adding another member's label.
4. The `squad` label is the "inbox" — untriaged issues waiting for Lead review.

## Rules

1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work.
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Anticipate downstream work.** If a feature is being built, spawn the tester to write test cases from requirements simultaneously.
7. **Issue-labeled work** — when a `squad:{member}` label is applied to an issue, route to that member. The Lead handles all `squad` (base label) triage.
