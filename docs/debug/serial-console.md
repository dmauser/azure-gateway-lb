# Serial Console Runbook — OPNsense NVAs on Azure

**Scope:** FreeBSD 14.4 OPNsense NVAs (`provider-nva-1`, `provider-nva-2`) deployed via `bicep/glb-active-active.bicep`.  
**Use when:** SSH is unreachable, the NVA is unresponsive, or you need out-of-band first-boot debugging.  
**Author:** Dumont (Operations / Debug Specialist) — 2026-05-09T19:20:21-05:00  
**See also:** [boot-diagnostics.md](./boot-diagnostics.md) · [vxlan-proof.md](./vxlan-proof.md) · [../troubleshooting.md](../troubleshooting.md)

---

## Table of Contents

- [Prerequisites](#prerequisites)
  - [OPNsense XML — Serial Console Must Be Enabled in Config](#opnsense-xml--serial-console-must-be-enabled-in-config)
- [Enable Boot Diagnostics (required by serial console)](#enable-boot-diagnostics-required-by-serial-console)
- [Attaching the Serial Console](#attaching-the-serial-console)
- [What to Expect at the OPNsense Console](#what-to-expect-at-the-opnsense-console)
- [FreeBSD Boot Loader Path (pre-bootstrap debugging)](#freebsd-boot-loader-path-pre-bootstrap-debugging)
- [Canonical Diagnostics to Run](#canonical-diagnostics-to-run)
- [Troubleshooting Console Issues](#troubleshooting-console-issues)
  - [No output on attach (XML stanza missing or wrong)](#no-output-on-attach-xml-stanza-missing-or-wrong)
- [Detaching Cleanly](#detaching-cleanly)

---

## Prerequisites

### RBAC

The operator must have **at minimum** one of:

| Role | Notes |
|------|-------|
| `Virtual Machine Contributor` | Minimum required for serial console access |
| `Contributor` | Covers all operations |
| Custom role with `Microsoft.SerialConsole/serialPorts/connect/action` | Least-privilege approach |

A user with **Reader** only will see the NVA in the portal but receive `403 Forbidden` when connecting to the serial console.

### Azure CLI Extension

The `serial-console` extension must be installed:

```bash
az extension add --name serial-console
# Verify:
az serial-console --help
```

### OPNsense XML — Serial Console Must Be Enabled in Config

> ⚠️ **Hard dependency (Ram's artifact):** `az serial-console connect` will attach successfully but show **no output** if the OPNsense `config.xml` does not contain the serial console stanza. Azure's serial port is always wired at the hypervisor layer; the guest must be explicitly told to write to it.

The canonical stanza (shipped by Ram — see `scripts/glb-config.xml` and `scripts/glb-config-active-active-primary.xml` for the exact placement):

```xml
<!-- Azure serial console: 115200 baud matches Azure's fixed requirement.
     enableserial activates the serial port in OPNsense.
     primaryconsole=serial routes all console I/O to ttyu0/COM1.
     Reference: dmauser/opnazure scripts/config.xml -->
<enableserial>1</enableserial>
<serialspeed>115200</serialspeed>
<primaryconsole>serial</primaryconsole>
```

These elements live inside the `<system>` block of the OPNsense config XML, applied during bootstrap by `configureopnsense.sh` via `sed` substitution.

**Ram's commit:** TBD (shipping in parallel — check `scripts/glb-config*.xml` on `main` after push).

> ℹ️ The existing skill `.squad/skills/opnsense-azure-serial-console/SKILL.md` documents an alternative dual-console pattern (`<primaryconsole>video</primaryconsole>` + `<secondaryconsole>serial</secondaryconsole>`) which keeps VGA as primary while also writing to serial. Both patterns work; Ram's shipped stanza takes precedence for this lab. If the OPNsense menu is needed on a physical/Bastion VGA connection after serial is set as primary, use the Portal browser serial console or switch to the dual-console pattern.

**If the XML stanza is missing or wrong**, `az serial-console connect` will attach (you will see `[Connected to virtual machine...]`) but the terminal will be blank. See [No output on attach (XML stanza missing or wrong)](#no-output-on-attach-xml-stanza-missing-or-wrong) in Troubleshooting.

### Boot diagnostics must be enabled

Serial console requires boot diagnostics (managed storage is preferred). See [Enable Boot Diagnostics](#enable-boot-diagnostics-required-by-serial-console) below.

### Environment variables

```bash
export SUBSCRIPTION_ID="<your-subscription-id>"
export RG_PROVIDER="rg-glb-provider-quorra"   # or your override
```

---

## Enable Boot Diagnostics (required by serial console)

The `thefreebsdfoundation/freebsd-14_4` marketplace image enables boot diagnostics by default when deployed via the squad's Bicep templates. Verify with:

```bash
az vm show \
  -g "$RG_PROVIDER" \
  -n provider-nva-1 \
  --query "diagnosticsProfile.bootDiagnostics" \
  -o json
```

**Expected output (managed storage):**

```json
{
  "enabled": true,
  "storageUri": null
}
```

`"storageUri": null` with `"enabled": true` = managed storage (preferred — no storage account needed).

**If boot diagnostics are off**, enable them (idempotent):

```bash
az vm boot-diagnostics enable \
  -g "$RG_PROVIDER" \
  -n provider-nva-1

az vm boot-diagnostics enable \
  -g "$RG_PROVIDER" \
  -n provider-nva-2
```

> ⚠️ A VM reboot is NOT required after enabling boot diagnostics. The serial console becomes available on the next boot or within a few minutes on a running VM.

---

## Attaching the Serial Console

### Connect (interactive)

```bash
# Primary NVA
az serial-console connect \
  -g "$RG_PROVIDER" \
  -n provider-nva-1 \
  --subscription "$SUBSCRIPTION_ID"

# Secondary NVA
az serial-console connect \
  -g "$RG_PROVIDER" \
  -n provider-nva-2 \
  --subscription "$SUBSCRIPTION_ID"
```

The command opens an interactive terminal session over the Azure serial port (COM1 / ttyd0 on FreeBSD). You may need to **press Enter** once to wake the console if the VM is idle.

### Portal alternative

Azure Portal → Virtual Machines → `provider-nva-1` → **Help** → **Serial console**. This requires the same RBAC as the CLI path.

---

## What to Expect at the OPNsense Console

### If bootstrap SUCCEEDED

You will see the **OPNsense menu**:

```
*** Welcome to OPNsense 25.1 ***

 LAN (hn1)        -> v4: 10.0.1.4/24
 WAN (hn0)        -> v4/DHCP4: 10.0.0.x/24

 0) Logout (SSH only)
 1) Assign Interfaces
 2) Set Interface IP address
 3) Reset the root password
 4) Reset to factory defaults
 5) Reboot system
 6) Halt system
 7) Ping host
 8) Shell
 9) pfTop
10) Filter Logs
11) Restart web interface
12) OPNsense Update
13) Restore a configuration backup
14) Restore and reinstall packages
15) Restore and reinstall packages with full reset
16) PowerOff system

Enter an option:
```

**Key menu items:**

| Option | Action |
|--------|--------|
| `8` | Drop to root shell (FreeBSD `sh`) — run all diagnostics from here |
| `7` | Ping test — quick network reachability check |
| `2` | View/set interface IPs |
| `12` | OPNsense Update (avoid during lab — can change config) |

**Default credentials:**

| Username | Password | Notes |
|----------|----------|-------|
| `root` | `opnsense` | OPNsense factory default; may be changed if bootstrap configured a password |

> ℹ️ If `admin` is shown as login, try both `root` and `admin`. The squad bootstrap does not currently set a custom root password — factory default `opnsense` applies.

### If bootstrap FAILED or is still running

You will see a raw **FreeBSD login prompt** or a blank cursor:

```
FreeBSD/amd64 (primary-nva) (ttyd0)

login:
```

This means OPNsense did NOT install (bootstrap failed, still in progress, or cloud-init has not fired yet). Proceed with the [Canonical Diagnostics](#canonical-diagnostics-to-run) below.

**Login:** `root` with the `adminPassword` / `TempPassword` set in the Bicep deploy parameters (check `deploy.azcli` for the value supplied as `--admin-password`).

---

## FreeBSD Boot Loader Path (pre-bootstrap debugging)

Use this if the VM is stuck before the OS loads — e.g., kernel panic, disk/image corruption, or you want single-user mode.

### Interrupt the boot loader

1. Attach serial console (see above).
2. **Reboot the VM** in a separate terminal:
   ```bash
   az vm restart -g "$RG_PROVIDER" -n provider-nva-1 --no-wait
   ```
3. Watch the console — you have approximately **3 seconds** to press any key at the FreeBSD boot menu (you will see countdown `Hit [Enter] to boot immediately, or any other key for command prompt`).
4. Press **any key** to interrupt.

### Boot menu options

```
  1. Boot Multi User [Enter]
  2. Boot [S]ingle User
  3. Escape to [L]oader Prompt
  4. Reboot
  Options:
  5. [K]ernel: kernel (1 of 2)
  6. [B]oot Options
```

| Option | Use |
|--------|-----|
| `2` / `S` | Single-user mode — mount root read-write, then `fsck -y /` + `mount -a` |
| `3` / `L` | Loader prompt — manual module loading, variable inspection |

### Single-user mode quick procedure

```
# At the single-user shell prompt:
mount -u /
mount -a
# Now inspect cloud-init artifacts:
cat /var/log/cloud-init-output.log | tail -50
cat /var/run/opnsense-bootstrap-done 2>/dev/null || echo "SENTINEL ABSENT"
cat /var/run/opnsense-bootstrap-failed 2>/dev/null || echo "NO FAILURE SENTINEL"
```

---

## Canonical Diagnostics to Run

Access the shell via **Option 8** from the OPNsense menu, or by logging in at the FreeBSD prompt as `root`.

### a) Bootstrap success sentinel

```sh
cat /var/run/opnsense-bootstrap-done
```

**Expected on success:**
```
bootstrap-ok-20260509T192021Z
```

**If absent:** Bootstrap did not complete. Check the failure sentinel next.

> ⚠️ **Known reliability issue:** In Round 5, the `tee`-based pipeline in the old cloud-init YAML caused the sentinel to be written even on script failure (tee exits 0). The current YAML (post-Round 6) writes the sentinel via an explicit `[ $rc -eq 0 ]` check — sentinel presence IS reliable evidence of success in Round 6+. See [`opnsense-bootstrap.yaml`](../../bicep/cloud-init/opnsense-bootstrap.yaml).

### b) Bootstrap failure sentinel

```sh
cat /var/run/opnsense-bootstrap-failed
```

**Expected on failure:**
```
bootstrap-failed-rc=1-20260509T192021Z
```

The exit code embedded in the filename is the exit code of `configureopnsense.sh`. Common codes:
- `rc=1` — general script error (check the bootstrap log)
- `rc=127` — command not found (e.g., `python` instead of `python3`, or `fetch` path issue)

### c) Bootstrap and cloud-init logs

```sh
# Full bootstrap script output
tail -200 /var/log/opnsense-bootstrap.log

# Cloud-init native output (includes runcmd execution)
tail -200 /var/log/cloud-init-output.log
```

**What to look for in `opnsense-bootstrap.log`:**

| Pattern | Meaning |
|---------|---------|
| `fetch: ...` lines | Script downloading XML / Python helper — fetches ok means network ok |
| `Error on line N (exit 1)` | Trap fired — exact line number of failure |
| `python3 get_nic_gw.py` | Gateway derivation — if missing, script exited before this point |
| `cp glb-config-active-active-primary.xml /usr/local/etc/config.xml` | Config applied |
| `sh ./opnsense-bootstrap.sh.in -y -r 25.1` | OPNsense installer started |

**What to look for in `cloud-init-output.log`:**

| Pattern | Meaning |
|---------|---------|
| `Cloud-init v.` | cloud-init version line — confirms cloud-init ran |
| `Running module final:runcmd` | runcmd block executed |
| `bootstrap-ok-` | Success sentinel written via runcmd inline `echo` |
| `Traceback` | Python error in cloud-init itself |
| `Failed to run module` | cloud-init module-level failure |

### d) Cloud-init status

```sh
cloud-init status --long
```

**Expected output when complete:**

```
status: done
time: Mon, 09 May 2026 19:20:21 +0000
detail:
DataSourceAzure
```

**If still running:**

```
status: running
```

Wait and retry. OPNsense bootstrap typically takes 5–15 minutes (includes OPNsense package install via `opnsense-bootstrap.sh.in`).

**If failed:**

```
status: error
```

Examine `cloud-init-output.log` for the failing module.

### e) Network and VXLAN sanity checks

Run these from the root shell (Option 8 or login):

```sh
# Interface status — look for hn0 (WAN/untrusted), hn1 (LAN/trusted), vxlan0, vxlan1
ifconfig

# Default route — should point to hn0's gateway
route -n get default

# VXLAN-specific interface check
ifconfig vxlan0
ifconfig vxlan1

# Live VXLAN packet capture — 10 packets, any interface, both VXLAN ports
# (Run this WHILE generating traffic — see vxlan-proof.md for full procedure)
tcpdump -nn -i any "udp port 10800 or udp port 10801" -c 10
```

**Expected `ifconfig vxlan0` output (after bootstrap):**

```
vxlan0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
        options=80000<LINKSTATE>
        ether 12:34:56:78:9a:bc
        inet 10.0.0.4 netmask 0xffffff00 broadcast 10.0.0.255
        groups: vxlan
        vxlan: vni 800 local 10.0.1.4 remote 168.63.129.16 local-port 10800 remote-port 10800
        ...
```

**Expected `route -n get default`:**

```
   route to: default
destination: default
       mask: default
    gateway: 10.0.0.1
  interface: hn0
      flags: <UP,GATEWAY,DONE,STATIC>
```

**VXLAN UDP socket check (confirms OPNsense is listening):**

```sh
sockstat -l -P udp | grep -E '10800|10801'
```

Expected: two lines showing `vxlan0` and `vxlan1` bound to ports 10800 and 10801.

---

## Troubleshooting Console Issues

### No output on attach (XML stanza missing or wrong)

**Symptom:** `az serial-console connect` prints `[Connected to virtual machine 'provider-nva-1'. Use Ctrl+] to exit.]` but the terminal is completely blank — no cursor, no boot text, no OPNsense menu — even after pressing Enter.

**Root cause:** The FreeBSD kernel and OPNsense are not writing to COM1/ttyu0. Azure's serial console endpoint is always live at the hypervisor, but the guest must be configured to use it.

**Diagnostic sequence (without a working console):**

1. **Check the boot log for serial output** — even if the interactive console is blank, boot diagnostics may have captured early boot messages:
   ```bash
   az vm boot-diagnostics get-boot-log \
     -g "$RG_PROVIDER" -n provider-nva-1 | Select-String "uart|ttyu|console|serial"
   ```
   - Output present → kernel DID write to serial at some point; problem is post-boot OPNsense config
   - Empty → kernel never wrote to serial → check `/boot.config` or XML stanza

2. **Inspect the active OPNsense config.xml via boot diagnostics log** (if bootstrap completed):
   The bootstrap log echoes the config.xml path — grep the boot log:
   ```bash
   az vm boot-diagnostics get-boot-log \
     -g "$RG_PROVIDER" -n provider-nva-1 | Select-String "enableserial|serialspeed|primaryconsole|secondaryconsole"
   ```
   If no matches: the XML stanza was never written — bootstrap likely failed before `cp glb-config*.xml /usr/local/etc/config.xml`.

3. **If you can get a shell by another path** (SSH via Bastion, or after fixing bootstrap):
   ```sh
   # Confirm the XML stanza is present
   grep -E 'enableserial|serialspeed|primaryconsole|secondaryconsole' /usr/local/etc/config.xml

   # Expected output (Ram's stanza):
   # <enableserial>1</enableserial>
   # <serialspeed>115200</serialspeed>
   # <primaryconsole>serial</primaryconsole>

   # Check what loader.conf says (OPNsense writes this from config.xml at runtime)
   grep -E 'console|comconsole' /boot/loader.conf

   # Check dmesg for UART/serial port detection
   dmesg | grep -i uart
   # Expected: uart0: <16550 or compatible> at port 0x3f8 irq 4 flags 0x10 on isa0
   ```

4. **Force serial console at the boot loader level** (emergency path — survives config.xml issues):
   If you can interrupt the FreeBSD boot loader (see [FreeBSD Boot Loader Path](#freebsd-boot-loader-path-pre-bootstrap-debugging)):
   ```
   # At the loader prompt (option 3 from boot menu):
   set console="comconsole"
   set comconsole_speed="115200"
   boot
   ```
   This overrides config.xml for the current boot only. Use it to get a working console, then fix the XML permanently.

5. **Check `/boot.config`** (a persistent override file):
   ```sh
   cat /boot.config
   # If this file contains "-D -h" or "-S 115200 -D -h" → serial is forced at boot loader level
   # This is a valid alternative to config.xml; OPNsense may create it
   ```
   If `/boot.config` is absent and config.xml is missing the stanza, the kernel defaults to VGA only.

**Resolution:** Ensure Ram's XML stanza (`<enableserial>1</enableserial>`, `<serialspeed>115200</serialspeed>`, `<primaryconsole>serial</primaryconsole>`) is present in `scripts/glb-config*.xml` AND that `configureopnsense.sh` ran to completion (sentinel `/var/run/opnsense-bootstrap-done` exists). A VM reboot is required after the XML is corrected for the serial console to activate (`az vm restart -g "$RG_PROVIDER" -n provider-nva-1`).

---

### Console appears to hang / no output after connect

1. Press **Enter** once — the console may be waiting for input.
2. Check if the VM is still booting: `az vm get-instance-view -g "$RG_PROVIDER" -n provider-nva-1 --query "instanceView.statuses[1].displayStatus" -o tsv`
3. If `VM running`, the OS is up. Try pressing `Ctrl+L` (clear screen) or `q` to dismiss any pager.
4. If `VM starting`, wait ~2 minutes and reconnect.
5. If `VM deallocated`, start the VM: `az vm start -g "$RG_PROVIDER" -n provider-nva-1`

### "Permission denied" when connecting

- Verify RBAC: you need at minimum `Virtual Machine Contributor` on the NVA or its resource group.
- Verify the extension is installed: `az extension show --name serial-console`
- Try re-adding: `az extension update --name serial-console`

### "Boot diagnostics not enabled" error

Run the enable command from [Enable Boot Diagnostics](#enable-boot-diagnostics-required-by-serial-console) above. Then reconnect.

### Console connects but keyboard input is not echoed (IME / terminal conflict)

The Azure serial console expects a raw terminal. If you are on Windows with an IME (Input Method Editor) active:
1. Disable the IME before connecting.
2. Use the Azure Portal browser-based serial console instead of the CLI.
3. On PowerShell / Windows Terminal: ensure `TERM=xterm` and use UTF-8 code page (`chcp 65001`).

### OPNsense menu appears but "8" (shell) hangs

- Type `8` and press Enter firmly. Sometimes the menu requires the Enter key explicitly.
- If it still hangs, try connecting from the Azure Portal serial console.
- As a last resort, use `az vm run-command` on the **consumer** VM (Ubuntu supports run-command) to verify network reachability from the consumer side, avoiding the NVA console entirely.

---

## Detaching Cleanly

To exit the serial console session without leaving the console in a broken state:

**Keyboard shortcut:** Press `Ctrl+]` (Control + right bracket)

This sends the telnet escape sequence and returns you to the local shell prompt without disturbing the running OPNsense session. The NVA continues running normally.

> ⚠️ Do NOT close the terminal window directly or press `Ctrl+C` — this may leave the serial port locked for 30–60 seconds before it times out on the Azure side.

---

*Cross-references: [boot-diagnostics.md](./boot-diagnostics.md) · [vxlan-proof.md](./vxlan-proof.md) · [../troubleshooting.md](../troubleshooting.md) · [../troubleshooting-freebsd-on-azure.md](../troubleshooting-freebsd-on-azure.md)*
