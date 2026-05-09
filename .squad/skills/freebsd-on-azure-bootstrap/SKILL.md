# SKILL: FreeBSD-on-Azure Bootstrap (No Extension Support)

**Category:** Azure / VM Provisioning  
**Discovered:** 2026-05-09  
**Author:** Flynn (Lead / Azure Architect)  
**Validated by:** Quorra (round 3 — pending)

---

## Problem Class

You are deploying a FreeBSD VM on Azure and need to run a post-provisioning bootstrap script (e.g., configure OPNsense, install packages, set up VXLAN). The obvious path — `Microsoft.OSTCExtensions/CustomScriptForLinux` or `Microsoft.Azure.Extensions/CustomScript` — fails on FreeBSD.

---

## Root Cause Pattern

Azure VM extensions ship **platform-specific native binaries** for their handler process:

| Extension family | Handler runtime | FreeBSD-compatible? |
|-----------------|----------------|---------------------|
| `Microsoft.OSTCExtensions/CustomScriptForLinux` 1.x | Python 2 | ❌ FreeBSD 14.4 has Python 3 only; `0700` octal literal fails at parse time |
| `Microsoft.Azure.Extensions/CustomScript` 2.x | Go (compiled Linux ELF) | ❌ Linux ELF won't run on FreeBSD without Linuxulator |
| `Microsoft.CPlat.Core/RunCommandHandlerLinux` | Go (compiled Linux ELF) | ❌ Same reason |
| Any `thefreebsdfoundation/*` extension | — | ❌ No extensions published in Azure Marketplace |

**The hard rule:** No Azure VM extension supports FreeBSD. This is confirmed empirically by running `az vm extension image list --location <region> --publisher thefreebsdfoundation` (always empty) and by Microsoft's extension documentation which lists only Linux distributions.

---

## Verification Commands

```bash
# Check if any extension exists for FreeBSD — always returns empty
az vm extension image list --location westus3 --publisher thefreebsdfoundation -o table

# Confirm OSTCExtensions versions available (all Python 2)
az vm extension image list --location westus3 --publisher Microsoft.OSTCExtensions \
  --query "[?contains(name, 'CustomScript')].{name:name, version:version}" -o table
```

---

## Solution: WAAgent Action Run-Command

`az vm run-command invoke --command-id RunShellScript` uses WAAgent's **built-in** command execution path, NOT the extension framework. WALinuxAgent runs natively on FreeBSD 14.4 (thefreebsdfoundation provides it on the image) and handles RunShellScript without any extension installation.

### Pattern

```bash
az vm run-command invoke \
    --resource-group "$rg" \
    --name "$vm_name" \
    --command-id RunShellScript \
    --scripts \
        "fetch -o /tmp/bootstrap.sh https://example.com/bootstrap.sh" \
        "sh /tmp/bootstrap.sh arg1 arg2" \
    --output none
```

**Notes:**
- FreeBSD uses `fetch` (built-in) for HTTP downloads, not `curl`/`wget`
- `--command-id RunShellScript` is the same ID as on Linux; WAAgent on FreeBSD recognizes it
- The command is synchronous — waits for the script to complete before returning
- If the script triggers a reboot (e.g., `shutdown -r +1`), schedule the reboot asynchronously so the script exits first, then poll for VM restart in your orchestration script

### Handling Reboots

If your bootstrap script needs to reboot the VM:

```bash
# In the bootstrap script: use async reboot (schedules in N minutes, returns immediately)
sed -i "" "s/reboot/shutdown -r +1/g" installer.sh
sh installer.sh  # runs installer, schedules reboot, then script returns

# Back in your orchestration script: poll for VM restart
sleep 90  # initial grace period
for i in $(seq 1 20); do
    state=$(az vm get-instance-view --rg "$rg" --name "$vm_name" \
        --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus" -o tsv)
    [[ "$state" == "VM running" ]] && break
    sleep 30
done
```

---

## Alternative: customData with bsdcloudinit

If `az vm run-command invoke` fails (e.g., WAAgent version on image is too old for RunShellScript):

1. The `thefreebsdfoundation/freebsd-14_4` image includes `bsdcloudinit`
2. Pass a `#cloud-config` YAML as `customData` in the VM ARM/Bicep spec
3. bsdcloudinit processes it on first boot via `runcmd:` directives

```bicep
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  properties: {
    osProfile: {
      customData: base64('''
#cloud-config
runcmd:
  - ["sh", "-c", "fetch -o /tmp/bootstrap.sh https://example.com/bootstrap.sh && sh /tmp/bootstrap.sh"]
''')
    }
  }
}
```

**Caveat:** bsdcloudinit support is not documented by Microsoft; verify it's on your specific image version before depending on it.

---

## What Does NOT Work

- `Microsoft.OSTCExtensions/CustomScriptForLinux` — ANY version — on FreeBSD 14.4
- `Microsoft.Azure.Extensions/CustomScript` — ANY version — on FreeBSD 14.4
- Assuming bumping `autoUpgradeMinorVersion: true` will find a working version — it won't
- `RunCommandHandlerLinux` extension — same Linux ELF issue

---

## Applied In

- `bicep/glb-active-active.bicep` — vmext module calls removed (Round 3 fix)
- `deploy.azcli` — `az vm run-command invoke` bootstrap step added (Round 3 fix)
