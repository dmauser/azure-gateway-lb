# Architecture: Cloud-Init for Consumer VM and OPNsense NVAs

**Status:** Implemented  
**Date:** 2026-05-09  
**Last Updated:** 2026-05-09T19:20:21-05:00  
**Author:** Flynn (Lead / Azure Architect)  
**Implementation:** Clu (consumer-vm Bicep, commits `86732d8`, `9c369e8`); Ram (OPNsense cloud-config, commit `29b7f6f`); Clu (OPNsense Bicep wiring, commit `6f79ee2`)

---

## Context

The consumer Linux VM currently installs nginx via Azure Custom Script Extension (CSE):

```bash
# From deploy.azcli, step 7:
az vm extension set \
    --resource-group "$consumer_rg" \
    --vm-name consumer-vm \
    --name CustomScript \
    --settings '{"commandToExecute": "apt-get -y update && apt-get -y install nginx && echo Test Website on consumer-vm > /var/www/html/index.html"}' \
    --publisher Microsoft.Azure.Extensions \
    --no-wait \
    --output none
```

CSE has several operational drawbacks:
- Runs **after** VM boot, adding latency before the VM is useful
- Failures are opaque — you must inspect extension logs rather than cloud-init's built-in `/var/log/cloud-init-output.log`
- `--no-wait` means the LB probe may flip healthy before nginx is installed
- Not composable — multiple CSE invocations on the same VM are not supported

**Cloud-init** is the industry-standard multi-cloud VM initialization tool, supported on Ubuntu 22.04 on Azure out of the box. It runs before the VM reports ready to Azure, ensuring the VM is fully provisioned when the health probe first fires.

---

## Scope (Final — both VM types)

| VM | Approach | Status |
|----|----------|--------|
| consumer-vm (Ubuntu 22.04) | **cloud-init** via `osProfile.customData` | ✅ Implemented (Clu, commits `86732d8`, `9c369e8`) |
| provider-nva-primary / -secondary (OPNsense / FreeBSD 14.4) | **cloud-init** via `osProfile.customData` + template placeholders | ✅ Implemented (Ram + Clu, commits `29b7f6f`, `6f79ee2`) |

The original proposal scoped only consumer-vm. Post-Round-3, the OPNsense bootstrap was also migrated
to cloud-init because no Azure VM extension works on FreeBSD 14.4 (see
[docs/troubleshooting-freebsd-on-azure.md](../troubleshooting-freebsd-on-azure.md)).

---

## Cloud-init equivalent

The following cloud-init YAML is the direct equivalent of the current CSE command:

```yaml
#cloud-config
package_update: true
package_upgrade: false
packages:
  - nginx
write_files:
  - path: /var/www/html/index.html
    content: "Test Website on consumer-vm\n"
    owner: www-data:www-data
    permissions: '0644'
runcmd:
  - systemctl enable nginx
  - systemctl start nginx
```

### Key differences from CSE

| Aspect | CSE (current) | cloud-init (proposed) |
|--------|---------------|-----------------------|
| Timing | After first boot, async | During first boot, synchronous |
| Logs | Azure extension logs | `/var/log/cloud-init-output.log` on the VM |
| Retry on failure | Manual re-run of extension | Re-provision only |
| Composability | Single extension per VM | Multiple `write_files`, `runcmd` blocks |
| Azure readiness | VM ready before nginx | VM ready only after cloud-init completes |

---

## Bicep changes Clu needs to make

The cloud-init YAML must be base64-encoded and passed as the `customData` field in `osProfile`.

### Step 1: Encode the cloud-init YAML in Bicep

Bicep's `base64()` function can encode an inline string:

```bicep
var cloudInitScript = '''
#cloud-config
package_update: true
packages:
  - nginx
write_files:
  - path: /var/www/html/index.html
    content: "Test Website on consumer-vm\n"
    owner: www-data:www-data
    permissions: '0644'
runcmd:
  - systemctl enable nginx
  - systemctl start nginx
'''
```

### Step 2: Pass `customData` in the VM `osProfile`

```bicep
resource consumerVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'consumer-vm'
  location: location
  properties: {
    osProfile: {
      computerName: 'consumer-vm'
      adminUsername: adminUsername
      // SSH key auth — no password
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
      customData: base64(cloudInitScript)   // ← cloud-init replaces CSE
    }
    // ... rest of VM properties ...
  }
}
```

### Step 3: Remove the CSE extension resource

The `vmext.bicep` module (or equivalent extension resource targeting consumer-vm) should be removed or conditioned out. Cloud-init makes it redundant.

```bicep
// DELETE or comment out:
// module consumerVmExt 'modules/VM/vmext.bicep' = { ... }
```

### Step 4: Update deploy.azcli (Flynn's coordination note)

