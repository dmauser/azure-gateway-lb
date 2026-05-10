# SKILL: tl-cloudinit-static-gate

**Author:** Quorra (Validator / Tester)  
**Extracted from:** commit `9c369e8` review — Trusted Launch + cloud-init migration (2026-05-09T13:23:58-05:00)  
**Applies to:** Any PR that adds Trusted Launch security profiles or cloud-init `customData` to Azure Bicep VM modules.

---

## When to Apply

Use this pattern whenever a PR touches:
- `securityProfile` / `uefiSettings` on any `Microsoft.Compute/virtualMachines` resource
- `osProfile.customData` (cloud-init injection)
- Removal of a `CustomScript` extension that is being replaced by cloud-init
- A new top-level Bicep template that wraps an existing VM module

---

## Static Gate Sequence (no live deploy required)

### Step 1 — Bicep Build

```bash
az bicep build --file <changed-template>.bicep 2>&1
az bicep build --file bicep/glb-active-active.bicep 2>&1  # always run the root template too
```

**PASS:** Exit 0, 0 errors.  
**Acceptable:** Tool-advisory WARNING about new Bicep version.  
**FAIL (immediate REJECT):** Any line containing `Error` or `BCP` error code.

Record error count and warning count. Compare to pre-PR baseline. Any new error = REJECT.

---

### Step 2 — Trusted Launch Shape Checklist

For every VM resource changed, apply the correct shape:

#### Full Trusted Launch (Linux/Windows with MS-signed UEFI shim)

```bicep
securityProfile: {
  securityType: 'TrustedLaunch'   // REQUIRED — vTPM will not activate without it
  uefiSettings: {
    secureBootEnabled: true        // REQUIRED for OS with MS CA enrollment
    vTpmEnabled: true              // REQUIRED
  }
}
```

**SKU check:** Image SKU must contain `gen2` (or equivalent Gen2 marker). Trusted Launch is Gen2-only.

#### vTPM-Only Trusted Launch (FreeBSD / OPNsense — no MS-signed shim)

```bicep
securityProfile: {
  securityType: 'TrustedLaunch'   // REQUIRED even for vTPM-only
  uefiSettings: {
    secureBootEnabled: false       // REQUIRED for FreeBSD — no MS UEFI CA shim
    vTpmEnabled: true              // REQUIRED
  }
}
```

**HARD RULE:** If `secureBootEnabled: true` on a FreeBSD VM → **REJECT immediately**. The VM will not boot.

---

### Step 3 — Cloud-Init Wiring

Check all three components:

1. **YAML file exists at the referenced path:**
   ```
   loadTextContent('<relative-path>/consumer-vm.yaml')
   ```
   Resolve relative to the Bicep module file. Verify with `Test-Path`.

2. **Base64 encoding applied:**
   ```bicep
   var cloudInitData = base64(loadTextContent('...'))
   ```
   The raw YAML must be base64-encoded — Azure injects it as `customData` in base64 format.

3. **Injected into `osProfile`:**
   ```bicep
   osProfile: {
     customData: cloudInitData
   }
   ```
   Not in `storageProfile`, not in an extension — must be `osProfile.customData`.

4. **YAML syntax check (manual):**
   - First line must be `#cloud-config`
   - `packages:` list installs expected software
   - `runcmd:` enables and starts the service
   - `write_files:` produces the expected content at the expected path

---

### Step 4 — CSE Removal Verification

If cloud-init replaces a Custom Script Extension:

**Consumer-side CSE (deploy.azcli):**
```bash
grep -n "vm extension set\|CustomScript\|az vm extension" deploy.azcli
```
**PASS:** No matches (CSE removed).  
**FAIL:** Any match = CSE still present = REJECT (duplicate install, not just redundant — can cause race conditions).

**OPNsense CSE (Bicep):**
```bash
grep -n "vmext" bicep/glb-active-active.bicep
```
**PASS:** Lines reference `modules/VM/vmext.bicep` for primary and secondary NVAs.  
**FAIL:** Lines missing = OPNsense CSE accidentally removed = REJECT (FreeBSD won't configure itself).

---

### Step 5 — Orchestration Integrity

For any deploy.azcli changes, verify:

| Check | Command | PASS |
|-------|---------|------|
| Step numbering has no gaps | `grep -n "^# [0-9])" deploy.azcli` | Sequential: 1, 2, 3 … |
| Bicep template path is absolute | Look for `${SCRIPT_DIR}/bicep/…` | Present |
| No `--no-wait` before downstream query on same resource | `grep -n "no-wait" deploy.azcli` | Absent (or only in commented cleanup) |
| NIC name used in LB attachment matches Bicep default | Compare `--nic-name` in step 6 vs `var nicName` in module | Match |

---

### Step 6 — Phase Regression Check

After any TL/cloud-init PR, verify these did not regress:

```bash
grep -n "securityType\|secureBootEnabled\|vTpmEnabled" bicep/modules/VM/opnsense-vm-active-active.bicep
```
Expect: `securityType: 'TrustedLaunch'`, `secureBootEnabled: false`, `vTpmEnabled: true`.

```bash
grep -n "thefreebsdfoundation\|freebsd-14_4\|14_4-release-amd64-gen2" bicep/modules/VM/opnsense-vm-active-active.bicep
```
Expect: All three present (publisher, offer, SKU unchanged).

---

## What-If Deferral Rule

What-if requires existing infrastructure (resource group + VNet). If the VNet referenced via `existing` resource is not yet provisioned, **defer what-if to live deploy** and document it explicitly in the verdict. Do not block APPROVE solely on skipped what-if when all other static gates pass.

---

## REJECT Triggers (Immediate)

Any one of these = ❌ REJECT, no further review:

| Trigger | File |
|---------|------|
| `az bicep build` exit ≠ 0 | Any changed .bicep |
| `secureBootEnabled: true` on FreeBSD/OPNsense VM | opnsense-vm-active-active.bicep |
| `securityType` missing but `vTpmEnabled: true` | Any .bicep — vTPM won't activate |
| `customData` absent from `osProfile` when cloud-init YAML is referenced | consumer-vm.bicep |
| `loadTextContent` path resolves to non-existent file | Build will error — caught in Gate 1 |
| OPNsense CSE (vmext.bicep) removed from glb-active-active.bicep | FreeBSD won't configure |
