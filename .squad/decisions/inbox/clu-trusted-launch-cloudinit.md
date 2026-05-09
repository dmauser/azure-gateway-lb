# Decision Drop: Trusted Launch + Cloud-Init Implementation

**Author:** Clu (IaC Engineer)  
**Date:** 2026-05-09  
**Commit:** 86732d8 — `feat(iac): Trusted Launch + cloud-init for consumer and OPNsense VMs`

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

### Track 2 — Cloud-Init for Consumer VM

| Artifact | Path | Description |
|----------|------|-------------|
| Cloud-init YAML | `bicep/cloud-init/consumer-vm.yaml` | Installs nginx, writes index.html, enables+starts the service |
| Consumer VM module | `bicep/modules/VM/consumer-vm.bicep` | New module with `customData: base64(loadTextContent(...))` |

**Pattern used:**
```bicep
var cloudInitData = base64(loadTextContent('../../cloud-init/consumer-vm.yaml'))
// ...
osProfile: {
  customData: cloudInitData
  // ...
}
```

The consumer VM CSE (`az vm extension set --name CustomScript` in deploy.azcli step 7) is NOT a Bicep resource. The new `consumer-vm.bicep` module simply omits CSE entirely — cloud-init is the only provisioning mechanism. OPNsense CSE left unchanged per charter boundary.

---

## Deferred / Needs Follow-up

### deploy.azcli Step 7 — Flynn action required

`deploy.azcli` line 233–241 contains:
```bash
# 7) Install nginx and test website (Move this to cloud-init in a future phase)
az vm extension set \
    --resource-group "$consumer_rg" \
    --vm-name consumer-vm \
    --name CustomScript \
    --settings '{"commandToExecute": "apt-get -y update && apt-get -y install nginx && echo Test Website on consumer-vm > /var/www/html/index.html"}' \
    --publisher Microsoft.Azure.Extensions \
    --no-wait \
    --output none
```

**Action needed (Flynn):** Once `consumer-vm.bicep` is integrated into the consumer-side deployment (replacing the imperative `az vm create` calls), this step becomes a no-op and should be removed. If deploy.azcli continues to be used for consumer VM creation, it should switch to pass `--custom-data bicep/cloud-init/consumer-vm.yaml` and remove the extension step.

Clu does not own deploy.azcli per charter boundaries.

### Consumer Bicep Integration

The new `consumer-vm.bicep` module is NOT yet referenced by any top-level Bicep template. Currently the consumer side is purely imperative (deploy.azcli). A future task should create `bicep/consumer.bicep` as a top-level consumer-side template that uses this module, completing the Bicep-ification of the consumer deployment.

### What-If Validation

`az` was authenticated during this session but no test resource group was available for a live `az deployment group what-if` run. Deferred to Quorra (testing agent) per task instructions.

---

## Build Gate Evidence

```
$ az bicep build --file bicep/glb-active-active.bicep
WARNING: A new Bicep release is available: v0.43.8. Upgrade now by running "az bicep upgrade".
Exit code: 0
```
Zero errors. One WARNING is a pre-existing az CLI upgrade notice — not a Bicep compilation issue.

```
$ az bicep build --file bicep/modules/VM/consumer-vm.bicep
WARNING: A new Bicep release is available: v0.43.8. Upgrade now by running "az bicep upgrade".
Exit code: 0
```
`loadTextContent` resolved correctly; base64 encoding confirmed at compile time.

`bicep/glb-active-active.json` regenerated and committed in the same commit (86732d8).
