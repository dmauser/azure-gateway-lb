# SKILL: Bicep API Version Audit + Marketplace Image SKU Lookup

**Version:** 1.0  
**Author:** Clu  
**Date:** 2026-05-09  
**Tags:** bicep, api-versions, azure-marketplace, freebsd, image-sku

---

## What this skill does

Provides a repeatable audit pattern for:
1. Finding all `Microsoft.*@YYYY-MM-DD` version strings in a Bicep codebase
2. Verifying current target versions for common resource types
3. Looking up live Azure Marketplace image SKUs (publisher/offer/sku/version)

---

## When to use

- Before a Bicep modernization sprint (confirm baseline)
- When adding a new VM image reference (verify publisher/offer/sku)
- When a deployment fails with `InvalidApiVersion` or `ImageNotFound` errors
- When a CI lint job reports `use-recent-api-versions` warnings

---

## Pattern 1: API Version Audit (ripgrep)

```powershell
# Find all API version strings across all .bicep files
grep -r "@[0-9]{4}-[0-9]{2}-[0-9]{2}" --glob "*.bicep" --include-line-numbers <bicep-dir>

# Or with ripgrep (rg):
rg "@\d{4}-\d{2}-\d{2}" --glob "*.bicep" <bicep-dir>
```

### Current targets (verified 2026-05-09)

| Resource namespace | Target API version | Notes |
|---|---|---|
| `Microsoft.Network/*` | `2023-09-01` | LB, NIC, NSG, PIP, VNet, RouteTable, Subnet |
| `Microsoft.Compute/virtualMachines` | `2024-03-01` | All VM types |
| `Microsoft.Compute/virtualMachines/extensions` | `2024-07-01` | CustomScript, DSC, etc. |
| `Microsoft.Resources/resourceGroups` | `2022-09-01` | subscription-scope deployments |
| `Microsoft.Resources/deployments` | compiler-injected | Do NOT hand-edit; Bicep auto-injects latest |

**Rule:** Never introduce a future-dated API version. Verify against `az provider operation list` or ARM docs.

---

## Pattern 2: Marketplace Image SKU Lookup

```powershell
# List all SKUs for a publisher/offer combination (live query)
az vm image list --publisher <publisher> --offer <offer> --all --query "[].{sku:sku,version:version}" -o table

# Example: FreeBSD 14.4 from The FreeBSD Foundation
az vm image list --publisher thefreebsdfoundation --offer freebsd-14_4 --all --query "[].{sku:sku,version:version}" -o table

# Example: List all offers from a publisher
az vm image list-offers --publisher thefreebsdfoundation --location eastus -o table

# Example: Verify a specific image is deployable
az vm image show --publisher thefreebsdfoundation --offer freebsd-14_4 --sku 14_4-release-amd64-gen2-ufs --version latest --location eastus
```

### FreeBSD SKU reference (thefreebsdfoundation, verified 2026-05-09)

| Offer | SKU | Version | Notes |
|---|---|---|---|
| `freebsd-14_4` | `14_4-release-amd64-gen2-ufs` | `14.4.0` | AMD64, Gen2, UFS — **recommended** |
| `freebsd-14_4` | `14_4-release-amd64-gen2-zfs` | `14.4.0` | AMD64, Gen2, ZFS |
| `freebsd-14_4` | `14_4-release-ufs` | `14.4.0` | AMD64, Gen1, UFS |
| `freebsd-14_4` | `14_4-release-zfs` | `14.4.0` | AMD64, Gen1, ZFS |
| `freebsd-14_4` | `14_4-release-arm64-gen2-ufs` | `14.4.0` | ARM64, Gen2, UFS |
| `freebsd-14_4` | `14_4-release-arm64-gen2-zfs` | `14.4.0` | ARM64, Gen2, ZFS |

**For OPNsense / NVA workloads:** Use `14_4-release-amd64-gen2-ufs` — Gen2 improves boot time and is required for VM sizes that mandate UEFI.

---

## Pattern 3: Bicep `plan:` block for Marketplace images

When using a Marketplace image with a `plan`, the Bicep `plan:` block must match `publisher`, `product` (= offer), and `name` (= sku):

```bicep
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: resourceGroup().location
  plan: {
    publisher: 'thefreebsdfoundation'
    product: 'freebsd-14_4'        // matches offer
    name: '14_4-release-amd64-gen2-ufs'  // matches sku
  }
  properties: {
    storageProfile: {
      imageReference: {
        publisher: 'thefreebsdfoundation'
        offer: 'freebsd-14_4'
        sku: '14_4-release-amd64-gen2-ufs'
        version: 'latest'
      }
    }
    // ...
  }
}
```

**Common mistake:** Mismatching `plan.name` with `imageReference.sku` — they must be identical.

---

## Pattern 4: SSH Key + Key Vault parameter contract

```bicep
// Secure parameter — caller can supply via Key Vault reference in parameters file:
// "TempPassword": { "reference": { "keyVault": { "id": "..." }, "secretName": "..." } }
@secure()
param TempPassword string

// SSH public key — optional; when provided, injected into authorized_keys
param adminSshKey string = ''

// In osProfile:
osProfile: {
  adminUsername: adminUsername
  adminPassword: TempPassword
  linuxConfiguration: empty(adminSshKey) ? null : {
    disablePasswordAuthentication: false
    ssh: {
      publicKeys: [
        {
          path: '/home/${adminUsername}/.ssh/authorized_keys'
          keyData: adminSshKey
        }
      ]
    }
  }
}
```

---

## References

- [ARM API versions reference](https://learn.microsoft.com/en-us/azure/templates/)
- [az vm image list CLI reference](https://learn.microsoft.com/cli/azure/vm/image)
- [Azure Marketplace plan requirements](https://learn.microsoft.com/azure/virtual-machines/linux/cli-ps-findimage)
- [Bicep nullable types](https://learn.microsoft.com/azure/azure-resource-manager/bicep/data-types#nullable-types)
