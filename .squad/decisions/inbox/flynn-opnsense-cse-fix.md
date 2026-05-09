# Flynn Decision Drop — OPNsense CSE Python 3 Fix

**Author:** Flynn (Lead / Azure Architect)  
**Date:** 2026-05-09T13:42:28-05:00  
**Round:** 3 (addressing Quorra round 2 blocker)  
**Files changed:** `bicep/glb-active-active.bicep`, `deploy.azcli`, `bicep/glb-active-active.json` (auto-regen)

---

## Problem Statement

`Microsoft.OSTCExtensions.CustomScriptForLinux` v1.4.1.0 crashes at handler `--install` on FreeBSD 14.4 with:

```
SyntaxError: leading zeros in decimal integer literals are not permitted
  File "customscript.py", line 62: os.chmod('/var/log/azure/', 0700)
```

The extension handler is Python 2. FreeBSD 14.4 (`thefreebsdfoundation/freebsd-14_4`) ships Python 3 only. The crash happens before `configureopnsense.sh` ever runs.

---

## Investigation Results

### Extension Inventory — westus3

| Publisher | Type | Latest | FreeBSD 14.4 compatible? |
|-----------|------|--------|--------------------------|
| `Microsoft.OSTCExtensions` | `CustomScriptForLinux` | 1.5.4 | ❌ No — Python 2 handler; officially unsupported on FreeBSD |
| `Microsoft.Azure.Extensions` | `CustomScript` | 2.1.16 | ❌ No — Go binary compiled for Linux ELF only |
| `Microsoft.CPlat.Core` | `RunCommandHandlerLinux` | 1.3.28 | ❌ No — same Linux ELF issue |
| `Microsoft.CPlat.Core` | `RunCommandLinux` | 1.0.9 | ❌ No — same Linux ELF issue |
| `thefreebsdfoundation` | *(any)* | *(none)* | — No extensions published in Azure |

**Finding:** No Azure VM extension supports FreeBSD 14.4. This is a hard platform limitation confirmed by Azure Marketplace query and Microsoft documentation. Paths A, B, C all eliminated.

### Decision Matrix

| Path | Description | Verdict |
|------|-------------|---------|
| A | Bump `CustomScriptForLinux` to 1.5.x | ❌ Same Python 2 handler; FreeBSD unsupported |
| B | Switch to `Microsoft.Azure.Extensions/CustomScript` v2.x | ❌ Linux ELF binary; won't run on FreeBSD |
| C | Switch to `RunCommandLinux` extension | ❌ Linux ELF binary; same issue |
| **D-prime** | **Remove CSE from Bicep; bootstrap via `az vm run-command invoke`** | ✅ **CHOSEN** |
| D | customData + bsdcloudinit | Valid fallback if D-prime fails; requires verifying bsdcloudinit on image |
| E | Roll back to FreeBSD 12.0 | ❌ Rejected Phase 1 — EOL image |
| F | OPNsense Marketplace appliance | ❌ No OPNsense marketplace image exists in Azure as of today |

---

## Path D-prime — Selected Solution

`az vm run-command invoke --command-id RunShellScript` uses WAAgent's **built-in** command execution handler — NOT the extension framework. WALinuxAgent 2.x runs natively on FreeBSD 14.4 and handles RunShellScript without any extension installation.

### Why the timing works

`configureopnsense.sh` patches `opnsense-bootstrap.sh.in` to replace `reboot` with `shutdown -r +1`. The `shutdown -r +1` command is asynchronous (schedules reboot in 60 s, returns immediately). The script completes all remaining steps (waagent install, bash/frr packages, syshook setup) within the 60 s window and exits. `az vm run-command invoke` receives the success exit code before the reboot fires. deploy.azcli then polls for VM restart before proceeding to GLB chaining.

---

## What Shipped

### `bicep/glb-active-active.bicep`
- **Removed** `OpnScriptURI` and `ShellScriptName` parameters (exclusively consumed by vmext calls)
- **Removed** `opnSensePrimaryScript` module instantiation
- **Removed** `opnSenseScondaryScript` module instantiation
- **Added** outputs:
  - `output primaryTrustedIP string = opnSensePrimary.outputs.trustedNicIP`
  - `output secondaryTrustedIP string = opnSenseSecondary.outputs.trustedNicIP`
  - `output trustedSubnetPrefix string = trustedSubnet.properties.addressPrefix`
- `az bicep build` → exit code 0

### `deploy.azcli` (Provider section, step 3 — new)
After Bicep deployment:
1. Query `primaryTrustedIP`, `secondaryTrustedIP`, `trustedSubnetPrefix` from deployment outputs
2. Run both NVA bootstrap scripts in parallel (bash `&` + `wait`)
3. Poll for VM restart (90 s grace + up to 20 × 30 s per VM)
4. Continue to GLB chaining

`bash -n deploy.azcli` → exit code 0

### `vmext.bicep`
Untouched. Retained as a module for potential future non-FreeBSD use cases.

---

## Fallback Plan

If `az vm run-command invoke` fails on FreeBSD (e.g., WAAgent version on base image too old):

**Path D-proper** — `customData` with bsdcloudinit:
- The `thefreebsdfoundation/freebsd-14_4` image includes `bsdcloudinit`
- `customData` can carry a `#cloud-config` YAML with `runcmd:` directives
- Script parameters (URI, role, CIDR, peer IP) must be baked into the customData at deploy time — requires Bicep parameter changes and Ram's review
- Coordinator should route to Ram if D-prime fails in round 3

---

## Next Action

**Quorra:** Round 3 deploy. Watch for:
- `az vm run-command invoke` returning success on both `provider-nva-primary` and `provider-nva-secondary`
- VM restart polling completing successfully
- GLB chain established (gate 3f)
- VXLAN traffic flowing through OPNsense (gate 3g)

If run-command returns a non-zero exit or "extension not supported" error → file a new blocker and the coordinator will route to Path D-proper.
