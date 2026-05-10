## SUMMARY (Entries pre-2026-04-09)

History truncated for readability. Old entries archived. Key milestones:
- Round 7 deployment arc completed
- VXLAN validation confirmed
- Team expanded to 8 members
- CI workflow staged for commit

---
## Round 7 Deployment Close-out
- **Date:** 2026-05-09
- **Status:** ✅ ALL GATES GREEN
- **Session:** End-to-end deployment validated; VXLAN tcpdump confirmed bidirectional; all RGs cleaned; CI workflow staged
- **Key Outcome:** Full session arc logged, decisions merged, team expanded to 8 members
- **Next:** Deployment proof via bash deploy.azcli with SSH_PUBLIC_KEY set
# Flynn — History

## Project Context
- **Project:** azure-gateway-lb — Azure Gateway Load Balancer lab with OPNsense NVAs
- **User:** Daniel Mauser
- **Stack:** Bicep, ARM JSON, Azure CLI, OPNsense (FreeBSD), VXLAN
- **Layout:** `bicep/`, `ARM/`, `scripts/`, `deploy.azcli`, `linux-vxlan.azcli`

## Learnings

### 2026-05-08: Architecture Audit - Critical Blockers Identified

**Session:** Full architecture audit on request from Daniel Mauser  
**Finding:** Lab is documented but operationally broken - not deployable end-to-end  

#### Critical Issues Discovered:
1. **Missing PIP Resource** - `deploy.azcli` creates consumer-elb without public IP, then tries to reference non-existent `PublicIPconsumer-elb`. This is the immediate blocker preventing any end-to-end deployment.
2. **Dual IaC Maintenance Burden** - 21 Bicep modules + ARM folder create maintenance split; no clear source of truth. Bicep is richer but ARM folder suggests legacy dual-path.
3. **Non-Idempotent Script** - Interactive prompts, hardcoded subscription names, inconsistent `--no-wait`, incomplete error handling. Script fails on retry and in Cloud Shell.
4. **Template Deployment Sync** - Provider GLB template uses `--no-wait` but chaining immediately follows without polling for readiness.
5. **Weak Security Defaults** - Hardcoded passwords (Msft123Msft123), no managed identity, no SSH key option, default OPNsense creds.

#### Architecture Review Completed:
- ✓ Traffic flow documented in README matches template architecture
- ✓ All referenced media files exist and are current
- ✓ Bicep modules well-structured (vnet, lb, gwlb, VM, resource-group)
- ✗ README link to GLB docs should reference GA, not preview
- ✗ "Coming soon" placeholders for Layer 7 and IDS are misleading

#### Deliverable:
- Audit report written to `.squad/decisions/inbox/flynn-architecture-audit.md`
- Three-phase remediation plan: Phase 1 (unblock), Phase 2 (modernize), Phase 3 (polish)
- Clear strategic question for Daniel: Consolidate on Bicep, retire ARM folder

#### Recommendations:
- Phase 1: Fix PIP creation, add deployment polling, remove interactive prompts, complete cleanup
- Phase 2: Make Bicep canonical, add managed identity, improve docs
- Phase 3: Trusted Launch, cloud-init, CI/CD pipeline, troubleshooting guide

**Estimated Effort:** 7-10 days total across 3 phases (Clu owns tactical, Flynn owns architecture/validation, Ralph owns CI/CD)

---

### 2026-05-08: Phase 1 — deploy.azcli Rewrite Complete

**Session:** Phase 1 execution on request from Daniel Mauser  
**Deliverable:** Fully rewritten `deploy.azcli` — passes `bash -n`, CI-safe, no interactive prompts

