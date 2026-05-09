# Decision Drop: Trusted Launch + Cloud-Init Implementation

**Author:** Clu (IaC Engineer)  
**Date:** 2026-05-09  
**Commits:**
- `86732d8` — `feat(iac): Trusted Launch + cloud-init for consumer and OPNsense VMs` (initial)
- `9c369e8` — `feat(iac): Path B — top-level consumer-vm.bicep + deploy.azcli rewire` (Path B)

---

## Implementation Path Decision

**Path B chosen** (preferred per Daniel Mauser / Quorra finding). Rationale: Phase 0 Q1 decision — "Bicep is canonical; deploy.azcli is an orchestrator, not a VM author." The consumer VM was the last resource created imperatively inside deploy.azcli; moving it to Bicep completes that principle.

Path A (--custom-data flag on az vm create) was rejected because:
1. It contradicts the Phase 0 canonical Bicep decision.
2. It leaves VM configuration scattered across deploy.azcli instead of being diff-trackable in Bicep/cloud-init YAML.

---

## What Shipped

### Track 1 — Trusted Launch

| VM | Module | secureBootEnabled | vTpmEnabled | Reason |
|----|--------|:-----------------:|:-----------:|--------|
| consumer-vm | `bicep/modules/VM/consumer-vm.bicep` (new) | `true` | `true` | Ubuntu 22.04 Gen2 ships `shim-signed` (Microsoft UEFI CA enrolled) |
| provider-nva-primary | `bicep/modules/VM/opnsense-vm-active-active.bicep` | `false` | `true` | FreeBSD: no signed UEFI shim; Secure Boot blocks boot |
| provider-nva-secondary | same module | `false` | `true` | same |
| opnsense-vm (standalone) | `bicep/modules/VM/opnsense-vm.bicep` | `false` | `true` | same |
| opnsense-vm-sing-nic | `bicep/modules/VM/opnsense-vm-sing-nic.bicep` | `false` | `true` | same |

**Image changes (consumer VM only):**
- Old (deploy.azcli): `Ubuntu2204` — CLI alias, resolves to Gen1 or Gen2 depending on region defaults
- New (consumer-vm.bicep): `Canonical / 0001-com-ubuntu-server-jammy / 22_04-lts-gen2` — explicit Gen2 required for Trusted Launch

**OPNsense image:** `thefreebsdfoundation/freebsd-14_4/14_4-release-amd64-gen2-ufs` — already Gen2 (Phase 2 pick); no change needed.

### Track 2 — Cloud-Init for Consumer VM (Path B)

| Artifact | Path | Description |
|----------|------|-------------|
| Cloud-init YAML | `bicep/cloud-init/consumer-vm.yaml` | Installs nginx, writes index.html, enables+starts the service |
| Consumer VM module | `bicep/modules/VM/consumer-vm.bicep` | Module — NIC + VM with `customData: base64(loadTextContent(...))` + full Trusted Launch |
| Consumer VM top-level | `bicep/consumer-vm.bicep` | **NEW** — standalone deployable template; looks up existing VNet/subnet; delegates to module |

**Pattern used (module):**
```bicep
var cloudInitData = base64(loadTextContent('../../cloud-init/consumer-vm.yaml'))
// ...
osProfile: {
  customData: cloudInitData
  // ...
}
```

**deploy.azcli changes (Path B):**
- **Step 5 replaced:** `az network nic create` + `az vm create` → `az deployment group create --template-file bicep/consumer-vm.bicep`
  - NIC (`consumer-vm-nic`) is now created inside the Bicep template
  - Step 6 (LB/NAT attachment) uses the same NIC name — no change needed
- **Step 7 removed:** `az vm extension set --name CustomScript` deleted; cloud-init handles nginx
- **Step renumbered:** Bastion is now step 7 (was 8)

**vmext.bicep:** Unchanged — OPNsense CSE remains. Quorra finding 4 confirmed; no Bicep CSE removal was needed for the consumer path (it was never in Bicep).

---

## Deferred / Needs Follow-up

### ~~deploy.azcli Step 7 — Flynn action required~~ — RESOLVED in Path B

Step 7 (`az vm extension set`) has been removed from deploy.azcli directly as part of the Path B rewire. No further Flynn action needed on the CSE removal.

### Consumer Bicep Integration — COMPLETE

`bicep/consumer-vm.bicep` (top-level) is now the canonical consumer VM deployment. deploy.azcli step 5 calls it. Consumer VNet/NSG/ELB/Bastion remain imperative in deploy.azcli — those are out of scope for this task. Future task: create `bicep/consumer.bicep` to wrap the full consumer side if full Bicep-ification is desired.

### What-If Validation

No live Azure subscription was available for `az deployment group what-if` during this session. Deferred to Quorra's smoke-test gate per `docs/validation/trusted-launch-cloudinit-checklist.md`.

---

## Build Gate Evidence

```
$ az bicep build --file bicep/consumer-vm.bicep
WARNING: A new Bicep release is available: v0.43.8. Upgrade now by running "az bicep upgrade".
Exit code: 0

$ az bicep build --file bicep/glb-active-active.bicep
WARNING: A new Bicep release is available: v0.43.8. Upgrade now by running "az bicep upgrade".
Exit code: 0
```
Zero errors on both templates. One WARNING is a pre-existing az CLI upgrade notice — not a Bicep compilation issue.

`bicep/glb-active-active.json` regenerated (commit 86732d8) — no OPNsense structure changes in Path B commit.
