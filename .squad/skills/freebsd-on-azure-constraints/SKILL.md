# SKILL: FreeBSD-on-Azure Platform Constraints

**Category:** Azure / VM Provisioning / OS Compatibility  
**Discovered:** 2026-05-09T19:20:21-05:00 (consolidated from Rounds 1–6)  
**Author:** Flynn (Lead / Azure Architect)  
**Validated by:** Quorra (Rounds 1–5, empirical)

---

## Problem Class

You are deploying or bootstrapping a FreeBSD VM (`thefreebsdfoundation/freebsd-14_4`) on Azure and
hitting platform-level failures that are not documented in standard Azure VM docs.

---

## Constraint Checklist (run through this before any FreeBSD-on-Azure work)

### 1. No Trusted Launch

```
BadRequest: Use of TrustedLaunch setting is not supported for the provided image.
```

- `thefreebsdfoundation/freebsd-14_4` is NOT on Azure's Trusted Launch allowlist
- Setting `securityType: 'TrustedLaunch'` with ANY `secureBootEnabled`/`vTpmEnabled` combination is rejected
- Fix: omit `securityProfile` block entirely

```bash
# Verify current status:
az vm image show \
    --publisher thefreebsdfoundation --offer freebsd-14_4 \
    --sku 14_4-release-amd64-gen2-ufs --version latest \
    --query "features[?name=='SecurityType'].value" -o tsv
# Empty output = not TL capable
```

### 2. No VM Extensions Work

| Extension | Reason |
|-----------|--------|
| `Microsoft.OSTCExtensions.CustomScriptForLinux` | Python 2 handler; FreeBSD 14.4 has Python 3 only |
| `Microsoft.Azure.Extensions.CustomScript` | Linux ELF binary |
| `az vm run-command invoke` / `RunCommandLinux` | Installs Linux ELF extension handler |
| `thefreebsdfoundation/*` | None published in Azure Marketplace |

**Use cloud-init (`customData`) instead — it is the ONLY viable bootstrap mechanism.**

### 3. Cloud-Init Is the Bootstrap Mechanism

```bicep
var resolvedYaml = replace(replace(replace(replace(
    loadTextContent('./cloud-init/template.yaml'),
    '__URI__', bootstrapUri), '__ROLE__', role),
    '__LOCAL_CIDR__', localIP), '__PEER_IP__', peerIP)

osProfile: {
    customData: base64(resolvedYaml)
}
```

FreeBSD cloud-init notes:
- `packages:`, `package_update:` are no-ops — use `runcmd` with `pkg install -y`
- `runcmd` runs via `/bin/sh -c` as root; `set -o pipefail` works on FreeBSD 14.4
- Exit code from `runcmd` propagates to `cloud-init status`

### 4. Use `fetch`, Not `curl`

```sh
# ✅ Correct:
/usr/bin/fetch -o /tmp/script.sh 'https://example.com/script.sh'

# ❌ Wrong — curl is a port, not in base:
curl -o /tmp/script.sh 'https://example.com/script.sh'
```

### 5. Use `python3`, Not `python`

FreeBSD 14.4 has `python3`/`python3.11` only. No `python` symlink in PATH.

```sh
# ✅ Correct:
python3 get_nic_gw.py $arg

# ❌ Wrong — exits immediately under set -euo pipefail:
python get_nic_gw.py $arg
```

### 6. Exit-Code-Preserving runcmd Pattern

```sh
# ❌ Wrong — tee masks exit code:
/tmp/script.sh ... 2>&1 | /usr/bin/tee /var/log/script.log

# ✅ Correct — captures real rc:
/tmp/script.sh ... > /var/log/script.log 2>&1; rc=$?; \
cat /var/log/script.log; \
[ $rc -eq 0 ] \
  && echo "ok-$(date -u +%Y%m%dT%H%M%SZ)" > /var/run/script-done \
  || echo "failed-rc=$rc-$(date -u +%Y%m%dT%H%M%SZ)" > /var/run/script-failed; \
exit $rc
```

### 7. Marketplace Terms Required

```bash
# Run before first deploy on any subscription (idempotent):
az vm image terms accept \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --plan 14_4-release-amd64-gen2-ufs
```

Without this: `MarketplacePurchaseEligibilityFailed` after partial resource creation.

---

## Sentinel Verification Pattern

```bash
# SSH into NVA after bootstrap:
cat /var/run/opnsense-bootstrap-done    # present = true success
cat /var/run/opnsense-bootstrap-failed  # present = failure; inspect log
tail -50 /var/log/opnsense-bootstrap.log
cloud-init status --long
```

---

## Applied In

- `bicep/modules/VM/opnsense-vm-active-active.bicep` — no securityProfile, customData wired
- `bicep/cloud-init/opnsense-bootstrap.yaml` — tee-free runcmd pattern
- `scripts/configureopnsense.sh` — python3 calls, fetch for downloads
- `deploy.azcli` — marketplace terms preflight, GLB poll
- `docs/troubleshooting-freebsd-on-azure.md` — detailed reference

---

## See Also

- `freebsd-on-azure-bootstrap` SKILL — note: Run-Command section is stale (superseded by cloud-init)
- `freebsd-python-on-azure` SKILL
- `cloud-init-runcmd-exit-discipline` SKILL
- `marketplace-terms-preflight` SKILL
