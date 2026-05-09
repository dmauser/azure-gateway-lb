# SKILL: Bicep cloud-init via loadTextContent + base64

**Version:** 1.0  
**Author:** Clu  
**Date:** 2026-05-09  
**Tags:** bicep, cloud-init, customData, linux, ubuntu, osProfile

---

## What this skill does

Embeds a cloud-init YAML file into a Bicep VM resource's `osProfile.customData` using `loadTextContent()` + `base64()` — replacing Custom Script Extensions (CSE) for Linux VM initialization.

---

## When to use

- You need to provision a Linux VM with first-boot configuration (packages, files, services)
- You want to replace a CSE `commandToExecute` with a composable, diff-friendly cloud-init YAML
- The YAML is long enough that embedding it as a raw Bicep string would hurt readability
- You want cloud-init's synchronous boot semantics (VM only reports ready after cloud-init completes)

---

## Pattern

### Directory layout
```
bicep/
  cloud-init/
    <vm-name>.yaml      ← cloud-init YAML (diff-friendly, lintable)
  modules/VM/
    <vm-name>.bicep     ← references the YAML via relative path
```

### Bicep code
```bicep
// loadTextContent resolves at compile time — file must exist at build time.
// Path is relative to the .bicep file.
var cloudInitData = base64(loadTextContent('../../cloud-init/<vm-name>.yaml'))

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: virtualMachineName
  location: resourceGroup().location
  properties: {
    osProfile: {
      computerName: virtualMachineName
      adminUsername: adminUsername
      customData: cloudInitData    // ← cloud-init YAML, base64-encoded
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    // ... rest of VM ...
  }
}
```

### Minimal cloud-init YAML (nginx example)
```yaml
#cloud-config
package_update: true
package_upgrade: false
packages:
  - nginx
write_files:
  - path: /var/www/html/index.html
    content: "My content\n"
    owner: www-data:www-data
    permissions: '0644'
runcmd:
  - systemctl enable nginx
  - systemctl start nginx
```

---

## Key decisions

| Decision | Rationale |
|----------|-----------|
| `loadTextContent` over inline Bicep string | Keeps YAML diff-friendly; avoids Bicep string escaping issues |
| `base64()` at compile time | Azure `customData` API requires base64-encoded string |
| Separate `cloud-init/` subdirectory | YAML can be linted/validated independently (e.g., `cloud-init devel schema --config-file`) |
| No CSE alongside cloud-init | Ubuntu supports one `customData` payload; CSE is redundant after migration |

---

## CSE removal checklist

When replacing a CSE with cloud-init:
1. ✅ Remove `Microsoft.Compute/virtualMachines/extensions` resource (or module reference)
2. ✅ Add `customData: base64(loadTextContent(...))` to `osProfile`
3. ✅ Check `deploy.azcli` / pipeline for `az vm extension set` calls referencing the same VM — flag for script owner to remove
4. ✅ Verify `az bicep build` exits 0 after change

---

## Caveats

- `loadTextContent` path is **relative to the `.bicep` file**, not the working directory at build time
- cloud-init only runs on **first boot** — existing VMs must be redeployed
- **FreeBSD / OPNsense** does not support cloud-init via Azure `customData`; keep CSE for those VMs
- Azure image must support cloud-init (`Ubuntu2204` / `22_04-lts-gen2` both do; check with `az vm image show ... --query features`)

---

## References

- [cloud-init on Azure — official docs](https://learn.microsoft.com/azure/virtual-machines/linux/using-cloud-init)
- [Bicep loadTextContent function](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-functions-files#loadtextcontent)
- [cloud-init module reference](https://cloudinit.readthedocs.io/en/latest/reference/modules.html)
