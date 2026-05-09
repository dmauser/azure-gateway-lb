# SKILL: Bicep Trusted Launch securityProfile Patterns

**Version:** 1.0  
**Author:** Clu  
**Date:** 2026-05-09  
**Tags:** bicep, trusted-launch, secure-boot, vtpm, security, gen2, ubuntu, freebsd

---

## What this skill does

Provides the correct `securityProfile` Bicep blocks for Trusted Launch VMs, with patterns for both full Trusted Launch (Linux/Ubuntu) and vTPM-only mode (FreeBSD/OPNsense where Secure Boot cannot be enabled).

---

## When to use

- Adding Trusted Launch to an existing Azure VM Bicep module
- Determining whether to enable Secure Boot based on OS/image compatibility
- Migrating a VM from Standard security type to Trusted Launch

---

## Prerequisites

1. **VM must be Gen2.** Trusted Launch is not available on Gen1 VMs. Verify image SKU contains `gen2` or use explicit Gen2 SKU names.
2. **Cannot be applied to existing VMs.** Trusted Launch can only be set at VM creation time. Re-deploy required.
3. **Bicep API version:** `Microsoft.Compute/virtualMachines@2024-03-01` or later.

---

## Pattern A: Full Trusted Launch (Ubuntu / Linux with signed shim)

Use when: Ubuntu 22.04 LTS Gen2, Windows Server 2019+, or any OS with a Microsoft-signed UEFI shim.

```bicep
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: virtualMachineName
  location: resourceGroup().location
  properties: {
    // ... osProfile, hardwareProfile, storageProfile, networkProfile ...
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true   // OS shim is Microsoft-signed; safe to enable
        vTpmEnabled: true
      }
    }
  }
}
```

**Required image (Ubuntu example):**
```bicep
imageReference: {
  publisher: 'Canonical'
  offer: '0001-com-ubuntu-server-jammy'
  sku: '22_04-lts-gen2'          // Gen2 explicit — required for Trusted Launch
  version: 'latest'
}
```

---

## Pattern B: NO securityProfile (FreeBSD / OPNsense — TL unavailable)

> ⛔ **Empirically confirmed 2026-05-09:** `thefreebsdfoundation/freebsd-14_4` image DOES NOT support `securityType: 'TrustedLaunch'`. Azure returns `BadRequest: "Use of TrustedLaunch setting is not supported for the provided image."` regardless of `secureBootEnabled` value.

The correct pattern for OPNsense NVAs is **no `securityProfile` block at all**:

```bicep
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: virtualMachineName
  location: resourceGroup().location
  properties: {
    // ... osProfile, hardwareProfile, storageProfile, networkProfile ...
    // securityProfile intentionally omitted: FreeBSD 14.4 does NOT support
    // securityType 'TrustedLaunch' — image is not on Azure's TL allowlist.
    // Deploy as Standard Gen2 VM.
  }
}
```

**What NOT to do:**
```bicep
// ❌ WRONG — Azure rejects this for FreeBSD 14.4 even with secureBootEnabled: false
securityProfile: {
  securityType: 'TrustedLaunch'
  uefiSettings: {
    secureBootEnabled: false
    vTpmEnabled: true
  }
}
```

---

## Pattern C: Optional Trusted Launch (parameter-controlled)

Use when the template must support both TL-enabled and non-TL environments (e.g., different subscriptions, testing without Gen2).

```bicep
@description('Enable Trusted Launch security profile (requires Gen 2 VM image)')
param trustedLaunch bool = true

@description('Enable Secure Boot within Trusted Launch (disable for FreeBSD/OPNsense VMs)')
param secureBootEnabled bool = true

// ...

securityProfile: trustedLaunch ? {
  securityType: 'TrustedLaunch'
  uefiSettings: {
    secureBootEnabled: secureBootEnabled
    vTpmEnabled: true
  }
} : null
```

---

## OS Compatibility Matrix

| OS | TL Allowlisted | Secure Boot | vTPM | Notes |
|----|:--------------:|:-----------:|:----:|-------|
| Ubuntu 22.04 LTS Gen2 | ✅ | ✅ | ✅ | `shim-signed` enrolled in Microsoft UEFI CA |
| Ubuntu 20.04 LTS Gen2 | ✅ | ✅ | ✅ | Same as 22.04 |
| Windows Server 2019+ | ✅ | ✅ | ✅ | Microsoft-signed by default |
| FreeBSD 14.x (thefreebsdfoundation) | ⛔ | ❌ | ❌ | **Entire `securityType: TrustedLaunch` rejected** — image not on Azure TL allowlist. Confirmed 2026-05-09 westus3. |
| OPNsense (FreeBSD-based) | ⛔ | ❌ | ❌ | Same as FreeBSD — no securityProfile block at all |
| Custom/BYOS images | Verify | Check vendor | ✅ | Must verify TL allowlist AND shim signing |

> ⚠️ **Key lesson:** Gen2 capability is **necessary but not sufficient** for Trusted Launch. The image must also be on Azure's explicit TL allowlist. `az vm image show ... --query "features[?name=='SecurityType'].value"` is the ground truth — empty output = not TL-capable.

---

## Verification queries

```bash
# Check if image supports Trusted Launch
az vm image show \
  --publisher Canonical \
  --offer 0001-com-ubuntu-server-jammy \
  --sku 22_04-lts-gen2 \
  --version latest \
  --query "features[?name=='SecurityType'].value" \
  -o tsv

# Check hyperV generation of an image
az vm image show \
  --publisher thefreebsdfoundation \
  --offer freebsd-14_4 \
  --sku 14_4-release-amd64-gen2-ufs \
  --version latest \
  --query hyperVGeneration \
  -o tsv
# Expected: V2
```

---

## References

- [Azure Trusted Launch overview](https://learn.microsoft.com/azure/virtual-machines/trusted-launch)
- [Trusted Launch supported VM sizes](https://learn.microsoft.com/azure/virtual-machines/trusted-launch#virtual-machines-sizes)
- [FreeBSD on Azure](https://learn.microsoft.com/azure/virtual-machines/freebsd-intro-on-azure)
- [securityProfile ARM/Bicep reference](https://learn.microsoft.com/azure/templates/microsoft.compute/virtualmachines#securityprofile)
