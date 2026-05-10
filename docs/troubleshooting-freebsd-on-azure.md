# FreeBSD on Azure — Constraints and Gotchas

**Last Updated:** 2026-05-09T19:20:21-05:00  
**Author:** Flynn (Lead / Azure Architect)  
**Source:** Empirical evidence from lab deploy rounds 1–6 on `MSDN_Dmauser / westus3`.

This is the single-source reference for every FreeBSD-on-Azure constraint discovered while deploying
OPNsense NVAs behind Azure Gateway Load Balancer. All findings below are empirically confirmed — not
derived from documentation alone.

---

## 1. No Trusted Launch Support

**Symptom:**

```
BadRequest: Use of TrustedLaunch setting is not supported for the provided image.
Please select Trusted Launch Supported Gen2 OS Image.
```

**When it fires:** When any Bicep resource has `securityProfile.securityType: 'TrustedLaunch'` for a
FreeBSD VM — regardless of whether `secureBootEnabled` is `true` or `false`.

**Root cause:** Azure maintains an explicit allowlist of images that support `securityType: 'TrustedLaunch'`.
The `thefreebsdfoundation/freebsd-14_4` image is **not on this list**. Being a Gen2 image is necessary
but not sufficient for Trusted Launch. There is no vTPM-only workaround — any `securityType: 'TrustedLaunch'`
combination is rejected at the API level.

**Verified:** Quorra live deploy on `westus3`, 2026-05-09T18:51 UTC.  
**Correlation ID:** `07943e5e-7b53-44b4-b8b0-79e5c6362b65`

**Fix:** Omit the `securityProfile` block entirely from the VM resource. Do NOT set `securityType: 'Standard'`
— just omit the block. FreeBSD 14.4 deploys cleanly as a standard Gen2 VM.

```bicep
resource opnsenseVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  properties: {
    // NO securityProfile block — FreeBSD 14.4 is not on Azure's TL allowlist.
    // Adding securityType: 'TrustedLaunch' causes: BadRequest
  }
}
```

**How to check if the image gained TL support later:**

```bash
az vm image show \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --sku 14_4-release-amd64-gen2-ufs \
    --version latest \
    --query "features[?name=='SecurityType'].value" \
    -o tsv
# Empty output = not TL capable. "TrustedLaunch" in output = now capable — re-add securityProfile.
```

---

## 2. No VM Extensions Work

All three Azure extension mechanisms have been tried and fail on FreeBSD 14.4:

### 2a. `Microsoft.OSTCExtensions.CustomScriptForLinux` (Rounds 2)

**Error:**

```
SyntaxError: leading zeros in decimal integer literals are not permitted;
use an 0o prefix for octal integers
  File ".../customscript.py", line 62:  os.chmod('/var/log/azure/', 0700)
```

**Root cause:** The extension handler (`customscript.py`) is written in Python 2 syntax. FreeBSD 14.4
ships Python 3 only. The handler fails at **parse time during its own install** — before any custom
script ever runs.

**Verified:** Round 2, `westus3`, 2026-05-09.

### 2b. `Microsoft.Azure.Extensions.CustomScript` v2.x (Round 3 candidate)

**Error (if tried):** `Exec format error` — the extension binary is a Linux ELF compiled for x86-64
Linux. FreeBSD 14.4 cannot execute Linux ELF without the `linuxulator` kernel module, which is NOT
loaded by default on Azure-hosted FreeBSD images.

**Status:** Eliminated by investigation; not deployed in this lab.

### 2c. `az vm run-command invoke` / `Microsoft.CPlat.Core.RunCommandLinux` (Round 3)

**Error:**

```
Non-zero exit code: 126,
/var/lib/waagent/Microsoft.CPlat.Core.RunCommandLinux-1.0.9/bin/run-command-shim install
+ /var/lib/waagent/.../bin/run-command-extension install
  cannot execute binary file: Exec format error
```

**Root cause:** `az vm run-command invoke --command-id RunShellScript` **implicitly installs**
the `Microsoft.CPlat.Core.RunCommandLinux` extension handler before executing any script. This
handler binary is a Linux ELF. FreeBSD 14.4 cannot run it.

