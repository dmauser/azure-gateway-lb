# ADR: Trusted Launch for GLB Lab VMs

**Status:** Implemented (consumer-only); FreeBSD opted-out per Azure platform constraint — empirically confirmed  
**Date:** 2026-05-09  
**Last Updated:** 2026-05-09T19:20:21-05:00  
**Author:** Flynn (Lead / Azure Architect)  
**Assignee:** Clu (Bicep implementation — complete)

---

## Context

Azure Trusted Launch provides a hardened security baseline for Generation 2 VMs via two features:

- **Secure Boot** — prevents loading unsigned boot-time code (rootkits, bootkits)
- **vTPM** — a virtualized TPM 2.0 chip enabling attestation, BitLocker, and measured boot

The GLB lab currently deploys VMs without any security profile, meaning they run in Standard mode with no firmware-level integrity guarantees. For a networking security lab whose primary NVAs are OPNsense (a firewall/IDS product), enabling platform-level boot integrity is architecturally consistent with the lab's security narrative.

---

## Decision

**Propose** adding Trusted Launch to the consumer Linux VM and (if compatible) to the OPNsense NVAs. This is a Bicep-only change — no deploy.azcli modifications are required.

---

## What Trusted Launch gives the lab

1. **Attestation** — vTPM enables remote boot attestation via Microsoft Defender for Cloud, surfacing in the Azure portal's security posture blade.
2. **Secure Boot** — ensures the OPNsense/Ubuntu kernel and initrd are signed and unmodified.
3. **Security posture signal** — the lab demonstrates that NVA workloads can be hardened at the hypervisor level, not just at the OS firewall level.

---

## Supported VM SKUs

Trusted Launch requires Generation 2 VMs. The lab currently uses:

| VM | Size | Gen | TL Support |
|----|------|-----|------------|
| consumer-vm | Standard_B1s | Gen 2 capable | ✅ |
| provider-nva-primary / -secondary | Standard_B2s | Gen 2 capable | ✅ (OS-dependent) |

