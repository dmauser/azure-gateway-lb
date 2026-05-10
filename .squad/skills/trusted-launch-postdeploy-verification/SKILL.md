# SKILL: Trusted Launch Post-Deploy Verification

**Author:** Quorra  
**Created:** 2026-05-09T13:23:58-05:00  
**Applicable to:** Any Azure VM deployment that enables Trusted Launch (TrustedLaunch securityProfile)

---

## When to Apply

Use this skill whenever validating that Trusted Launch is correctly applied to a deployed Azure VM — whether Ubuntu (full TL: Secure Boot + vTPM) or FreeBSD/OPNsense (vTPM only).

---

## Pattern: Full TL Verification (Ubuntu / Linux with signed shim)

```bash
# Verify securityProfile is populated
az vm show \
  --resource-group <rg> \
  --name <vm-name> \
  --query 'securityProfile' \
  -o json

# PASS result:
# {
#   "securityType": "TrustedLaunch",
#   "uefiSettings": {
#     "secureBootEnabled": true,
#     "vTpmEnabled": true
#   }
# }
```

**FAIL conditions:**
- `null` — securityProfile not applied (likely image mismatch or Gen 1 VM)
- `secureBootEnabled: false` on a Linux VM — not full TL
- `securityType` absent — API version too old (`2024-03-01` required minimum)

---

## Pattern: vTPM-Only Verification (FreeBSD / OPNsense)

```bash
az vm show \
  --resource-group <provider-rg> \
  --name <opnsense-vm-name> \
  --query 'securityProfile' \
  -o json

# PASS result:
# {
#   "securityType": "TrustedLaunch",
#   "uefiSettings": {
#     "secureBootEnabled": false,    ← intentional: no signed FreeBSD shim
#     "vTpmEnabled": true
#   }
# }
```

**Critical:** `securityType: 'TrustedLaunch'` is required EVEN when only enabling vTPM. You cannot set `vTpmEnabled: true` without `securityType: 'TrustedLaunch'`.

---

## Pattern: Cloud-Init Log Inspection (Ubuntu)

```bash
# SSH into VM first
ssh <admin>@<pip> -p <port>

# Quick status check
cloud-init status
# PASS: status: done

# Detailed log — last 50 lines
sudo cat /var/log/cloud-init-output.log | tail -50
# PASS: Look for package install lines and "cloud-init: finished"

# Parse for failures
sudo grep -i "error\|failed\|traceback" /var/log/cloud-init.log
# PASS: Empty output (no errors)
```

---

## Pattern: Bicep What-If Expected Diff for TL Addition

When adding TL to an existing VM, `az deployment group what-if` should show:

```
~ Microsoft.Compute/virtualMachines/<name>
  + properties.securityProfile:
      securityType:          "TrustedLaunch"
      uefiSettings:
        secureBootEnabled:   true|false    (depends on OS)
        vTpmEnabled:         true
```

No other VM properties should change. If `storageProfile.imageReference` or `osProfile` appears in the diff, Clu introduced an unintended change.

---

## Caveats

1. **TL is creation-time only.** You cannot add Trusted Launch to an existing VM. A full VM redeploy is required.
2. **Gen 2 required.** Verify image SKU contains `-gen2` or use `az vm image show --query hyperVGeneration` to confirm `V2` before deploying.
3. **FreeBSD: Secure Boot = boot failure.** Never set `secureBootEnabled: true` on a FreeBSD-based VM — no signed shim is available in the Azure marketplace images.
4. **Bicep API version:** Use `Microsoft.Compute/virtualMachines@2024-03-01` or later for the `securityProfile` block to be recognized.
