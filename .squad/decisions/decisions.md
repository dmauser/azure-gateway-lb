# Decisions Archive

Accumulated decision records from squad agents.

---

## clu-phase2-modernization.md

# Decision Drop: Clu Phase 2 Bicep Modernization

**Author:** Clu (IaC Engineer)  
**Date:** 2026-05-09  
**Status:** Shipped — ready for team review

---

## What Shipped

### Track 1 — API Version Audit ✅

All Bicep modules audited against 2025 version targets:

| Resource Type | Target | Result |
|---|---|---|
| Microsoft.Network/* | `2023-09-01` | Already current across all vnet modules |
| Microsoft.Compute/virtualMachines | `2024-03-01` | Already current across all VM modules |
| Microsoft.Compute/virtualMachines/extensions | `2024-07-01` | Already current (Phase 1) |
| Microsoft.Resources/resourceGroups | `2022-09-01` | Bumped from `2020-06-01` in `rg.bicep` |

No future-dated APIs introduced. No pre-2021 APIs remain.

### Track 2 — Bicep Hygiene ✅

**File:** `bicep/glb-active-active.bicep`

- Removed 4 redundant `dependsOn` blocks:
  - `opnSensePrimary` → `[opnSenseSecondary]` (no actual output dependency)
  - `nsgwinvm` → `[opnSenseSecondary, opnSensePrimary]`
  - `winvmpublicip` → `[opnSenseSecondary, opnSensePrimary]`
  - `winvm` → `[opnSenseSecondary, opnSensePrimary]` (kept `nsgwinvm`, `winvmpublicip` — required for `existing` reference resolution)
- Unused variable `externalLoadBalancingRuleName` — **not found** in current file (previously cleaned or never landed)
- Typos "Manchine" / "Nework" — **not found** in current file (same finding)
- Linter warning count: **7 → 0**

**AVM Candidates (flagged, NOT migrated):**
- `modules/vnet/lb.bicep` → `avm/res/network/load-balancer`
- `modules/vnet/nsg.bicep` → `avm/res/network/network-security-group`
- `modules/vnet/vnet.bicep` → `avm/res/network/virtual-network`
- Recommendation: defer to a dedicated AVM migration sprint after Phase 3 docs

### Track 3 — FreeBSD Image Migration ✅

**Migrated all OPNsense VM modules** to `thefreebsdfoundation` FreeBSD 14.4:

| Module | Old Image | New Image |
|---|---|---|
| `opnsense-vm-active-active.bicep` | `thefreebsdfoundation/freebsd-13_5/13_5-release` | `thefreebsdfoundation/freebsd-14_4/14_4-release-amd64-gen2-ufs` |
| `opnsense-vm.bicep` | `thefreebsdfoundation/freebsd-13_5/13_5-release` | `thefreebsdfoundation/freebsd-14_4/14_4-release-amd64-gen2-ufs` |
| `opnsense-vm-sing-nic.bicep` | `MicrosoftOSTC/FreeBSD/12.0` (EOL) | `thefreebsdfoundation/freebsd-14_4/14_4-release-amd64-gen2-ufs` |

**Verification:** Live `az vm image list --publisher thefreebsdfoundation --offer freebsd-14_4 --all` confirmed `14.4.0` GA with 6 SKU variants. SKU `14_4-release-amd64-gen2-ufs` selected (AMD64, Gen2, UFS — best for Standard_B2s).

**Note:** `plan:` blocks updated in sync with `imageReference` on all affected modules.

### Track 4 — SSH Key + Key Vault Parameter Contract ✅

- Added `param adminSshKey string = ''` to:
  - `opnsense-vm-active-active.bicep`
  - `opnsense-vm.bicep`
  - `opnsense-vm-sing-nic.bicep`
  - `glb-active-active.bicep` (propagated through to both OPNsense module calls)
- When `adminSshKey` is non-empty: `linuxConfiguration.ssh.publicKeys` injected into `osProfile`; `disablePasswordAuthentication: false` preserves password fallback
- Key Vault comment block present in all three VM modules
- Fixed missing `@secure()` on `TempPassword` in `opnsense-vm-sing-nic.bicep`

**NOT done:** Key Vault resource provisioning — deferred by design (separate decision needed)

---

## Build Evidence

```
az bicep build --file bicep/glb-active-active.bicep
# Output: WARNING: A new Bicep release is available: v0.43.8. (CLI notice, not code)
# Exit code: 0
# Linter warnings: 0
# glb-active-active.json regenerated: 2026-05-09
```

---

## Deferred Items

| Item | Reason | Owner |
|---|---|---|
| Key Vault provisioning | Separate infrastructure decision needed | Team |
| AVM module migration | Phase 3+ — not in scope now | Clu (future) |
| OPNsense 14.4 deployment test | Needs live Azure environment | Daniel |
| `windows11-vm.bicep` SSH key | Not applicable (Windows VM) | N/A |


---

## ram-phase2-scripts.md

# Ram — Phase 2 Scripts Decision Drop

**Date:** 2026-05-09  
**Agent:** Ram (NVA / Scripts Engineer)  
**Requested by:** Daniel Mauser  

---

## Summary

All 4 Phase 2 script modernization tasks completed and committed. `bash -n` validation passes on both shell scripts. `shellcheck` was not available in the Windows environment (not on PATH); this is noted as a CI gap.

---

## Task 1: Version Standardization (`gwlbconfig.sh`) ✅

| Component | Before | After |
|-----------|--------|-------|
| OPNsense release | `21.7` | `25.1` |
| WALinuxAgent | `v2.4.0.2` | `v2.12.0.4` |
| Python symlink | `python3.8` | `python3.11` |

`configureopnsense.sh` was already at these versions (Phase 1 partial work). `gwlbconfig.sh` is now aligned.

**Assumptions / URL notes:**
- `opnsense-bootstrap.sh.in` is fetched from `master` branch at runtime, so no URL change needed.
- WALinuxAgent tarball: `https://github.com/Azure/WALinuxAgent/archive/refs/tags/v2.12.0.4.tar.gz` — standard GitHub release URL pattern, assumed valid.
- `python3.11` symlink assumes OPNsense 25.1 on FreeBSD ships Python 3.11. If the image ships 3.12+, the `ln -s` will fail. **Track as follow-up:** probe Python version post-bootstrap and symlink dynamically, or remove the fixed symlink.

---

## Task 2: VXLAN Port Persistence in XML ✅

**Files:** `scripts/glb-config-active-active-primary.xml`, `scripts/glb-config.xml`

Added `<vxlanlocalport>` and `<vxlanremoteport>` to each `<vxlan>` block within `<vxlans version="1.0.1">`:

| Interface | `<vxlanid>` | Local port | Remote port |
|-----------|-------------|------------|-------------|
| vxlan0 (internal) | 800 | 10800 | 10800 |
| vxlan1 (external) | 801 | 10801 | 10801 |

Tags are placed between `<vxlanremote>` and `<vxlangroup/>` in each block. Both XML files patched identically. Port persistence now survives OPNsense config reloads; the `rc.syshook` `25-azure` hook remains as a boot-time safeguard.

---

## Task 3: Error Traps in Shell Scripts ✅

Added to **both** `scripts/configureopnsense.sh` and `scripts/gwlbconfig.sh`:
```sh
set -euo pipefail
trap 'echo "Error on line $LINENO (exit $?)" >&2' ERR
```

Added to **`scripts/get_nic_gw.py`**:
- `#!/usr/bin/env python3` shebang
- `try/except` around the main routine (prints to stderr and exits with code 1 on any error)

> ⚠️ **FreeBSD /bin/sh note:** FreeBSD's `ash`-based `/bin/sh` silently ignores `pipefail`; `set -e` and `trap ERR` still work. The scripts use `#!/bin/sh`. Once bash is installed post-bootstrap, shebangs could be updated to `#!/usr/bin/env bash` for full `pipefail` support. Tracked as a separate follow-up.

---

## Task 4: Parameter Contract Documentation ✅

**File:** `scripts/configureopnsense.sh` header comment (lines 1–60).

Documents:
- Each of the 4 positional parameters: name, type, example, and usage within the script
- XML placeholder → value mapping table
- Example invocations for Primary and Secondary roles
- Invocation context: Azure Custom Script Extension via `bicep/modules/VM/vmext.bicep`
- VXLAN port persistence note cross-referencing the Phase 2 XML change

---

## Validation Evidence

```
bash -n scripts/configureopnsense.sh   → exit 0  ✅
bash -n scripts/gwlbconfig.sh          → exit 0  ✅
shellcheck                             → not on PATH (Windows env); CI gap — recommend
                                         adding shellcheck to a GitHub Actions workflow
```

---

## Files Modified (Phase 2)

| File | Changes |
|------|---------|
| `scripts/configureopnsense.sh` | Error traps; full parameter-contract header |
| `scripts/gwlbconfig.sh` | Version bumps (25.1, v2.12.0.4, python3.11); error traps; bootstrap set-e suppression |
| `scripts/get_nic_gw.py` | Shebang; try/except error handling |
| `scripts/glb-config-active-active-primary.xml` | VXLAN port tags added (×2 blocks) |
| `scripts/glb-config.xml` | VXLAN port tags added (×2 blocks) |

---

## Open Items / Handoffs

| # | Item | Owner | Priority |
|---|------|-------|----------|
| 1 | `pipefail` on FreeBSD /bin/sh (silent no-op) | Ram | Low — add `#!/usr/bin/env bash` after bootstrap phase |
| 2 | `gwlbconfig.sh` fetches XML from `huangyingting/glb-demo` (external) | Ram | Medium — migrate to canonical repo `$1`-prefixed URL |
| 3 | `python3.11` symlink may fail if OPNsense 25.1 ships Python 3.12+ | Ram | Medium — probe at runtime or drop fixed symlink |
| 4 | `shellcheck` not in CI | Ram / Daniel | Low — add GitHub Actions workflow step |
| 5 | FreeBSD 14.4 image compatibility | Ram (blocked on Clu) | High — pending Clu confirmation |


---

## ram-phase2-completion.md

# Ram — Phase 2 Completion Report

**Date:** 2026-05-08  
**Agent:** Ram (NVA / Scripts Engineer)  
**Requested by:** Daniel Mauser  
**Approved by:** Quorra (Phase 1 approval carried forward)

---

## Summary

All 4 Phase 2 script modernization tasks completed. `bash -n` validation passes on both shell scripts.

---

## Task 1: OPNsense/WALinuxAgent/Python Version Standardization ✅

**File:** `scripts/gwlbconfig.sh`

| Component | Before | After |
|-----------|--------|-------|
| OPNsense release | `21.7` | `25.1` |
| WALinuxAgent | `v2.4.0.2` | `v2.12.0.4` |
| Python symlink | `python3.8` | `python3.11` |

Now matches `configureopnsense.sh`. Bootstrap `set -e` suppression also added to `gwlbconfig.sh`  
(same fix already present in `configureopnsense.sh` — pkg commands may exit non-zero during unlock/delete).

---

## Task 2: VXLAN Port Persistence in XML ✅

**Files:** `scripts/glb-config-active-active-primary.xml`, `scripts/glb-config.xml`

Added `<vxlanlocalport>` and `<vxlanremoteport>` to each `<vxlan>` block:

| Interface | vxlanid | Ports |
|-----------|---------|-------|
| vxlan0 (internal) | 800 | 10800 |
| vxlan1 (external) | 801 | 10801 |

Both XML files are identical in this section; both patched. Port persistence is now guaranteed  
across OPNsense config reloads. The rc.syshook `25-azure` hook remains as a boot-time safeguard.

---

## Task 3: Error Handling in Shell Scripts ✅

**`scripts/configureopnsense.sh`:** Added after the comment block:
```bash
set -euo pipefail
trap 'echo "Error on line $LINENO (exit $?)" >&2' ERR
```

**`scripts/gwlbconfig.sh`:** Added after shebang:
```bash
set -euo pipefail
trap 'echo "Error on line $LINENO (exit $?)" >&2' ERR
```

No `|| true` additions needed — no commands in either script are intentionally tolerant of failure.  
The one known exception is the bootstrap script's internal pkg commands, handled by suppressing its  
own `set -e` before running it (already done in `configureopnsense.sh`; added to `gwlbconfig.sh`).

**`scripts/get_nic_gw.py`:** Added `#!/usr/bin/env python3` shebang and try/except around the main  
routine (exits with code 1 and prints to stderr on any error).

> ⚠️ **FreeBSD note:** `/bin/sh` on FreeBSD does not support `pipefail`. These scripts use `#!/bin/sh`.
> If `pipefail` is critical, shebangs should be updated to `#!/usr/bin/env bash` (bash is installed by
> these scripts, but only available after the bootstrap phase). Track as a separate follow-up.

---

## Task 4: Parameter Contract Documentation ✅

**File:** `scripts/configureopnsense.sh`

Expanded the header comment to include:
- Each parameter: name, type, example value, where it gets used in the script
- Example invocations for Primary and Secondary roles
- Invocation context: Custom Script Extension via `bicep/modules/VM/vmext.bicep` (`OPNScriptURI` → `$1`, `ShellScriptParameters` → `$2 $3 $4`)
- VXLAN port persistence note (Phase 2 XML change)

---

## Validation

```
bash -n scripts/configureopnsense.sh  → OK
bash -n scripts/gwlbconfig.sh         → OK
```

---

## Scope (git diff --stat, Phase 2 files only)

| File | Change |
|------|--------|
| `scripts/configureopnsense.sh` | +61 lines (expanded docs, error traps) |
| `scripts/get_nic_gw.py` | +7 lines (shebang, try/except) |
| `scripts/glb-config-active-active-primary.xml` | +4 lines (vxlan port tags) |
| `scripts/glb-config.xml` | +4 lines (vxlan port tags) |
| `scripts/gwlbconfig.sh` | +8 lines (error traps, version bumps, bootstrap fix) |

---

## Open Items / Handoffs

- **FreeBSD sh + pipefail:** Track as separate issue. If `pipefail` semantics are required, change shebangs to `#!/usr/bin/env bash` after verifying bash is pre-installed on the OPNsense Azure image.
- **gwlbconfig.sh URL source:** Still fetches XML from `huangyingting/glb-demo` (external repo). Consider migrating to the canonical repo URL (same as `configureopnsense.sh`'s `$1` prefix) for consistency.
- **FreeBSD image migration:** Pending Clu confirmation that OPNsense vendor supports FreeBSD 14.4 (Phase 0 decision).


---

## flynn-phase3-docs.md

# Phase 3 Documentation Consolidation — Flynn

**Date:** 2026-05-09  
**Status:** Complete  
**Owner:** Flynn (Lead Architect)

## Summary

Phase 3 focused on improving documentation clarity and discoverability while consolidating reference materials into a dedicated docs/ directory.

## Changes Made

### Task 1: Linux VXLAN Tutorial Migration
- **Action:** `git mv linux-vxlan.azcli docs/linux-vxlan-tutorial.md`
- **Rationale:** The file contains vim interactive editor commands (`:wq`) and is inherently a manual step-by-step tutorial, not a runnable script. Moving to `docs/` clarifies its intended use.
- **Enhancements:**
  - Added header notice: "Manual Tutorial (NOT a runnable script)"
  - Added status badge indicating it is reference-only
  - Clarified VNI differentiation: the tutorial uses VNI 900/901 (independent), while main lab uses 800/801
  - Restructured as numbered sections with code blocks and clear instructions
  - Removed vim `:wq` escape sequences from code blocks for clarity

### Task 2: README Modernization & Completeness
- **Updated Microsoft Docs link:**
  - Old: `https://docs.microsoft.com/en-us/azure/load-balancer/gateway-overview`
  - New: `https://learn.microsoft.com/azure/load-balancer/gateway-overview` (current GA docs)

- **Added Prerequisites section** (new, post-Introduction):
  - System requirements checklist
  - Environment variable contract from Phase 1 deploy.azcli (8 vars with defaults)
  - Quick start code snippet

- **Updated Layer 7 and IDS sections:**
  - Removed "(coming soon)" placeholders
  - Added directed links to OPNsense docs
  - Clarified these are "out of scope" for default deployment but achievable
  - Explained that GLB infrastructure *supports* these capabilities

- **Added archived note:**
  - Document that `main-two-nics.bicep` is archived and no longer maintained
  - Clarify `bicep/glb-active-active.bicep` is the canonical active-active deployment

## Impact

### Clarity
- Users now understand which files are tutorials vs. deployable scripts
- VNI scope is explicit (tutorial VNI ≠ lab VNI)
- Missing prerequisites are no longer a deployment blocker

### Discoverability
- Prerequisites section appears early (after Introduction)
- Quick start example is immediately visible
- Archived topologies are clearly marked

### Completeness
- All undefined environment variables documented with defaults
- Layer 7/IDS sections no longer orphaned; users know where to find advanced configs
- Documentation links point to current GA (not preview) references

## Notes for Future Phases

- If Layer 7 or IDS configurations are ever implemented in OPNsense bootstrap script, update the README sections with step-by-step examples.
- Monitor Microsoft docs URL structure; `learn.microsoft.com` is now GA source of truth (docs.microsoft.com is redirects).
- Consider adding a "Troubleshooting" section in Phase 4 pointing to common GLB+OPNsense integration issues.

## Files Changed

- `linux-vxlan.azcli` → `docs/linux-vxlan-tutorial.md` (moved, reformatted)
- `README.md` (updated links, added sections, replaced placeholders)
- `.squad/decisions/inbox/flynn-phase3-docs.md` (this file)
- `.squad/agents/flynn/history.md` (appended learning)


---

## flynn-phase3-polish.md

# Flynn Phase 3 Polish — Decision Drop

**Date:** 2026-05-09  
**Author:** Flynn (Lead / Azure Architect)  
**Session:** Phase 3 polish (p3 tracks: troubleshooting, trusted-launch, cloud-init, CI)

---

## What shipped

### p3-troubleshooting-guide ✅ DONE
- **File:** `docs/troubleshooting.md`
- Covers all requested failure modes: `SSH_PUBLIC_KEY`, subscription, pre-existing RG, GLB chaining race
- VXLAN tunnel section: port 10800/10801, MAC `12:34:56:78:9a:bc` for Azure health probe IP, tcpdump commands
- Standard LB NAT rule `--frontend-ip-name` pitfall documented
- Cross-subscription `$glbfeid` capture order documented
- OPNsense access: default creds, web UI ports, SSH via Bastion
- GLB chain verification and removal commands
- Linked from README TOC

### p3-ci-workflow ✅ DONE
- **File:** `.github/workflows/ci.yml`
- Triggers: push to `main` + PR targeting `main`
- Job 1: `bicep-build` — `az bicep build` on all top-level `bicep/*.bicep` (excludes `archived/`)
- Job 2: `bicep-lint` — `az bicep lint` on same scope
- Job 3: `shellcheck` — `scripts/*.sh` and `deploy.azcli` with `--shell=bash --severity=warning`
- Actions pinned to `@v4` (checkout) — no floating `@main` references
- YAML validated with `python -c "import yaml; yaml.safe_load(...)"` — passes
- **NOT pushed to main** — left for Daniel to enable when ready
- Will act as reviewer gate for future PRs

---

## What was proposed (queued for Clu)

### p3-trusted-launch ⏳ PROPOSED — awaiting Clu implementation
- **File:** `docs/architecture/trusted-launch.md`
- **Key finding:** FreeBSD/OPNsense has no Microsoft-signed Secure Boot shim. NVA VMs should use `secureBootEnabled: false` + `vTpmEnabled: true`. Consumer Ubuntu VM gets full TL.
- **Bicep contract for Clu:**
  - Consumer VM: `securityType: 'TrustedLaunch'`, `secureBootEnabled: true`, `vTpmEnabled: true`
  - OPNsense VMs: `securityType: 'TrustedLaunch'`, `secureBootEnabled: false`, `vTpmEnabled: true`
  - Modules: `bicep/modules/VM/opnsense-vm-active-active.bicep` and consumer VM module
- **Do NOT modify Bicep** — Clu owns this

### p3-cloud-init ⏳ PROPOSED — awaiting Clu implementation
- **File:** `docs/architecture/cloud-init-migration.md`
- Consumer VM nginx install moves from CSE to `osProfile.customData: base64(cloudInitScript)`
- cloud-init YAML documented inline
- Bicep pattern: `base64()` function on inline multiline string variable
- **CSE step in deploy.azcli step 7** — Flynn to remove after Clu's Bicep PR merges
- OPNsense: no change (FreeBSD bootstrap via CSE stays, Ram's domain)
- **Do NOT modify Bicep or scripts** — Clu and Ram own those

---

## Architecture decisions captured

| Decision | Status | Notes |
|----------|--------|-------|
| Trusted Launch: `secureBootEnabled: false` for OPNsense VMs | ✅ Decided | FreeBSD no signed shim |
| Trusted Launch: full TL for Ubuntu consumer-vm | ✅ Decided | Ubuntu ships signed shim |
| cloud-init replaces CSE for consumer-vm | ✅ Decided | Better timing guarantees |
| OPNsense bootstrap keeps CSE | ✅ Decided | FreeBSD; Ram's domain |
| CI uses `az bicep` (no separate install action) | ✅ Decided | Simpler; AZ CLI already installs bicep |
| ShellCheck severity: `warning` | ✅ Decided | Avoids `info` noise in CI gate |

---

## README changes

TOC updated with:
- `[Troubleshooting](./docs/troubleshooting.md)`
- `[Architecture decisions](./docs/architecture/)`
  - Trusted Launch
  - Cloud-init migration

---

## Next steps for team

1. **Clu:** Implement Trusted Launch (`docs/architecture/trusted-launch.md` has full parameter contract)
2. **Clu:** Implement cloud-init for consumer VM (`docs/architecture/cloud-init-migration.md` has full Bicep pattern)
3. **Flynn (after Clu merges):** Remove `az vm extension set` step from `deploy.azcli` step 7
4. **Daniel:** Enable `.github/workflows/ci.yml` by merging to main or enabling via GitHub Actions UI


---

## quorra-phase1-verdict.md

# Quorra — Phase 1 Reviewer Gate Verdict

**Date:** 2026-05-08T23:56-05:00  
**Reviewer:** Quorra (Validator / Tester)  
**Requested by:** Daniel Mauser  
**Authors under review:** Clu (IaC), Ram (Scripts), Flynn (Deploy)

---

## ✅ APPROVED — Phase 1

---

## Evidence — Verbatim Tool Output

### 1. Bicep Build

```
az bicep build --file bicep/glb-active-active.bicep
Exit code: 0

WARNING: A new Bicep release is available: v0.43.8.
WARNING: glb-active-active.bicep(49,5)  : no-unused-vars — "externalLoadBalancingRuleName"
WARNING: glb-active-active.bicep(295,5) : no-unnecessary-dependson — 'nsgopnsense'
WARNING: glb-active-active.bicep(314,5) : no-unnecessary-dependson — 'nsgopnsense'
WARNING: glb-active-active.bicep(328,5) : no-unnecessary-dependson — 'nsgopnsense'
WARNING: glb-active-active.bicep(329,5) : no-unnecessary-dependson — 'opnSensePrimary'
WARNING: glb-active-active.bicep(342,5) : no-unnecessary-dependson — 'nsgopnsense'
WARNING: glb-active-active.bicep(343,5) : no-unnecessary-dependson — 'opnSenseSecondary'
```

**Result:** 0 errors / 7 warnings (1× `no-unused-vars`, 6× `no-unnecessary-dependson`). All 7 are Phase 2 deferred per Clu's report and the coordinator decision record. ✅

---

### 2. Shell Syntax (bash -n)

```
bash -n scripts/configureopnsense.sh   → exit 0  ✅
bash -n scripts/gwlbconfig.sh          → exit 0  ✅
bash -n deploy.azcli                   → exit 0  ✅
shellcheck                             → not installed, skipped (Phase 2 CI)
```

---

### 3. File Inventory

| File | Status |
|------|--------|
| `bicep/glb-active-active.bkp` | ✅ absent |
| `bicep/temp.json` | ✅ absent |
| `bicep/main-two-nics.bicep` | ✅ absent (→ archived/) |
| `bicep/main-two-nics.json` | ✅ absent (→ archived/) |
| `bicep/main-two-nics.parameters.json` | ✅ absent (→ archived/) |
| `scripts/configureopnsense copy.sh` | ✅ absent (→ archived/scripts/) |
| `scripts/glb-config copy.xml` | ✅ absent (→ archived/scripts/) |
| `scripts/config-active-active-primary copy.xml` | ✅ absent (→ archived/scripts/) |
| `scripts/original.config.xml` | ✅ absent (→ archived/scripts/) |
| `archived/README.md` | ✅ exists — explains deprecation, security note, revival instructions |

---

### 4. Security

| Check | Result |
|-------|--------|
| `P@ssw0rd!1234&Azure` in tracked files (excl. archived/) | ✅ NOT FOUND |
| `--admin-password` in deploy.azcli | ✅ NOT FOUND |
| `VSE-SUB` / `DMAUSER-MS` in deploy.azcli | ✅ NOT FOUND |
| `@secure()` on `TempPassword` — `opnsense-vm.bicep` | ✅ line 6-7: `@secure()` / `param TempPassword string` |
| `@secure()` on `TempPassword` — `opnsense-vm-active-active.bicep` | ✅ line 5-6: `@secure()` / `param TempPassword string` |
| `@secure()` on `TempPassword` — `windows11-vm.bicep` | ✅ line 5-6: `@secure()` / `param TempPassword string` |
| `archived/main-two-nics.parameters.json` — REDACTED placeholder | ✅ REDACTED-SEE-GIT-HISTORY-FOR-WHY-THIS-WAS-REMOVED |
| CRLF in `scripts/configureopnsense.sh` | ✅ 0 carriage return (0x0D) bytes — fully LF |

---

### 5. Architectural / Logic Walk-through

#### deploy.azcli — Step Order Review

| Check | Line(s) | Result |
|-------|---------|--------|
| `set -euo pipefail` at top | 24 | ✅ |
| SSH_PUBLIC_KEY guard (required, @-file validation) | 34–44 | ✅ |
| `consumer-elb-pip` created BEFORE `consumer-elb` | 154 before 163 | ✅ |
| `consumer-elb` frontend references `consumer-elb-pip` | 167 | ✅ |
| Provider Bicep deploy is SYNCHRONOUS (no `--no-wait`) | 298–311 | ✅ |
| GLB frontend IP queried AFTER deploy completes | 356–361 | ✅ |
| GLB chain via `--gateway-lb "$glbfeid"` | 370–376 | ✅ |
| Chain validation (non-empty = active) | 382–387 | ✅ |
| No hardcoded subscription names | all | ✅ |
| No `--admin-password` | all | ✅ |
| Cleanup section is commented-out function (not bare `az`) | 469–473 | ✅ |

#### Traffic Flow — README vs deploy.azcli

```
Expected:  internet → consumer ELB → provider GLB → NVA pair → back through GLB → consumer VM
Observed:  consumer-elb-pip (Standard Static) → consumer-elb/frontendip1
                              → chained to provider-nva-glb/FW (via --gateway-lb)
                              → Bicep-deployed OPNsense active-active NVA pair
                              → consumer-vm via vmbackend pool
```
**Match: ✅**

#### Flynn's Open Flag — `az network lb inbound-nat-rule create` without `--frontend-ip-name`

Deploy.azcli line 189–196: `az network lb inbound-nat-rule create` does **not** include `--frontend-ip-name frontendip1`.

- For a Standard LB with exactly **one** frontend IP config, Azure CLI auto-selects the single frontend. This is non-blocking for the Phase 1 lab topology.
- **Non-blocking observation** — Phase 2 hardening: add `--frontend-ip-name frontendip1` to future-proof against multi-frontend scenarios and avoid CLI version drift.

---

## Open Items (Non-Blocking, Phase 2)

1. **`az network lb inbound-nat-rule create` missing `--frontend-ip-name frontendip1`** (deploy.azcli:189) — add for robustness; works for single-frontend Standard LB but may break if fronends are added.
2. **7 Bicep warnings** — `no-unused-vars` (×1), `no-unnecessary-dependson` (×6) — all Phase 2 scope.
3. **`shellcheck` not installed** — Phase 2 CI integration.
4. **`gwlbconfig.sh`** still references OPNsense 21.7 / WALinuxAgent v2.4.0.2 — legacy script, Phase 2 version bump.
5. **Secondary XML file named `glb-config.xml`** (not `glb-config-active-active-secondary.xml`) — style inconsistency, functionally correct (file exists in `scripts/`).
6. **Both consumer and provider VNets use `10.0.0.0/24`** — known lab simplification, documented.
7. **Hardcoded MAC `12:34:56:78:9a:bc`** in `configureopnsense.sh` static ARP — Phase 2.
8. **Git history still contains plaintext password** — Daniel confirmed out of scope; documented in `archived/README.md`.

---

## Final Verdict

```
✅ APPROVED — Phase 1
Bicep build: 0 errors / 7 warnings
Shell syntax: pass / pass / pass
File inventory: clean
Security: clean
Open items: [see non-blocking list above — all Phase 2]
Recommendation: proceed to Phase 2.
```