All B-series sizes support Gen 2 and Trusted Launch when using a compatible image. Source: [Azure Trusted Launch supported VM sizes](https://learn.microsoft.com/azure/virtual-machines/trusted-launch#virtual-machines-sizes).

---

## FreeBSD / OPNsense Compatibility — Empirical Finding

> ⛔ **EMPIRICALLY CONFIRMED BLOCKER (2026-05-09):** `securityType: 'TrustedLaunch'` is **fully unavailable** for the `thefreebsdfoundation/freebsd-14_4` image. Azure rejects the deployment with a hard error regardless of `secureBootEnabled` value.

### What was tried

Quorra ran a live deploy on `MSDN_Dmauser / westus3` (2026-05-09T18:51 UTC, correlation ID `07943e5e-7b53-44b4-b8b0-79e5c6362b65`) with this Bicep `securityProfile`:

```bicep
securityProfile: {
  securityType: 'TrustedLaunch'
  uefiSettings: {
    secureBootEnabled: false   // vTPM-only mode as specified in original ADR
    vTpmEnabled: true
  }
}
```

**Azure response:**
```
BadRequest: Use of TrustedLaunch setting is not supported for the provided image.
Please select Trusted Launch Supported Gen2 OS Image.
```

This error fires for both `provider-nva-primary` and `provider-nva-secondary` simultaneously.

### Root cause

Azure maintains an explicit allowlist of images that support `securityType: 'TrustedLaunch'`. The `thefreebsdfoundation/freebsd-14_4` image is **not on this list** — being a Gen2 image is necessary but not sufficient. The original ADR assumed that Gen2 + `secureBootEnabled: false` (vTPM-only) would be accepted; this assumption is empirically incorrect.

### What the original ADR got wrong

The Phase 3 ADR stated:
> "Enable `vTpmEnabled: true` but leave `secureBootEnabled: false` for OPNsense VMs. This provides attestation and measured boot without the Secure Boot signing requirement."

This was based on Azure documentation that describes vTPM-only as a supported TL mode. What was not verified: the image itself must be on Azure's TL allowlist regardless of which UEFI features are requested. FreeBSD 14.4 is not on that list.

### Current state (post-fix, 2026-05-09)

OPNsense NVAs have **no `securityProfile` block** — they deploy as Standard Gen2 VMs. This is the Azure-correct way to deploy a VM with a non-TL image. No `securityType`, no `uefiSettings`, nothing.

### How to verify current image support

```bash
# Confirm FreeBSD 14.4 TL status — look for absence of TrustedLaunchSupported in features:
az vm image show \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --sku 14_4-release-amd64-gen2-ufs \
    --version latest \
    --query "features[?name=='SecurityType'].value" \
    -o tsv
# If output is empty or does not include 'TrustedLaunch', the image is not on the TL allowlist.
# If output includes 'TrustedLaunch', the image was added to the allowlist (re-enable securityProfile if so).

# Live deployment test (the exact Quorra repro):
az deployment group create \
    --name provider-nva-deploy \
    --resource-group <your-rg> \
    --template-file bicep/glb-active-active.bicep \
    --parameters \
        virtualMachineSize=Standard_B2s \
        virtualMachineName=provider-nva \
        TempUsername=azureuser \
        TempPassword=<password> \
        existingVirtualNetworkName=provider-vnet \
        existingUntrustedSubnet=external \
        existingTrustedSubnet=internal \
        PublicIPAddressSku=Standard
# Expected with TL block present: BadRequest "Use of TrustedLaunch setting is not supported for the provided image."
# Expected with no securityProfile block: deployment succeeds.
```

### Future state

FreeBSD support for Azure TL may change if `thefreebsdfoundation` requests allowlist inclusion from Microsoft. To check: run the `az vm image show` query above and look for `SecurityType` = `TrustedLaunch` in the features list. If it appears, re-adding a `securityProfile` block with `secureBootEnabled: false, vTpmEnabled: true` would be safe (assuming FreeBSD's UEFI chain is intact for vTPM attestation).

---

## Parameter contract (current — post empirical fix)

### Consumer VM (Ubuntu — full TL) ✅ Working

```bicep
// In bicep/modules/VM/consumer-vm.bicep
resource consumerVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  // ... existing properties ...
  properties: {
    // ... existing properties ...
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}
```

### OPNsense NVA VMs (FreeBSD — NO securityProfile) ⛔ TL unavailable

```bicep
// In bicep/modules/VM/opnsense-vm-active-active.bicep (and opnsense-vm.bicep, opnsense-vm-sing-nic.bicep)
resource opnsenseVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  // ... existing properties ...
  properties: {
    // ... existing properties ...
    // NO securityProfile block — FreeBSD 14.4 is not on Azure's TL allowlist.
    // Adding securityType: 'TrustedLaunch' causes: BadRequest
    // "Use of TrustedLaunch setting is not supported for the provided image."
  }
}
```

---

## Implementation constraints

1. **Image TL allowlist is separate from Gen2 capability:** Gen2 is required for TL but not sufficient. The image publisher must have registered the image with Azure's TL allowlist. Always verify with `az vm image show ... --query "features[?name=='SecurityType'].value"` before adding a `securityProfile` block.
2. **Existing VMs cannot be upgraded:** Trusted Launch can only be enabled at VM creation time. Existing deployed VMs cannot be converted; the lab must redeploy.
3. **No deploy.azcli changes required for TL:** All changes are in Bicep modules.
4. **Marketplace terms must be accepted:** FreeBSD 14.4 requires explicit marketplace terms acceptance on each new subscription before first deploy. See `deploy.azcli` preflight step — `az vm image terms accept --publisher thefreebsdfoundation --offer freebsd-14_4 --plan 14_4-release-amd64-gen2-ufs`.

---

## Current Status (post-Round-6, 2026-05-09)

| VM | Trusted Launch | Secure Boot | vTPM | Evidence |
|----|----------------|-------------|------|----------|
| `consumer-vm` (Ubuntu 22.04 Gen2) | ✅ Enabled | ✅ true | ✅ true | Quorra Round 2–5: `az vm show ... --query securityProfile` → full TL |
| `provider-nva-primary` (FreeBSD 14.4) | ⛔ Omitted | n/a | n/a | Quorra Round 1: `BadRequest` with TL; Round 2+ confirmed `securityProfile: null` |
| `provider-nva-secondary` (FreeBSD 14.4) | ⛔ Omitted | n/a | n/a | Same as primary |

Commits implementing the current state:
- `d386f14` — Flynn: removed `securityProfile` from all three OPNsense VM modules
- `86732d8` — Clu: consumer-vm TL implementation (full Trusted Launch)
- `9c369e8` — Clu: Path B consumer-vm Bicep module wiring

---

## Follow-up action

> **Status:** ✅ Consumer VM (Ubuntu) TL implemented and verified by Quorra (Rounds 2–5). ⛔ OPNsense TL empirically impossible — `securityProfile` block omitted per Azure platform constraint. No further action required until image support changes.
>
> **Re-check periodically:** Run `az vm image show --publisher thefreebsdfoundation --offer freebsd-14_4 --sku 14_4-release-amd64-gen2-ufs --version latest --query "features[?name=='SecurityType'].value" -o tsv`. If `TrustedLaunch` appears in output, re-add `securityProfile` to OPNsense modules with `secureBootEnabled: false, vTpmEnabled: true`.

---

## References

- [Azure Trusted Launch overview](https://learn.microsoft.com/azure/virtual-machines/trusted-launch)
- [Trusted Launch supported VM sizes](https://learn.microsoft.com/azure/virtual-machines/trusted-launch#virtual-machines-sizes)
- [FreeBSD on Azure — thefreebsdfoundation images](https://learn.microsoft.com/azure/virtual-machines/freebsd-intro-on-azure)
- [Secure Boot and vTPM for Azure VMs](https://learn.microsoft.com/azure/virtual-machines/trusted-launch#secure-boot)