The `RunShellScript` command does NOT bypass the extension framework on this image/WAAgent version.

**Verified:** Round 3, `westus3`, 2026-05-09. Both primary and secondary NVAs.

### Summary Table

| Mechanism | Publisher | Version | FreeBSD 14.4 Result | Failure reason |
|-----------|-----------|---------|---------------------|----------------|
| CustomScriptForLinux | Microsoft.OSTCExtensions | 1.4.1.0 | ❌ Fails at install | Python 2 octal syntax rejected by Python 3 |
| CustomScript | Microsoft.Azure.Extensions | 2.1.x | ❌ Exec format error | Linux ELF binary |
| RunCommandLinux | Microsoft.CPlat.Core | 1.0.9 | ❌ Exec format error | Linux ELF binary |
| Any FreeBSD extension | thefreebsdfoundation | — | ❌ None published | No FreeBSD extensions in Azure Marketplace |

**Conclusion:** There is no Azure VM extension that supports FreeBSD 14.4. This is a hard platform
limitation as of 2026-05-09.

---

## 3. Cloud-Init Is the Only Viable Bootstrap

The `thefreebsdfoundation/freebsd-14_4` images ship with **cloud-init pre-installed and enabled**
(Azure-friendly publisher contract). Cloud-init via `osProfile.customData` is the only supported
first-boot mechanism.

**Bicep pattern:**

```bicep
var cloudInitTemplate = loadTextContent('../../cloud-init/opnsense-bootstrap.yaml')
var resolvedCloudInit = replace(replace(replace(replace(
    cloudInitTemplate,
    '__URI__',     bootstrapUri),
    '__ROLE__',    role),
    '__LOCAL_CIDR__', localIP),
    '__PEER_IP__', peerIP)

resource opnsenseVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  properties: {
    osProfile: {
      customData: base64(resolvedCloudInit)
    }
  }
}
```

**Key cloud-init facts for FreeBSD 14.4:**

| Aspect | Finding |
|--------|---------|
| Shell for `runcmd` | `/bin/sh -c` (not bash). `set -o pipefail` is supported in `/bin/sh` on FreeBSD 14.4. |
| Package directive | `packages:`, `package_update:` are **no-ops or errors** on FreeBSD. Use `pkg install -y <pkg>` inside `runcmd` instead. |
| Log location | `/var/log/cloud-init-output.log` (cloud-init native); `/var/log/opnsense-bootstrap.log` (script output redirected) |
| Sentinel file (success) | `/var/run/opnsense-bootstrap-done` — written only on true rc=0 (post Round 6 fix) |
| Sentinel file (failure) | `/var/run/opnsense-bootstrap-failed` — written with exit code on non-zero (post Round 6 fix) |
| Status polling | `cloud-init status --wait` is available and reliable for smoke tests |

**⚠️ Tee masks exit codes (pre-Round-6 trap):**

Before Round 6, the `runcmd` step used:

```sh
/tmp/configureopnsense.sh ... 2>&1 | /usr/bin/tee /var/log/opnsense-bootstrap.log
```

`tee` always exits 0. This caused `/var/run/opnsense-bootstrap-done` to be written even when the
bootstrap script failed — making the sentinel unreliable.

**Post-Round-6 pattern (exit-code-preserving):**

```sh
/tmp/configureopnsense.sh ... > /var/log/opnsense-bootstrap.log 2>&1; rc=$?; \
cat /var/log/opnsense-bootstrap.log; \
[ $rc -eq 0 ] \
  && echo "bootstrap-ok-$(date -u +%Y%m%dT%H%M%SZ)" > /var/run/opnsense-bootstrap-done \
  || echo "bootstrap-failed-rc=$rc-$(date -u +%Y%m%dT%H%M%SZ)" > /var/run/opnsense-bootstrap-failed; \
exit $rc
```

This pattern: captures the real exit code → writes the correct sentinel → propagates failure to
cloud-init (making `cloud-init status` report `error` on failure).

---

## 4. `fetch`, Not `curl`

FreeBSD's HTTP/HTTPS download tool is `/usr/bin/fetch` (part of the base system). `curl` is a port
and is NOT installed on the base `thefreebsdfoundation` Azure marketplace image.

