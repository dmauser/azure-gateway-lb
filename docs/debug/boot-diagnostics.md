# Boot Diagnostics Runbook — Non-Interactive Log Retrieval

**Scope:** All VMs in the Azure Gateway Load Balancer lab — OPNsense NVAs and Ubuntu consumer VM.  
**Use when:** Serial console is unavailable or you need a quick non-interactive signal (CI, scripted triage, pre-SSH check).  
**Author:** Dumont (Operations / Debug Specialist) — 2026-05-09T19:20:21-05:00  
**See also:** [serial-console.md](./serial-console.md) · [vxlan-proof.md](./vxlan-proof.md) · [../troubleshooting.md](../troubleshooting.md)

---

## Table of Contents

- [Why Boot Diagnostics?](#why-boot-diagnostics)
- [Enable Boot Diagnostics](#enable-boot-diagnostics)
- [Retrieve the Boot Log](#retrieve-the-boot-log)
- [Grep Recipe — Key Keywords](#grep-recipe--key-keywords)
- [Download Screenshot Blob](#download-screenshot-blob)
- [Interpreting Boot Log Output](#interpreting-boot-log-output)
- [Troubleshooting — Empty or Missing Boot Log](#troubleshooting--empty-or-missing-boot-log)

---

## Why Boot Diagnostics?

Boot diagnostics stream the VM's serial port output (COM1 / ttyd0) to Azure storage and make it retrievable via `az vm boot-diagnostics get-boot-log`. This gives you the **same data as the serial console but non-interactively** — useful for:

- Scripted triage pipelines
- Checking NVA state when the serial console extension is unavailable or rate-limited
- Getting a snapshot of the boot log at a specific moment (the boot log is a rolling buffer)
- Confirming cloud-init ran at all before attempting SSH or serial console

The boot log is the **fastest first signal** after a deploy: did cloud-init fire? Did the kernel panic? Did `configureopnsense.sh` log anything visible?

---

## Enable Boot Diagnostics

The `thefreebsdfoundation/freebsd-14_4` and `Canonical/ubuntu-22_04` images deployed by this lab's Bicep templates have boot diagnostics enabled by default (managed storage). Verify:

```bash
# OPNsense primary NVA
az vm show \
  -g "$RG_PROVIDER" \
  -n provider-nva-1 \
  --query "diagnosticsProfile.bootDiagnostics" \
  -o json

# Consumer VM
az vm show \
  -g "$RG_CONSUMER" \
  -n consumer-vm \
  --query "diagnosticsProfile.bootDiagnostics" \
  -o json
```

**Expected (both VMs):**

```json
{
  "enabled": true,
  "storageUri": null
}
```

`"storageUri": null` with `"enabled": true` = managed storage (no storage account required).

**If disabled**, enable (idempotent — safe to run even if already enabled):

```bash
# Enable on all four lab VMs at once
for RG_VM in \
  "$RG_PROVIDER:provider-nva-1" \
  "$RG_PROVIDER:provider-nva-2" \
  "$RG_CONSUMER:consumer-vm"; do
  RG="${RG_VM%%:*}"
  VM="${RG_VM##*:}"
  echo "Enabling boot diagnostics on $VM in $RG..."
  az vm boot-diagnostics enable -g "$RG" -n "$VM" --output none
done
echo "Done."
```

> ℹ️ Enabling boot diagnostics does NOT require a reboot. Data appears in the log on the next boot or within ~2 minutes for a running VM.

---

## Retrieve the Boot Log

The boot log dumps the entire serial port buffer to stdout. Pipe or redirect as needed.

```bash
# Primary OPNsense NVA
az vm boot-diagnostics get-boot-log \
  -g "$RG_PROVIDER" \
  -n provider-nva-1

# Secondary OPNsense NVA
az vm boot-diagnostics get-boot-log \
  -g "$RG_PROVIDER" \
  -n provider-nva-2

# Consumer VM (Ubuntu)
az vm boot-diagnostics get-boot-log \
  -g "$RG_CONSUMER" \
  -n consumer-vm
```

**Save to file for offline inspection:**

```powershell
# PowerShell
az vm boot-diagnostics get-boot-log `
  -g $env:RG_PROVIDER `
  -n provider-nva-1 `
  | Out-File -FilePath "nva1-bootlog-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt" -Encoding utf8
```

```bash
# Bash
az vm boot-diagnostics get-boot-log \
  -g "$RG_PROVIDER" \
  -n provider-nva-1 \
  > "nva1-bootlog-$(date +%Y%m%d-%H%M%S).txt"
```

---

## Grep Recipe — Key Keywords

Pipe the boot log through keyword filters for rapid triage. These work in both Bash and PowerShell.

### PowerShell (operator's primary shell)

```powershell
# Run once and cache
$bootlog = az vm boot-diagnostics get-boot-log `
  -g $env:RG_PROVIDER -n provider-nva-1

# Keyword scan — one block
$keywords = @(
  'cloud-init',          # confirms cloud-init ran
  'bootstrap-ok',        # success sentinel echoed to console
  'bootstrap-failed',    # failure sentinel echoed to console
  'python3',             # python3 invocation (expected for get_nic_gw.py)
  'Permission denied',   # auth or filesystem issues
  'panic',               # kernel panic
  'vxlan',               # VXLAN interface bring-up
  'Error on line',       # bash trap fired in configureopnsense.sh
  'fetch:',              # FreeBSD fetch output (script download)
  'opnsense-bootstrap',  # OPNsense installer running
  'cloud-config',        # cloud-init YAML parsed
  'runcmd'               # runcmd execution
)

foreach ($kw in $keywords) {
  $matches = $bootlog | Select-String -Pattern $kw -CaseSensitive:$false
  if ($matches) {
    Write-Host "=== $kw ===" -ForegroundColor Cyan
    $matches | ForEach-Object { Write-Host $_.Line }
  } else {
    Write-Host "--- $kw : NOT FOUND ---" -ForegroundColor Yellow
  }
}
```

### Bash (in WSL or Linux)

```bash
bootlog=$(az vm boot-diagnostics get-boot-log \
  -g "$RG_PROVIDER" -n provider-nva-1)

for kw in cloud-init bootstrap-ok bootstrap-failed python3 "Permission denied" panic vxlan "Error on line" "fetch:" "opnsense-bootstrap" runcmd; do
  count=$(echo "$bootlog" | grep -ci "$kw" 2>/dev/null || echo 0)
  printf "%-25s : %d hits\n" "$kw" "$count"
done
```

### Quick one-liners for specific questions

```powershell
# Did cloud-init actually run?
az vm boot-diagnostics get-boot-log -g $env:RG_PROVIDER -n provider-nva-1 |
  Select-String "cloud-init"

# Did the bootstrap succeed?
az vm boot-diagnostics get-boot-log -g $env:RG_PROVIDER -n provider-nva-1 |
  Select-String "bootstrap-ok|bootstrap-failed"

# Any kernel panic?
az vm boot-diagnostics get-boot-log -g $env:RG_PROVIDER -n provider-nva-1 |
  Select-String "panic"

# Did the python3 get_nic_gw.py call run?
az vm boot-diagnostics get-boot-log -g $env:RG_PROVIDER -n provider-nva-1 |
  Select-String "python3"

# Did VXLAN come up?
az vm boot-diagnostics get-boot-log -g $env:RG_PROVIDER -n provider-nva-1 |
  Select-String "vxlan"
```

---

## Download Screenshot Blob

For VMs that are graphically stuck (rare for FreeBSD text-mode, but possible), retrieve the screenshot:

```bash
# Get SAS URIs for the screenshot and serial log blobs
az vm boot-diagnostics get-boot-log-uris \
  -g "$RG_PROVIDER" \
  -n provider-nva-1 \
  -o json
```

**Output format:**

```json
{
  "consoleScreenshotBlobUri": "https://<storage>.blob.core.windows.net/...<SAS>",
  "serialConsoleLogBlobUri":  "https://<storage>.blob.core.windows.net/...<SAS>"
}
```

Download the screenshot:

```powershell
# PowerShell
$uris = az vm boot-diagnostics get-boot-log-uris `
  -g $env:RG_PROVIDER -n provider-nva-1 | ConvertFrom-Json

Invoke-WebRequest -Uri $uris.consoleScreenshotBlobUri `
  -OutFile "nva1-screenshot-$(Get-Date -Format 'yyyyMMdd-HHmmss').bmp"

# Open immediately (Windows)
Start-Process "nva1-screenshot-*.bmp"
```

> ℹ️ For FreeBSD NVAs, the screenshot will be a text-mode terminal image. It is most useful for confirming what is on-screen when the boot loader is paused or when the VM is stuck at a login prompt.

---

## Interpreting Boot Log Output

### Timeline of a healthy OPNsense boot

```
[0–10s]   FreeBSD EFI loader / kernel messages (hardware detection, ATA, NIC init)
[10–30s]  cloud-init: DataSourceAzure detected, user-data decoded
[30–60s]  cloud-init: runcmd step 0 — hostname set
[60–90s]  cloud-init: runcmd step 1 — fetch configureopnsense.sh (network must be up)
[90–300s] cloud-init: runcmd step 2 — configureopnsense.sh running
           - fetch XML templates and get_nic_gw.py
           - python3 get_nic_gw.py (derive gateway)
           - sed substitutions on XML
           - opnsense-bootstrap.sh.in -y -r 25.1 (OPNsense package install ~5-10 min)
           - rc.syshook 25-azure written
           - sshd_config patched (PermitRootLogin yes)
[~15 min] bootstrap-ok-<ISO8601Z> echoed to console / sentinel written
[~15 min] cloud-init: status done
[~15 min] OPNsense launches — menu appears on console
```

### Diagnosis by keyword presence/absence

| Keyword found? | Keyword absent? | Interpretation |
|---|---|---|
| `cloud-init` ✅ | — | cloud-init ran — boot diagnostics are working |
| `cloud-init` ❌ | — | cloud-init did not run — either too early to check, or cloud-init not enabled on this image |
| `runcmd` ✅ | — | runcmd block reached — YAML was parsed |
| `fetch:` ✅ | — | Network was up when cloud-init ran; fetch succeeded |
| `fetch:` ❌ | `runcmd` ✅ | Network not available when runcmd ran — DHCP timing issue |
| `python3` ✅ | — | `get_nic_gw.py` was invoked — gateway derivation step reached |
| `Error on line` | — | `configureopnsense.sh` trap fired — check line number and bootstrap log |
| `bootstrap-ok` ✅ | — | Bootstrap succeeded — sentinel echoed to serial port |
| `bootstrap-failed` ✅ | — | Bootstrap failed — check `rc=N` in the sentinel string |
| `panic` | — | Kernel panic — system requires restart; may be image or hardware issue |
| `vxlan` ✅ | — | VXLAN interface appeared on serial output — rc.syshook ran |
| `Permission denied` | — | File system or permission issue in cloud-init runcmd |

### Common failure patterns

#### Pattern 1: Bootstrap fails silently (sentinel written but OPNsense absent)

**Boot log shows:**
```
bootstrap-ok-20260509T192021Z
```

**But** OPNsense web GUI does not respond and VXLAN is not configured.

**Root cause:** This was the Round 5 bug — `tee` pipeline masked the real exit code. In the current YAML (Round 6+), this should not happen. But if you see `bootstrap-ok` without an OPNsense GUI, check the full bootstrap log via serial console (`tail -200 /var/log/opnsense-bootstrap.log`).

#### Pattern 2: `python` not found (pre-Round-6 script)

**Boot log shows:**
```
Error on line 70 (exit 127)
```
or
```
/tmp/configureopnsense.sh: python: not found
```

**Root cause:** Script called `python` (Python 2, absent on FreeBSD 14.4). The current `configureopnsense.sh` uses `python3` — if you see this, the stale script from GitHub main was fetched. Verify `OPN_BOOTSTRAP_URI` points to the current branch and `git push origin main` was run.

#### Pattern 3: Fetch failure (URI stale or network not ready)

**Boot log shows:**
```
fetch: https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/configureopnsense.sh: Not Found
```

**Root cause:** `OPN_BOOTSTRAP_URI` points to a path that doesn't exist on GitHub (e.g., stale branch, wrong commit). Verify the URI resolves: `curl -s -o /dev/null -w "%{http_code}" <URI>configureopnsense.sh` — must return `200`.

---

## Troubleshooting — Empty or Missing Boot Log

### "No boot log data available" or empty output

1. **Boot diagnostics not enabled.** Run the enable command from [Enable Boot Diagnostics](#enable-boot-diagnostics).

2. **VM never booted.** Check power state: `az vm get-instance-view -g "$RG_PROVIDER" -n provider-nva-1 --query "instanceView.statuses[1].displayStatus" -o tsv`. If `VM deallocated`, start it first.

3. **Managed storage not yet flushed.** For a VM that just booted, the log may take 2–5 minutes to populate. Wait and retry.

4. **Image does not support serial console output.** Rare for Azure Marketplace images from `thefreebsdfoundation` or `Canonical`. If confirmed, see the [serial-console.md](./serial-console.md) runbook for interactive access.

5. **Subscription-level diagnostics restriction.** Some enterprise subscriptions disable the managed boot diagnostics storage feature via Azure Policy. Check with your subscription owner. As a workaround, specify an explicit storage account:
   ```bash
   az vm boot-diagnostics enable \
     -g "$RG_PROVIDER" \
     -n provider-nva-1 \
     --storage "https://<your-storage-account>.blob.core.windows.net"
   ```

### "ResourceNotFound" error on get-boot-log

The VM resource does not exist in the specified resource group. Verify:

```bash
az vm list -g "$RG_PROVIDER" --query "[].name" -o tsv
```

The Bicep module names them `provider-nva-1` and `provider-nva-2` by default (verify with `az vm list -g "$RG_PROVIDER" -o table`).

---

*Cross-references: [serial-console.md](./serial-console.md) · [vxlan-proof.md](./vxlan-proof.md) · [../troubleshooting.md](../troubleshooting.md) · [../troubleshooting-freebsd-on-azure.md](../troubleshooting-freebsd-on-azure.md)*