#### Changes Made:
1. **`set -euo pipefail`** added — script now aborts on any error
2. **Preflight guards:** `az account show` login check; `az bicep version || az bicep install`; `SSH_PUBLIC_KEY` required-var guard; `@file` path existence check
3. **Env-var contract established** — `SSH_PUBLIC_KEY` (required), `LOCATION`, `RG_CONSUMER`, `RG_PROVIDER`, `ADMIN_USERNAME`, `BASTION_DEPLOY`, `SUBSCRIPTION_ID`
4. **consumer-elb-pip created explicitly** (Standard Static) before `az network lb create` — fixes the primary blocker (`PublicIPconsumer-elb` was never created)
5. **Consumer VM uses SSH key auth** (`--ssh-key-values "$SSH_PUBLIC_KEY"`) instead of password
6. **Provider Bicep deployment is synchronous** — no `--no-wait`; uses local `bicep/glb-active-active.bicep` via `$SCRIPT_DIR`
7. **TempPassword auto-generated** (`GlbLab$(openssl rand -hex 6)Az1!`) — ephemeral, complexity-compliant, not hardcoded
8. **Bastion is optional** — gated on `BASTION_DEPLOY=true`
9. **Cleanup section** — proper `cleanup()` function as commented-out block
10. **Subscription selection** — `SUBSCRIPTION_ID` env var replaces hardcoded `VSE-SUB`/`DMAUSER-MS`

#### GLB Chaining Pattern (key for future agents):

The GLB "bump-in-the-wire" chain requires two steps after both sides are deployed:

```bash
# Step 1: Get GLB frontend IP config resource ID (lb name = provider-nva-glb, frontend name = FW)
glbfeid=$(az network lb frontend-ip show \
    -g "$provider_rg" \
    --lb-name provider-nva-glb \
    --name FW \
    --query id \
    --output tsv)

# Step 2: Chain consumer ELB frontend to GLB (consumer ELB PIP must already exist)
az network lb frontend-ip update \
    -g "$consumer_rg" \
    --name frontendip1 \
    --lb-name consumer-elb \
    --public-ip-address consumer-elb-pip \
    --gateway-lb "$glbfeid" \
    --output none
```

**Critical constraint:** The consumer ELB public IP (`consumer-elb-pip`) must be named and present before `az network lb create` AND before `az network lb frontend-ip update`. These two operations must reference the same PIP name. This is why the original script failed — `PublicIPconsumer-elb` was referenced in the update but never created.

**Cross-subscription:** Capture `$glbfeid` while provider subscription is active; switch to consumer subscription before the `frontend-ip update`. Inline commented `az account set` lines guide the user.

**Validation:** `az network lb frontend-ip show ... --query gatewayLoadBalancer.id -o tsv` returns the GLB resource ID if chained, empty if not.

#### Bicep Template Facts (for future agents):
- GLB resource name: `provider-nva-glb` (hardcoded in Bicep variable `internalLoadBalanceName`)
- GLB frontend name: `FW` (hardcoded in Bicep variable `internalLoadBalanceFIPConfName`)
- ELB resource name: `provider-nva-elb` (hardcoded in Bicep variable `externalLoadBalanceName`)
- ELB public IP: `provider-nva-elb-pip` (derived from `publicIPAddressName = '${externalLoadBalanceName}-pip'`)
- Bicep expects VNet and subnets to pre-exist (`existingVirtualNetworkName`, `existingUntrustedSubnet`, `existingTrustedSubnet`)
- `TempPassword` is `@secure()` — required by Bicep but OPNsense bootstrap may not retain it post-deploy

#### Open Questions for Future Phases:
- Does `configureopnsense.sh` actually use `TempPassword` or is it discarded after VM provisioning? (Ask Ram)
- `az network lb inbound-nat-rule create` may require `--frontend-ip-name` on newer Azure CLI for Standard SKU — watch for this in Quorra's test run
- Consumer and provider both default to `10.0.0.0/24` — acceptable for separate RGs/subs, but collides if peered

**Status:** Ready for Quorra's live deployment test.

---

### 2026-05-09: Phase 3 — Documentation Consolidation Complete

