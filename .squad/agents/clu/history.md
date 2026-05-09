# Clu — History

## Project Context
- **Project:** azure-gateway-lb
- **User:** Daniel Mauser
- **Files owned:** `bicep/`, `ARM/`

## Learnings

### Session 4: Trusted Launch + Cloud-Init (2026-05-09)

#### securityProfile object shapes applied

**OPNsense NVA VMs** (`opnsense-vm-active-active.bicep`, `opnsense-vm.bicep`, `opnsense-vm-sing-nic.bicep`):
```bicep
securityProfile: {
  securityType: 'TrustedLaunch'
  uefiSettings: {
    secureBootEnabled: false  // FreeBSD: no Microsoft-signed UEFI shim — boot fails with SB on
    vTpmEnabled: true         // vTPM for attestation only; Gen2 SKU required
  }
}
```

**Consumer VM** (`consumer-vm.bicep` — new module):
```bicep
securityProfile: {
  securityType: 'TrustedLaunch'
  uefiSettings: {
    secureBootEnabled: true   // Ubuntu 22.04 Gen2 ships shim-signed (Microsoft UEFI CA enrolled)
    vTpmEnabled: true
  }
}
```

#### Gen2 image verification
- OPNsense: `thefreebsdfoundation/freebsd-14_4/14_4-release-amd64-gen2-ufs` — already Gen2 (Phase 2 pick); confirmed by SKU name substring `gen2`
- Consumer: switched from `Ubuntu2204` (ambiguous, can be Gen1 or Gen2) to explicit `Canonical/0001-com-ubuntu-server-jammy/22_04-lts-gen2` — guarantees Gen2 for Trusted Launch compatibility

#### Cloud-init file location pattern
- YAML lives at `bicep/cloud-init/<vm-name>.yaml` (diff-friendly, lints separately)
- Module loads it at compile time: `var cloudInitData = base64(loadTextContent('../../cloud-init/consumer-vm.yaml'))`
- Path is relative to the `.bicep` file; `../../cloud-init/` resolves correctly from `bicep/modules/VM/`
- `loadTextContent` + `base64` is a single expression — no intermediate variable needed if only used once

#### Consumer VM discovery — corrected by Quorra mid-flight
- Consumer VM is NOT in any Bicep template; it was deployed entirely via `deploy.azcli` imperative CLI calls
- **Quorra finding (mid-flight):** Path B selected — top-level `bicep/consumer-vm.bicep` created as canonical consumer deployment
- `bicep/modules/VM/consumer-vm.bicep` is the reusable module (NIC + VM + cloud-init + full TL)
- `bicep/consumer-vm.bicep` is the top-level deployable template (looks up existing VNet/subnet via `existing`, delegates to module)

#### Commits shipped (Session 4, 2026-05-09)
- **86732d8:** Initial TL + cloud-init — both VM types, Bicep builds clean
- **9c369e8:** Path B finalization — consumer-vm.bicep module + top-level deployable + deploy.azcli step 5 rewire (az deployment group create) + step 7 removal (CSE deleted, cloud-init handles nginx) + nicName output added to VM module
- Both Bicep builds clean post-commit (exit 0, 0 errors)
- `deploy.azcli` step 5 rewired: `az network nic create` + `az vm create` → `az deployment group create --template-file bicep/consumer-vm.bicep`
- `deploy.azcli` step 7 (CSE nginx) removed — cloud-init handles it; NIC name `consumer-vm-nic` is deterministic so step 6 (LB attachment) needed no change
- **Pattern for top-level consumer deployment:** accept VNet/subnet names as params, use `existing` resource lookup in Bicep for subnet ID, expose nicName output for CLI orchestration

#### Build validation results
- `az bicep build --file bicep/consumer-vm.bicep` → exit 0, 0 errors (top-level; loadTextContent via module chain resolves correctly)
- `az bicep build --file bicep/glb-active-active.bicep` → exit 0, 0 errors, 0 linter warnings (one pre-existing upgrade-available warning from az CLI, not a Bicep error)
- `bicep/glb-active-active.json` regenerated in commit 86732d8

---

### Session 1: Full IaC Audit (2026-05-08)
**Scope:** Bicep modules, ARM templates, parameters, API versions, security, idempotency.

