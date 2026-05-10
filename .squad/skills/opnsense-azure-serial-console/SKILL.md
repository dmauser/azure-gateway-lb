# SKILL: OPNsense Azure Serial Console

**Category:** NVA / OPNsense XML Configuration  
**Applies to:** OPNsense on Azure (FreeBSD-based); `az serial-console connect`  
**Reference implementation:** `dmauser/opnazure` commit `7a16066`

---

## Problem

`az serial-console connect` attaches to the VM's COM1 port but shows no output because OPNsense defaults to VGA-only console output. The FreeBSD kernel must be instructed to also send console I/O to ttyS0 (serial).

---

## Canonical XML Pattern

Add these three elements inside the `<system>` block of every OPNsense `config.xml`:

```xml
<!-- Azure serial console: serialspeed matches Azure's 115200 baud requirement.
     primaryconsole=video keeps VGA for local/Bastion access.
     secondaryconsole=serial multiplexes output to ttyS0 for az serial-console connect.
     Reference: dmauser/opnazure scripts/config.xml lines 244-246 -->
<serialspeed>115200</serialspeed>
<primaryconsole>video</primaryconsole>
<secondaryconsole>serial</secondaryconsole>
```

### Element semantics

| Element | Value | Effect |
|---------|-------|--------|
| `<serialspeed>` | `115200` | Baud rate — must match Azure Serial Console's fixed 115200 baud |
| `<primaryconsole>` | `video` | VGA stays primary; interactive boot menu visible on hypervisor video |
| `<secondaryconsole>` | `serial` | OPNsense/FreeBSD multiplexes all console output to COM1 (ttyS0) |

### Placement

Place the stanza after `<sudo_allow_wheel>` and before `<ssh>` — consistent with all known working configs:

```xml
<sudo_allow_wheel>1</sudo_allow_wheel>
<serialspeed>115200</serialspeed>
<primaryconsole>video</primaryconsole>
<secondaryconsole>serial</secondaryconsole>
<ssh>
  ...
</ssh>
```

---

## What NOT to use

- `<enableserial>1</enableserial>` — **not required**; not present in the reference repo; may be vestigial from older OPNsense versions.
- `/boot.config` with `-D -h` — **not required** for this pattern. The `<secondaryconsole>serial</secondaryconsole>` XML element is sufficient. OPNsense translates this to the appropriate FreeBSD `comconsole` tunable at config-import time.
- `<primaryconsole>serial</primaryconsole>` — works but disables VGA; prefer `video` primary + `serial` secondary for dual-console (matches dmauser/opnazure working reference).

---

## FreeBSD / OPNsense Mechanics

OPNsense's `system_console_configure()` PHP function reads `<primaryconsole>` and `<secondaryconsole>` from config and writes the appropriate entries to `/boot/loader.conf`. When `secondaryconsole=serial`:

- FreeBSD boot loader: `comconsole_speed=115200` and `console="vidconsole,comconsole"` (dual output)
- Kernel: all `printf`/`kprintf` output goes to both framebuffer and COM1
- Azure hypervisor captures COM1 → exposes via Serial Console endpoint

This is why `az serial-console connect` works: Azure's serial console service is permanently attached to COM1 on the hypervisor side; the guest just needs to be writing to it.

---

## Verification

After deployment, connect via Azure Serial Console:

```bash
az serial-console connect \
  --resource-group <rg> \
  --name <vm-name>
```

**Expected:** OPNsense login prompt within 30 seconds. If blank:
1. Confirm `<secondaryconsole>serial</secondaryconsole>` is in the active `/conf/config.xml` on the VM.
2. Confirm `serialspeed` is `115200` (not 9600 or 38400).
3. Run `sudo /usr/local/sbin/opnsense-shell` → `Console` → confirm Serial is listed.

---

## XML Validation Command

```bash
python -c "import xml.etree.ElementTree as ET; ET.parse('scripts/glb-config.xml'); print('OK')"
```

Run after every XML edit. Exit 0 = parse OK.

---

## Source Files in This Repo

- `scripts/glb-config.xml` — single/secondary role config
- `scripts/glb-config-active-active-primary.xml` — primary role config

Both contain the canonical pattern as of 2026-05-09.