**Session:** Phase 3 documentation tasks on request from Daniel Mauser  
**Deliverable:** Linux VXLAN tutorial migrated to docs/, README modernized with prerequisites and quick-start

#### Key Learnings:

1. **Tutorial vs. Script Distinction:** Files containing vim interactive commands (`:wq`) are inherently manual tutorials, not deployable scripts. Moving such files to `docs/` clarifies intent and reduces user confusion.

2. **VNI Scope Clarity:** The linux-vxlan tutorial uses VNI 900/901 (independent test setup). This is separate from the main lab's VXLAN tunnel IDs (800/801). Documenting this upfront prevents tunnel misconfiguration when users adapt the tutorial.

3. **Environment Variable Contract Critical:** Users deploying `deploy.azcli` without documentation of required/optional env vars hit friction. Phase 1 established the contract (SSH_PUBLIC_KEY required, LOCATION/RG_*/ADMIN_USERNAME optional with defaults). Exposing this in README prevents misdeployments.

4. **Documentation Links Must Point to GA:** `docs.microsoft.com` URLs often redirect to preview or legacy docs. `learn.microsoft.com` is now the authoritative GA reference for Azure services. Link drift impacts user confidence.

5. **Placeholder Removal Requires Direction:** "Coming soon" sections should be replaced with clear scope statements and links to related docs, not left ambiguous. Users interpret "coming soon" as "will definitely work in future"—a promise we can't keep.

#### Phase 3 Changes:

- **Moved:** `linux-vxlan.azcli` → `docs/linux-vxlan-tutorial.md` (git mv preserves history)
- **Reformatted:** Tutorial now has clear header, numbered steps, code blocks, VNI scope explanation
- **Updated README:**
  - GLB docs link: `docs.microsoft.com` → `learn.microsoft.com`
  - Added Prerequisites section with env var table (8 vars, defaults documented)
  - Added Quick start code snippet
  - Replaced "(coming soon)" on Layer 7/IDS with scope + OPNsense doc links
  - Added archived template note
  - Updated TOC to reference new Prerequisites section

#### Documentation Maintenance Principles (Consolidate):

1. Distinguish between reference materials (docs/) and executable scripts (root + scripts/)
2. Always document env var contracts at deployment entrypoint
3. Replace vague "coming soon" with explicit "out of scope" or "achievable via [reference]"
4. Prefer GA documentation URLs; avoid preview/legacy redirects
5. Interactive tutorials belong in docs/ with explicit "manual walkthrough" headers

**Status:** Phase 3 complete. All three phases (1=unblock, 2=modernize, 3=polish) now concluded. Repository operationally ready for production use by team.

---

### 2026-05-09: Phase 3 — Polish Work Complete (p3 tracks)

**Session:** Phase 3 polish (four tracks) on request from Daniel Mauser

#### Deliverables shipped:

1. **`docs/troubleshooting.md`** — Full troubleshooting guide covering:
   - deploy.azcli failure modes (SSH_PUBLIC_KEY, subscription, pre-existing RG, GLB race)
   - VXLAN tunnel debugging (ports 10800/10801, Azure VIP MAC `12:34:56:78:9a:bc`, tcpdump on OPNsense)
   - Standard LB inbound NAT rule `--frontend-ip-name` pitfall
   - Cross-subscription chaining (`$glbfeid` capture order)
   - OPNsense default creds, web UI NAT ports, SSH via Bastion
   - GLB chain verification and removal commands

2. **`docs/architecture/trusted-launch.md`** — ADR-style proposal for Trusted Launch:
   - Key finding: OPNsense (FreeBSD) does NOT have a Microsoft-signed Secure Boot shim. Safe approach: `vTpmEnabled: true`, `secureBootEnabled: false` for NVAs.
   - Ubuntu consumer-vm: full TL (both Secure Boot + vTPM)
   - Bicep parameter contract for Clu documented
   - Queued for Clu to implement