```sh
# ✅ Correct — fetch is always available on FreeBSD 14.4 Azure images:
/usr/bin/fetch -o /tmp/configureopnsense.sh 'https://raw.githubusercontent.com/.../scripts/configureopnsense.sh'

# ❌ Wrong — curl is not in base:
curl -o /tmp/configureopnsense.sh 'https://...'   # command not found
```

---

## 5. `python3`, Not `python`

FreeBSD 14.4 ships `python3` and `python3.11` in PATH. **There is no `python` symlink** in the base
image. Scripts that call `python` will fail immediately under `set -euo pipefail`.

**Round 5 blocker:** `configureopnsense.sh` called `python get_nic_gw.py $3` before creating the
symlink. Because `set -euo pipefail` was in effect, the script exited at the first `python` call —
silently skipping OPNsense install and VXLAN configuration. The bootstrap log appeared to succeed
(due to the tee-masking issue) making the failure invisible.

**Fix (Round 6, commit `519bf26`):** Replace every `python` call with `python3`.

**Rule:** On FreeBSD 14.4, always invoke `python3` directly. Never depend on `python` symlink
existence. Audit every `python` call before committing.

---

## 6. `/bin/sh` for `runcmd`

FreeBSD cloud-init executes `runcmd` steps via `/bin/sh -c` as root. This is POSIX sh, not bash.

- `set -o pipefail` **is** supported in `/bin/sh` on FreeBSD 14.4 — safe to use.
- Bash-specific constructs (`[[ ]]`, `${var:-default}` in some forms, process substitution) may fail.
- Use POSIX sh syntax in cloud-config `runcmd` items.

---

## 7. Marketplace Terms

`thefreebsdfoundation/freebsd-14_4` requires explicit marketplace terms acceptance per subscription.
Without this, `az deployment group create` fails at the VM provisioning stage with:

```
MarketplacePurchaseEligibilityFailed
```

This failure is confusing because it occurs **after** networking infrastructure (VNet, subnets, LBs)
has been partially created.

**Fix:** Accept terms as an idempotent preflight step before any deployment:

```bash
az vm image terms accept \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --plan 14_4-release-amd64-gen2-ufs
# Idempotent — safe to re-run on subscriptions where terms are already accepted.
# Output: "accepted": true
```

**Note:** Some Enterprise Agreement (EA) and Cloud Solution Provider (CSP) subscriptions have
policies that prevent third-party marketplace purchases. Contact your Azure administrator if
`az vm image terms accept` returns an error about subscription policy restrictions.

The current `deploy.azcli` includes this as a preflight step automatically.

---

## 8. Image SKU Reference

The current lab image is:

| Field | Value |
|-------|-------|
| Publisher | `thefreebsdfoundation` |
| Offer | `freebsd-14_4` |
| SKU | `14_4-release-amd64-gen2-ufs` |
| Hypervisor Gen | Gen2 |
| Filesystem | UFS |

**Before pinning a different version or SKU:**

```bash
# List available FreeBSD 14.4 SKUs:
az vm image list-skus \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --location westus2 \
    -o table

# Verify TL support for any candidate SKU:
az vm image show \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --sku <candidate-sku> \
    --version latest \
    --query "features[?name=='SecurityType'].value" \
    -o tsv

# Verify marketplace terms for candidate SKU:
az vm image terms show \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --plan <candidate-sku>
```

---

## References

- [thefreebsdfoundation images on Azure](https://learn.microsoft.com/azure/virtual-machines/freebsd-intro-on-azure)
- [Azure Trusted Launch overview](https://learn.microsoft.com/azure/virtual-machines/trusted-launch)
- [cloud-init on Azure](https://learn.microsoft.com/azure/virtual-machines/linux/using-cloud-init)
- [OPNsense bootstrap repo](https://github.com/dmauser/opnazure)
- Lab troubleshooting guide: [`docs/troubleshooting.md`](./troubleshooting.md)
- Trusted Launch ADR: [`docs/architecture/trusted-launch.md`](./architecture/trusted-launch.md)