#### Critical Findings
1. **Compilation Error:** `main-two-nics.bicep` fails BCP037 — module params incorrectly passed to opnsense-vm instead of vmext
2. **Security:** Hardcoded password in `main-two-nics.parameters.json:15` (`P@ssw0rd!1234&Azure`)
3. **Deprecated APIs:** VM Extension 2015-06-15 (11 years old), network resources 2021, compute 2021 (need 2023-09-01+, 2024-03-01+)

#### Architecture Notes
- **GWLB + ELB + Active-Active OPNsense:** glb-active-active.bicep is primary (works), two-nics.bicep is broken alternative
- **VXLAN Tunneling:** Backend pool correctly configured (ports 10800/10801, IDs 800/801)
- **Consumer/Provider Pattern:** ELB → GWLB chaining; verify consumer LB rules use `gatewayLoadBalancer` property

#### Code Quality Issues
- Unnecessary dependsOn entries (6 instances) — Bicep auto-infers these
- Unused variable: `externalLoadBalancingRuleName` in glb-active-active.bicep:49
- Stale files: glb-active-active.bkp, temp.json, ARM/glb-active-active.json (should delete)
- Typos: "Manchine" → "Machine", "Nework" → "Network"
- OPNsense image (MicrosoftOSTC FreeBSD 12.0) may be EOL

#### Secure Practices Notes
- Parameters named with "Password" suffix must use @secure() decorator
- Never hardcode secrets in parameters.json — use Key Vault reference
- Removed passwords should NEVER be committed; rotate immediately

