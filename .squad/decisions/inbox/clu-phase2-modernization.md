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