The `az vm extension set` call in `deploy.azcli` step 7 (with the comment `# Move this to cloud-init in a future phase`) should be removed once Clu's Bicep changes are merged. The deploy script currently serves as the IaC entrypoint — after migration, `az vm create` (or the Bicep deployment) already embeds cloud-init, and the extension step becomes a no-op that can cause confusion.

---

## Verification after migration

After deploying with cloud-init, verify initialization completed:

```bash
# SSH into consumer-vm
ssh azureuser@<consumer-elb-pip> -p 50000

# Check cloud-init completion
cloud-init status
# Expected: status: done

# Check cloud-init output log
sudo cat /var/log/cloud-init-output.log | tail -20

# Verify nginx is running
systemctl status nginx
curl http://localhost
# Expected: Test Website on consumer-vm
```

---

## OPNsense path — cloud-init via customData (implemented)

OPNsense (FreeBSD 14.4) uses cloud-init via `osProfile.customData`. The bootstrap flow:

1. `bicep/cloud-init/opnsense-bootstrap.yaml` — a `#cloud-config` template with four placeholder
   tokens: `__URI__`, `__ROLE__`, `__LOCAL_CIDR__`, `__PEER_IP__`.
2. Bicep chains four `replace()` calls at compile-time to substitute placeholders, then `base64()`
   the result for `customData`.
3. At first boot, FreeBSD cloud-init executes `runcmd:` steps as root via `/bin/sh`:
   - `fetch` (FreeBSD base tool) downloads `configureopnsense.sh` from `__URI__`
   - The script runs with the 4-argument contract: `URI ROLE LOCAL_CIDR PEER_IP`
   - Exit code is captured; success/failure sentinels written to `/var/run/opnsense-bootstrap-done`
     or `/var/run/opnsense-bootstrap-failed`

### Templating contract

| Placeholder | Type | Example | Substituted by |
|-------------|------|---------|----------------|
| `__URI__` | string | `https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/` | Bicep `bootstrapUri` param (trailing slash required) |
| `__ROLE__` | string | `Primary` or `Secondary` | Literal in Bicep module call |
| `__LOCAL_CIDR__` | string | `10.0.0.36/24` | Derived from trusted subnet prefix via Bicep arithmetic |
| `__PEER_IP__` | string | `10.0.0.37` | The other NVA's private IP (bare IP, no mask) |

**Bicep substitution chain:**

```bicep
var cloudInitTemplate = loadTextContent('../../cloud-init/opnsense-bootstrap.yaml')
var resolvedCloudInit = replace(replace(replace(replace(
    cloudInitTemplate,
    '__URI__',        bootstrapUri),
    '__ROLE__',       role),
    '__LOCAL_CIDR__', localIP),
    '__PEER_IP__',    peerIP)

// In osProfile:
customData: base64(resolvedCloudInit)
```

### Exit-code-preserving runcmd pattern (Round 6 fix)

Before Round 6, the runcmd used `tee` which masked the exit code (tee always exits 0). The fix:

```sh
/tmp/configureopnsense.sh '__URI__' '__ROLE__' '__LOCAL_CIDR__' '__PEER_IP__' \
  > /var/log/opnsense-bootstrap.log 2>&1; rc=$?; \
cat /var/log/opnsense-bootstrap.log; \
[ $rc -eq 0 ] \
  && echo "bootstrap-ok-$(date -u +%Y%m%dT%H%M%SZ)" > /var/run/opnsense-bootstrap-done \
  || echo "bootstrap-failed-rc=$rc-$(date -u +%Y%m%dT%H%M%SZ)" > /var/run/opnsense-bootstrap-failed; \
exit $rc
```

This ensures: correct sentinel files, failure propagated to `cloud-init status`, and full script
output echoed to cloud-init's own log for post-deploy debugging.

---

## Follow-up action

> **Status:** ✅ Fully implemented. Consumer VM (Ubuntu): cloud-init YAML at `bicep/cloud-init/consumer-vm.yaml`, wired via `bicep/modules/VM/consumer-vm.bicep`. OPNsense NVAs (FreeBSD): cloud-init template at `bicep/cloud-init/opnsense-bootstrap.yaml`, wired via `bicep/modules/VM/opnsense-vm-active-active.bicep`.
>
> **CSE removed:** The `az vm extension set` call (step 7 in `deploy.azcli`) is gone. Cloud-init handles all first-boot configuration for both VM types.
>
> **`vmext.bicep`:** Retained as a module file for potential future non-FreeBSD use cases, but not referenced in any active deployment path.

---

## References

- [cloud-init on Azure — official docs](https://learn.microsoft.com/azure/virtual-machines/linux/using-cloud-init)
- [cloud-init module reference](https://cloudinit.readthedocs.io/en/latest/reference/modules.html)
- [Azure Custom Script Extension for Linux](https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-linux)
