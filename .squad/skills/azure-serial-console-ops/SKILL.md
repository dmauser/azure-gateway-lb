# SKILL: Azure Serial Console — Operational Runbook (FreeBSD / OPNsense)

**Category:** Operations / Debug  
**Applies to:** Any FreeBSD VM on Azure where SSH is unreachable (especially OPNsense NVAs)  
**Author:** Dumont (Operations / Debug Specialist) — 2026-05-09T19:20:21-05:00  
**Full runbook:** `docs/debug/serial-console.md`

---

## Problem

SSH to a FreeBSD NVA (OPNsense) is unavailable — either no NAT rule for port 22 exists, bootstrap has not completed, or the VM is stuck pre-boot. Need out-of-band console access to run diagnostics.

---

## Canonical Procedure

### 1. Install extension

```bash
az extension add --name serial-console
```

### 2. Connect

```bash
az serial-console connect \
  -g "$RG_PROVIDER" \
  -n provider-nva-1 \
  --subscription "$SUBSCRIPTION_ID"
```

Press **Enter** once if console appears blank.

### 3. Navigate OPNsense

At the OPNsense menu: **press `8`** for a root shell.

If you see a raw FreeBSD login (`login:`): bootstrap has not completed — log in with the admin password from deploy params.

### 4. Five canonical diagnostics

```sh
# a) Success sentinel
cat /var/run/opnsense-bootstrap-done

# b) Failure sentinel
cat /var/run/opnsense-bootstrap-failed

# c) Logs
tail -200 /var/log/opnsense-bootstrap.log
tail -200 /var/log/cloud-init-output.log

# d) Cloud-init status
cloud-init status --long

# e) Network/VXLAN
ifconfig
route -n get default
tcpdump -nn -i any "udp port 10800 or udp port 10801" -c 10
```

### 5. Detach cleanly

Press **`Ctrl+]`** (Control + right bracket).

---

## RBAC Required

`Virtual Machine Contributor` (or `Contributor`) on the VM or its resource group. Reader is not enough.

---

## FreeBSD-specific quirks

| Quirk | Mitigation |
|-------|-----------|
| Console blank after connect | Press Enter once; or `Ctrl+L` to refresh |
| OPNsense menu needs exact keypress | Type digit + Enter; `8` + Enter = shell |
| IME conflict on Windows | Disable IME or use Portal browser serial console |
| Boot loader window | Only ~3 seconds to interrupt — attach console BEFORE issuing `az vm restart` |

---

## Pre-requisite: Boot diagnostics enabled

Boot diagnostics must be enabled for serial console to work:

```bash
az vm boot-diagnostics enable -g "$RG" -n "$VM_NAME"
# Verify:
az vm show -g "$RG" -n "$VM_NAME" \
  --query "diagnosticsProfile.bootDiagnostics" -o json
# Expected: { "enabled": true, "storageUri": null }
```

---

## When to use serial console vs boot diagnostics

| Scenario | Use |
|----------|-----|
| Need interactive shell | Serial console (`az serial-console connect`) |
| Need non-interactive log snapshot | Boot diagnostics (`az vm boot-diagnostics get-boot-log`) |
| VM is rebooting / pre-OS | Serial console (attach before reboot) |
| CI/CD triage script | Boot diagnostics (no interactive session needed) |
| Both SSH and serial console hung | Boot diagnostics → diagnose → serial console to fix |

---

## Source

Derived from live deploy rounds 1–6 of `dmauser/azure-gateway-lb`. The key insight: **Azure serial console is the ONLY reliable out-of-band path for FreeBSD NVAs** because:
- `az vm run-command` installs Linux ELF extensions (fail on FreeBSD)
- SSH requires a NAT rule that the default Bicep does not provision (only port 443)
- Serial console works regardless of bootstrap state, networking, or OS health
