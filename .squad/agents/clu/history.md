# Clu — History

## Project Context
- **Project:** azure-gateway-lb
- **User:** Daniel Mauser
- **Files owned:** `bicep/`, `ARM/`

## Learnings

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

## Phase 2 TODO: FreeBSD Image Migration

**Decision (Phase 0):** Migrate OPNsense images from MicrosoftOSTC FreeBSD 12.0 (EOL) to TheFreeBSDFoundation FreeBSD 14.4 (modern, maintained).

**Pending:** Verify OPNsense compatibility with FreeBSD 14.4 via vendor documentation. If compatible, update `bicep/modules/VM/opnsense-vm.bicep` and `opnsense-vm-active-active.bicep`:
- Change publisher: `MicrosoftOSTC` → `thefreebsdfoundation`
- Change offer: `FreeBSD` → `freebsd-14_4`
- Change sku: `12.0` → `14_4-release-amd64-gen2-ufs`
- Regenerate glb-active-active.json after changes
- Test deployment in dev environment before promotion to main