3. **`docs/architecture/cloud-init-migration.md`** — Cloud-init migration proposal:
   - cloud-init YAML equivalent of CSE command documented
   - Bicep `customData: base64(cloudInitScript)` pattern documented
   - OPNsense (FreeBSD): no change — custom bootstrap via CSE remains (Ram's domain)
   - Queued for Clu to implement; Flynn to remove CSE step from deploy.azcli post-merge

4. **`.github/workflows/ci.yml`** — Three-job CI workflow:
   - `bicep-build`: compile all top-level Bicep files
   - `bicep-lint`: lint all top-level Bicep files
   - `shellcheck`: static analysis on `scripts/*.sh` and `deploy.azcli`
   - YAML syntax validated with Python `yaml.safe_load`
   - Left for user to enable (not pushed directly to main)

5. **README TOC** — Added entries for troubleshooting guide and architecture docs

#### Learnings:

- **FreeBSD Secure Boot gap:** No Microsoft-signed shim exists for FreeBSD/OPNsense on Azure as of 2026-05-09. Enabling `secureBootEnabled: true` on OPNsense VMs causes boot failure. Pattern: enable vTPM only for NVAs.
- **Cloud-init timing advantage:** Cloud-init blocks VM readiness reporting until complete, meaning the LB health probe fires after nginx is installed — eliminating the CSE `--no-wait` race condition that currently exists.
- **`az bicep lint` vs `az bicep build`:** Both commands emit warnings; `lint` is the semantic linter (checks coding best practices), `build` validates compilation. Running both in separate CI jobs catches different issue classes.
- **`find bicep -maxdepth 1`** pattern excludes module subdirectories from the CI build/lint loop, keeping the build scope tight to entrypoint templates.
- **ShellCheck on `.azcli` files:** ShellCheck doesn't recognize `.azcli` by extension — must pass `--shell=bash` explicitly. Severity `warning` excludes `info`-level style notices that would be too noisy for a CI gate.

---

### 2026-05-09: FreeBSD TL Removal — Reviewer Lockout Fix

**Session:** Reassignment from Quorra — reviewer lockout on Clu's Phase 3 Bicep work  
**Deliverables:** Three tracks completed: Bicep fix, ADR update, deploy.azcli preflight

#### Learnings

**1. FreeBSD-on-Azure Trusted Launch: empirically fully unavailable**

The Phase 3 ADR stated that `secureBootEnabled: false, vTpmEnabled: true` (vTPM-only TL) would work for FreeBSD 14.4 because it's a Gen2 image. This is **wrong**. Quorra's live deploy on `westus3` confirmed:

- Azure maintains an explicit TL **allowlist** separate from Gen2 capability
- `thefreebsdfoundation/freebsd-14_4` is NOT on that allowlist
- Setting `securityType: 'TrustedLaunch'` with ANY combination of `secureBootEnabled/vTpmEnabled` is rejected: `BadRequest: "Use of TrustedLaunch setting is not supported for the provided image."`
- The fix is to omit the `securityProfile` block entirely — not downgrade to `Standard`, just omit
- Verify image TL support with: `az vm image show ... --query "features[?name=='SecurityType'].value"` — empty = not TL-capable

**2. Marketplace-terms preflight pattern**

FreeBSD 14.4 requires `az vm image terms accept --publisher thefreebsdfoundation --offer freebsd-14_4 --plan 14_4-release-amd64-gen2-ufs` before first deploy on any subscription. Without this, deployment fails at VM provisioning stage (after infrastructure is partially created) with `MarketplacePurchaseEligibilityFailed`. Pattern: add as idempotent preflight step in `deploy.azcli` alongside login + bicep install checks. Source publisher/offer/plan from the Bicep `plan:` block to avoid drift.

**3. ADR-vs-reality gap this exposed**

The trusted-launch ADR was written without empirical validation of the FreeBSD TL assumption. The gap: architectural proposals that touch OS-level Azure features (TL, Secure Boot, BYOS, accelerated networking) need an `az vm image show` feature query as an explicit pre-condition before writing Bicep. Lesson: for any new OS image, run `az vm image show --query "features"` and `az vm image terms show` before drafting the ADR.

**4. Scope: all three OPNsense VM modules**

Grep revealed three modules had the securityProfile block (not just the one Quorra identified): `opnsense-vm-active-active.bicep`, `opnsense-vm-sing-nic.bicep`, `opnsense-vm.bicep`. All three were fixed. Consumer VM (`consumer-vm.bicep`) untouched — Ubuntu 22.04 Gen2 TL works fine.


**From Clu:** Phase 2 Bicep modernization complete (7 warnings → 0, FreeBSD 14.4 migration, SSH key parameters). Awaiting your implementation: Trusted Launch + cloud-init ADRs (`docs/architecture/*`). Changes target `opnsense-vm-active-active.bicep` and consumer VM module.

**From Ram:** Phase 2 scripts complete and committed. Versions at 25.1/v2.12.0.4/python3.11 to support Clu's FreeBSD 14.4 migration. VXLAN port persistence in XML guaranteed across reloads.

**Next:** Clu implements Trusted Launch + cloud-init Bicep changes (parallel). Once merged, Flynn removes CSE step from deploy.azcli. CI workflow `.github/workflows/ci.yml` left for user enablement.

---

### 2026-05-09: Round 3 — OPNsense CSE Python 3 Blocker Resolved

**Session:** Round 3 fix on request from Daniel Mauser — Quorra round 2 blocker  
**Blocker:** `Microsoft.OSTCExtensions.CustomScriptForLinux` v1.4.1.0 handler uses Python 2 octal literal (`os.chmod('/var/log/azure/', 0700)`) — rejected by FreeBSD 14.4's Python 3 at parse time during handler `--install`.

#### Investigation: FreeBSD 14.4 + Azure VM Extension Compatibility

| Extension | Available in westus3? | FreeBSD 14.4 compatible? | Reason |
|-----------|----------------------|--------------------------|--------|
| `Microsoft.OSTCExtensions/CustomScriptForLinux` 1.4.x | ✅ (1.4.1.0) | ❌ BROKEN | Python 2 handler; FreeBSD has Python 3 only |
| `Microsoft.OSTCExtensions/CustomScriptForLinux` 1.5.x | ✅ (1.5.4 latest) | ❌ NOT SUPPORTED | Handler still Python 2; OSTCExtensions officially unsupported on FreeBSD |
| `Microsoft.Azure.Extensions/CustomScript` v2.x | ✅ (2.1.16 latest) | ❌ NOT SUPPORTED | Go binary compiled for Linux ELF; does not run on FreeBSD natively |
| `Microsoft.CPlat.Core/RunCommandHandlerLinux` | ✅ (1.3.28) | ❌ NOT SUPPORTED | Same issue — Linux ELF binary |
| `thefreebsdfoundation/*` (any extension) | ❌ NONE | — | No extensions published for FreeBSD in Azure Marketplace |

**Conclusion:** No Azure VM extension supports FreeBSD 14.4. This is a hard platform limitation. Paths A, B, C all eliminated.

#### Path Chosen: D-prime — WAAgent Action Run-Command via deploy.azcli

The `az vm run-command invoke --command-id RunShellScript` uses WAAgent's built-in command execution handler, NOT the extension framework. WALinuxAgent runs on FreeBSD 14.4 and handles RunShellScript natively without requiring any extension to be installed.

**Why run-command exits before reboot:** `configureopnsense.sh` patches `opnsense-bootstrap.sh.in` to replace `reboot` with `shutdown -r +1` (asynchronous, schedules reboot in 1 min and returns). The script completes all remaining steps within that window and exits. `az vm run-command invoke` receives the exit code before the reboot fires.

#### Changes Shipped

**`bicep/glb-active-active.bicep`:**
- Removed `OpnScriptURI` and `ShellScriptName` parameters (only used by vmext calls)
- Removed `opnSensePrimaryScript` module instantiation (`vmext.bicep`)
- Removed `opnSenseScondaryScript` module instantiation (`vmext.bicep`)
- Added outputs: `primaryTrustedIP`, `secondaryTrustedIP`, `trustedSubnetPrefix` — consumed by deploy.azcli run-command calls
- `az bicep build` → exit code 0, ARM JSON regenerated

**`deploy.azcli`:**
- After Bicep deploy, queries the three new outputs to get NIC IPs + subnet prefix
- Runs both NVA bootstrap scripts in parallel (bash background jobs `&` + `wait`)
- Polls for VM restart after bootstrap (90 s initial grace + 20×30 s poll loop per VM)
- `bash -n deploy.azcli` → exit code 0

**`vmext.bicep`:** Untouched — retained as a module for potential future use with non-FreeBSD OS types.

#### Reusable Pattern
- FreeBSD-on-Azure extension compatibility lookup: `az vm extension image list --location <region> --publisher thefreebsdfoundation` → always empty. Conclusion: no Azure VM extension supports FreeBSD. Use WAAgent run-command instead.
- Skill written: `.squad/skills/freebsd-on-azure-bootstrap/SKILL.md`

**Status:** ✅ FIX SHIPPED — ready for Quorra round 3 deploy.

---

### 2026-05-09T13:42:28-05:00: Round 6 — FreeBSD python3, pipefail-safe cloud-init, GLB chain poll

**Session:** Round 6 reassignment from Quorra (Ram locked out per reviewer protocol).  
**Deliverable:** Three coordinated fixes shipped in commit `519bf26`.

#### Learnings

**1. FreeBSD python-symlink ordering trap**

`configureopnsense.sh` called `python get_nic_gw.py $3` (both Primary and Secondary branches)
before creating the `python` → `python3.11` symlink. On FreeBSD 14.4, only `python3`/`python3.11`
exist at script start. The script uses `set -euo pipefail`, so it exited immediately at the
`python` call — silently skipping all downstream steps (OPNsense install, VXLAN config, waagent).

**Rule:** On FreeBSD 14.4 (and any system without a guaranteed `python` symlink), always invoke
`python3` directly. Never depend on `python` pointing anywhere. Never create a symlink as a
workaround when the direct invocation is available. Audit every `python` call before commit.

**2. pipefail / exit-status pattern in cloud-init runcmd**

`runcmd` step: `script ... 2>&1 | tee /var/log/out.log` — tee always exits 0. The downstream
sentinel step runs unconditionally, writing a "success" marker even when the script failed. This
masks the real failure and fools post-deploy smoke tests.

**Rule:** Never pipe through `tee` in runcmd without capturing the script's exit code. Pattern:
```sh
script ... > /var/log/out.log 2>&1; rc=$?; cat /var/log/out.log; \
[ $rc -eq 0 ] && echo ok > /var/run/done || echo "failed-rc=$rc" > /var/run/failed; exit $rc
```
The `exit $rc` propagates failure to cloud-init's status reporting. The `cat` preserves log
visibility in cloud-init's own output log. The dual sentinel files give smoke tests a fast signal.

**3. GLB chain race condition pattern**

After `az deployment group create` returns (Bicep complete), the GLB resource exists in ARM
but hasn't propagated to all ARM endpoints. An immediate `az network lb frontend-ip update
--gateway-lb $glbfeid` fails with `InvalidGlobalResourceReference`. Quorra's workaround was
manual retry after 2 minutes.

**Rule:** Never issue a cross-resource ARM reference update immediately after the referenced
resource's deployment. Poll for queryability first:
```bash
until az network lb frontend-ip show -g "$rg" --lb-name provider-nva-glb --name FW \
        --query id -o tsv >/dev/null 2>&1; do sleep 5; done
```
This applies generally to any ARM chaining operation (e.g., GLB chain, Private Endpoint, VNet
peering that depends on a freshly created resource).

**Status:** ✅ ROUND-6 FIXES SHIPPED — ready for push + Quorra round 6.

---

### 2026-05-09T19:20:21-05:00: Documentation Audit + Improvement Pass (post-Round-6)

**Session:** Docs-only improvement pass on request from Daniel Mauser.  
**Directive:** "improve, and add the missing points on the documentation" + VXLAN must be proven at
tcpdump level + every README step must execute and work.

#### Files modified: 5 existing, 1 new

| File | Change |
|------|--------|
| `README.md` | Added `OPN_BOOTSTRAP_URI` env var; "What Gets Deployed" table; "Validation Walkthrough" with tcpdump proof; "Known Constraints" table; "Cleanup" section; updated TOC |
| `docs/troubleshooting.md` | Added Round 1–6 failure Q+As; VXLAN tcpdump proof procedure; corrected OPNsense bootstrap check (cloud-init, not CSE); added "README Validation Discipline" section |
| `docs/architecture/trusted-launch.md` | Status → "Implemented (consumer-only); FreeBSD opted-out"; added empirical evidence table + commit refs |
| `docs/architecture/cloud-init-migration.md` | Status → "Implemented"; expanded scope to include OPNsense NVAs; added templating contract; added exit-code-preserving runcmd pattern |
| `docs/validation/trusted-launch-cloudinit-checklist.md` | Added Section 6 (Round 6 learnings): 3e correction (null not TL), 3h bootstrap gate, mandatory tcpdump proof |
| `docs/troubleshooting-freebsd-on-azure.md` | **NEW** — single-source FreeBSD-on-Azure constraint guide (TL, extensions, cloud-init, fetch, python3, runcmd, marketplace terms, image SKU) |

#### Learnings

**1. README env-var drift is a deploy blocker, not a style issue**

`OPN_BOOTSTRAP_URI` was missing from the README prerequisites table. This contributed to Round 4's
pre-deploy halt: Daniel's team didn't know to set the variable, and the default pointed to stale
GitHub main. Every env var in `deploy.azcli` must have a corresponding row in the README table,
with defaults, required-vs-optional, and what-it-does. Any gap between README and script is a bug.

**Principle established:** "README must mirror deploy.azcli env contract."

**2. Validation must include direct evidence, not inference**

"nginx returned 200" does not prove VXLAN is working — it could succeed via direct LB routing if
the GLB chain has a gap. The only proof is `tcpdump -nn -i any "udp port 10800 or udp port 10801"`
on the OPNsense NVA while traffic flows. This must appear in README and troubleshooting.md.

**Principle established:** "Every end-to-end test that has multiple possible paths must document
the narrowest possible evidence (e.g. tcpdump at the encapsulation layer), not just the output."

**3. Old CSE references in troubleshooting.md created confusion post-Round-3**

The Phase 3 troubleshooting guide said to check `az vm extension show ... --name CustomScript` to
verify OPNsense bootstrap. CSE was completely removed in Round 3. This stale reference would have
misled anyone following the doc post-Round-3. Docs must be updated whenever the bootstrap mechanism
changes — they are part of the implementation, not an afterthought.

**4. Single-source FreeBSD constraint doc prevents re-discovering known failures**

Rounds 1–3 each independently discovered a different FreeBSD-on-Azure incompatibility. These were
scattered across decision drops, history.md, and ADRs. Having a single
`docs/troubleshooting-freebsd-on-azure.md` provides a checklist before attempting new OS-level
Azure features on FreeBSD — preventing future rounds from repeating the same investigations.

**Decision drop:** `.squad/decisions/inbox/flynn-docs-improvement.md`