#### API Version Baseline (2025 standards)
- Network: Microsoft.Network/* ≥ 2023-09-01
- Compute: Microsoft.Compute/* ≥ 2024-03-01
- Extensions: Microsoft.Compute/extensions ≥ 2024-07-01
- Avoid anything pre-2021

#### Module Structure Pattern
- vnet/ modules: lb.bicep, nic.bicep (public/private variants), nsg.bicep, publicip.bicep
- VM/ modules: opnsense-vm.bicep (single NIC), opnsense-vm-active-active.bicep (dual NIC), vmext.bicep (extension handler)
- All need API version bump

#### Next Audit Priorities
1. Fix BCP037 in main-two-nics or deprecate it
2. Remove password + integrate Key Vault
3. Bulk update API versions across all modules
4. Verify OPNsense Marketplace image
5. Regenerate .json files after fixes
6. Delete stale files (bkp, temp.json, ARM/)

#### Deployment Readiness Verdict
**NOT READY.** Blockers: compilation error, hardcoded password, outdated APIs, deprecated extension version.

---

### Session 2: Phase 1 IaC Fixes (2026-05-08)
**Scope:** Cruft cleanup, security hardening, API version fix (egregious 2015 one), JSON rebuild.

#### Changes Made
1. **Deleted:** `bicep/glb-active-active.bkp`, `bicep/temp.json`
2. **Created:** `archived/` directory at repo root
3. **`git mv` (history preserved):** `bicep/main-two-nics.{bicep,json,parameters.json}` → `archived/`
4. **Created:** `archived/README.md` with deprecation notice and security note
5. **Password redacted** in `archived/main-two-nics.parameters.json` before move
6. **`@secure()` added** to `param TempPassword string` in all three VM modules
7. **API version bumped:** `vmext.bicep` 2015-06-15 → 2024-07-01
8. **JSON rebuilt** via `az bicep build` — now in sync with source

#### Validation Result
- `az bicep build` exits 0 — NO ERRORS
- 7 warnings remain, all Phase 2 scope (no-unused-vars, no-unnecessary-dependson)

#### Learnings
- **`git mv` preserves history** for archived files — always use `git mv`, never shell `mv`/`Move-Item`, when preserving Bicep/ARM file history
- **`az bicep build` is offline-safe** — does not require `az login`; runs purely local compilation
- **`Microsoft.Resources/deployments@2025-04-01` in compiled JSON is compiler-generated** — the Bicep compiler auto-injects the latest deployment API for module nesting. Not a hand-edit; safe to ignore.
- **Redact secrets before `git mv`** — ensures the redacted value is the one that lands in the new path; the plaintext remains only in the source path's history
- **Phase 1 warning target (≤5) was not met (7 warnings)** but all 7 are explicitly Phase 2 items — track this in Phase 2 kick-off

---

## Session 2: FreeBSD 12.0 Image Investigation (2026-05-08T23:41:22)
**Scope:** Verify OPNsense base image (MicrosoftOSTC FreeBSD 12.0) EOL status and alternatives.

### Query Results

**MicrosoftOSTC Publisher Status:**
- Offers available: `FreeBSD`, `freebsd-11-3`
- SKUs under FreeBSD: `11.1`, `12.0`
- FreeBSD 12.0 versions: **EMPTY** (no active versions returned)
- Recommendation: MicrosoftOSTC FreeBSD 12.0 appears INACTIVE/EOL

**TheFreeBSDFoundation Publisher (Alternative):**
- Latest stable: FreeBSD 14.4.0 (Gen2, UFS/ZFS, includes ARM64)
- Also available: 14.3.0, 14.1.0, 14.0.0, 13.x series, 12.x series
- Modern image infrastructure: Gen2, multiple filesystem options, architecture variants

**OPNsense Marketplace:**
- No direct OPNsense appliance found via `--offer opnsense` search
- Timeout suggests unavailability in current region/subscription

### Findings

1. **Is FreeBSD 12.0 still available from MicrosoftOSTC?** 
   - **NO (replaced by silence)** — SKU exists but returns no active versions when queried with --all
   - MicrosoftOSTC has shifted focus to FreeBSD 11.3 (freebsd-11-3 offer)

2. **Newest FreeBSD SKU from MicrosoftOSTC?**
   - `freebsd-11-3` (version 11.3.0) — 11+ years old

3. **Is there a Marketplace OPNsense appliance?**
   - **NO** — Not found in current marketplace search

4. **Recommendation:**
   - **RISK:** Deploying with non-responsive image may fail silently or with confusing errors
   - **OPTIONS:**
     a) Switch to TheFreeBSDFoundation publisher + custom OPNsense installation
     b) Audit if FreeBSD 12.0 can be deployed despite empty version list (may fall back to latest within SKU)
     c) Downgrade to MicrosoftOSTC FreeBSD 11.3 (if OPNsense supports it)
   - **Recommended:** Move to TheFreeBSDFoundation FreeBSD 14.4.0 (modern, maintained, Gen2 support)

---

## Session 3: Phase 2 Bicep Modernization (2026-05-09)
**Scope:** API version audit, hygiene cleanup, FreeBSD image migration, SSH key parameter, JSON rebuild.

### API Version Table Applied

| Resource Type | Old | New | Files |
|---|---|---|---|
| Microsoft.Network/* (LB, NIC, NSG, PIP, VNet, RouteTable, Subnet) | `2023-09-01` | `2023-09-01` | All vnet modules — **already current**, no change needed |
| Microsoft.Compute/virtualMachines | `2024-03-01` | `2024-03-01` | opnsense-vm-active-active, opnsense-vm, windows11-vm, opnsense-vm-sing-nic — **already current** |
| Microsoft.Compute/virtualMachines/extensions | `2024-07-01` | `2024-07-01` | vmext.bicep, opnsense-vm-sing-nic.bicep — **already current** (Phase 1) |
| Microsoft.Resources/resourceGroups | `2020-06-01` | `2022-09-01` | rg.bicep — **bumped** |

**Finding:** Phase 1 API version work was more complete than expected. Only `rg.bicep` required a bump.

### FreeBSD Image Migration
- **From:** `thefreebsdfoundation/freebsd-13_5/13_5-release` (active-active modules) and `MicrosoftOSTC/FreeBSD/12.0` (sing-nic)
- **To:** `thefreebsdfoundation/freebsd-14_4/14_4-release-amd64-gen2-ufs` (all OPNsense modules)
- **Verification method:** Live CLI query `az vm image list --publisher thefreebsdfoundation --offer freebsd-14_4 --all` — returned version `14.4.0` with 6 SKU variants
- **SKU chosen:** `14_4-release-amd64-gen2-ufs` — AMD64, Gen2, UFS filesystem; best fit for Standard_B2s which supports Gen2
- **Plan block updated:** publisher/product/name all updated in resource `plan:` blocks
- **Files changed:** `opnsense-vm-active-active.bicep`, `opnsense-vm.bicep`, `opnsense-vm-sing-nic.bicep`

### Hygiene Findings (glb-active-active.bicep)

| Item | Status | Action |
|---|---|---|
| Unused `externalLoadBalancingRuleName` variable | **Not found** — already absent from file | No action |
| Typos: "Manchine", "Nework" | **Not found** — grep returned no matches | No action |
| `dependsOn: [opnSenseSecondary]` in opnSensePrimary | **Removed** — no actual output dependency |
| `dependsOn: [opnSenseSecondary, opnSensePrimary]` in nsgwinvm | **Removed** — no output dependency |
| `dependsOn: [opnSenseSecondary, opnSensePrimary]` in winvmpublicip | **Removed** — no output dependency |
| `dependsOn: [opnSenseSecondary, opnSensePrimary, nsgwinvm, winvmpublicip]` in winvm | **Partially removed** — kept nsgwinvm/winvmpublicip (required: `existing` references can't be auto-inferred by Bicep) |

**Warning count:** Dropped from 7 (Phase 1 end) to 0 linter warnings. Build output confirms clean compile.

### SSH Key + Key Vault Parameter Contract
- **Added:** `param adminSshKey string = ''` to `opnsense-vm-active-active.bicep`, `opnsense-vm.bicep`, `opnsense-vm-sing-nic.bicep`, and `glb-active-active.bicep` (propagated through)
- **Pattern:** When `adminSshKey` is non-empty, `linuxConfiguration.ssh.publicKeys` is injected into `osProfile` via ternary; `disablePasswordAuthentication: false` keeps both auth methods available for initial deployment flexibility
- **Key Vault comment block:** Already present in both active modules from Phase 1; added to `opnsense-vm-sing-nic.bicep` in this session
- **Missing from opnsense-vm-sing-nic.bicep:** Also added `@secure()` decorator to TempPassword (was absent)

### AVM Candidates (flagged, NOT migrated)
- `modules/vnet/lb.bicep` → AVM module `avm/res/network/load-balancer` — good candidate
- `modules/vnet/nsg.bicep` → AVM module `avm/res/network/network-security-group` — good candidate
- `modules/vnet/vnet.bicep` → AVM module `avm/res/network/virtual-network` — good candidate
- **Decision:** Do not migrate wholesale in Phase 2 — flag for Phase 3 or dedicated AVM migration sprint

### Build Validation
- `az bicep build --file bicep/glb-active-active.bicep` → **exit code 0, 0 errors, 0 linter warnings**
- `bicep/glb-active-active.json` regenerated (timestamp 2026-05-09T13:17 local)


**Decision (Phase 0):** Migrate OPNsense images from MicrosoftOSTC FreeBSD 12.0 (EOL) to TheFreeBSDFoundation FreeBSD 14.4 (modern, maintained).

**Pending:** Verify OPNsense compatibility with FreeBSD 14.4 via vendor documentation. If compatible, update `bicep/modules/VM/opnsense-vm.bicep` and `opnsense-vm-active-active.bicep`:
- Change publisher: `MicrosoftOSTC` → `thefreebsdfoundation`
- Change offer: `FreeBSD` → `freebsd-14_4`
- Change sku: `12.0` → `14_4-release-amd64-gen2-ufs`
- Regenerate glb-active-active.json after changes
- Test deployment in dev environment before promotion to main

---

### Cross-Agent Context (2026-05-09 Session Resume)

**From Flynn:** Trusted Launch + cloud-init migration ADRs proposed and queued for your implementation:
- `docs/architecture/trusted-launch.md` — OPNsense VMs: `secureBootEnabled: false` + `vTpmEnabled: true` (no FreeBSD signed shim). Consumer VM: full Trusted Launch.
- `docs/architecture/cloud-init-migration.md` — Consumer VM nginx via cloud-init (CSE → `osProfile.customData`). Bicep parameter contract documented. OPNsense unchanged.
- Handoff: Implement both in parallel; Flynn will remove CSE from `deploy.azcli` after merge.

**From Ram:** Phase 2 scripts complete; awaiting your FreeBSD 14.4 Bicep confirmation to proceed with live image testing. Script versions now at 25.1/v2.12.0.4/python3.11.
