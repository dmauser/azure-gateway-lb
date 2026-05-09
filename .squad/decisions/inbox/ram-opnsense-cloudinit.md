# Ram Decision Drop — OPNsense Bootstrap via customData/cloud-init (Path D-proper)

**Author:** Ram (NVA / Scripts Engineer)  
**Date:** 2026-05-09T13:42:28-05:00  
**Trigger:** Quorra Round 3 blocker — `az vm run-command invoke` fails on FreeBSD 14.4 (Linux ELF binary in `RunCommandLinux` extension)  
**Deliverable:** `bicep/cloud-init/opnsense-bootstrap.yaml`

---

## What Shipped

### File: `bicep/cloud-init/opnsense-bootstrap.yaml`

A `#cloud-config` document for first-boot OPNsense provisioning on FreeBSD 14.4.

**Structure:**
- `hostname: __ROLE__-nva` — OS hostname set by cloud-init before runcmd
- `runcmd:` — 5 steps executed sequentially as root via `/bin/sh -c`:
  1. `hostname $(echo __ROLE__ | tr '[:upper:]' '[:lower:]')-nva` — lowercase override (produces `primary-nva` / `secondary-nva`)
  2. `/usr/bin/fetch -o /tmp/configureopnsense.sh '__URI__configureopnsense.sh'` — fetch script using FreeBSD base `fetch`
  3. `chmod +x /tmp/configureopnsense.sh`
  4. `/tmp/configureopnsense.sh '__URI__' '__ROLE__' '__LOCAL_CIDR__' '__PEER_IP__' 2>&1 | /usr/bin/tee /var/log/opnsense-bootstrap.log` — 4-arg invocation with persistent log
  5. `echo "bootstrap-ok-$(date -u +%Y%m%dT%H%M%SZ)" > /var/run/opnsense-bootstrap-done` — sentinel file

---

## Placeholder Contract for Clu

Clu performs mechanical `str.replace()` on these exact strings in the YAML before base64-encoding for `customData`:

| Placeholder | Type | Example | Notes |
|-------------|------|---------|-------|
| `__URI__` | string | `https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/` | Trailing slash required — script appends filename directly |
| `__ROLE__` | string | `Primary` or `Secondary` | Exact casing; appears 4× in YAML (comment, hostname:, 2 runcmd items) |
| `__LOCAL_CIDR__` | string | `10.0.1.4/24` | Full CIDR — `configureopnsense.sh` strips prefix internally via `cut -d'/' -f1` |
| `__PEER_IP__` | string | `10.0.1.5` | Bare IP, no mask |

**Occurrence counts after substitution check:**
- `__URI__`: 3× (1 comment + 2 runcmd)
- `__ROLE__`: 4× (1 comment + 1 hostname: + 2 runcmd)
- `__LOCAL_CIDR__`: 2× (1 comment + 1 runcmd)
- `__PEER_IP__`: 2× (1 comment + 1 runcmd)

---

## FreeBSD cloud-init Specifics Learned

| Topic | Finding |
|-------|---------|
| cloud-init availability | `thefreebsdfoundation/freebsd-14_4` ships cloud-init pre-installed and enabled (Azure-friendly publisher contract) |
| runcmd shell | `/bin/sh -c` as root — POSIX sh, not bash. `pipefail` not available. |
| HTTP fetch utility | `/usr/bin/fetch` (FreeBSD base). Not `curl`, not `wget`. Handles HTTPS. |
| tee utility | `/usr/bin/tee` (FreeBSD base) — safe in runcmd pipelines |
| `cloud-init status --wait` | Available (cloud-init is a Python port). Quorra can use this for smoke test polling. |
| Linux-only directives | `apt:`, `package_update:`, `packages:` are no-ops or errors on FreeBSD — omit entirely |
| Package installs | Use `pkg install -y <pkg>` inside `runcmd` if needed — NOT `packages:` directive |
| YAML quoting | Wrap runcmd items containing `$()`, `tr '[:upper:]' '[:lower:]'` in double quotes for safe YAML parse |
| Hostname casing | `hostname:` directive fires before runcmd; runcmd `hostname $(echo ROLE | tr ...)` cleanly overrides |
| Log location | `/var/log/opnsense-bootstrap.log` (script output via tee); `/var/log/cloud-init-output.log` (cloud-init native) |
| Sentinel pattern | `/var/run/opnsense-bootstrap-done` — last runcmd writes `bootstrap-ok-<ISO8601Z>` |

---

## Validation

```sh
# YAML parse (Python 3)
python -c "import yaml; yaml.safe_load(open('bicep/cloud-init/opnsense-bootstrap.yaml'))"
# Result: OK — keys: hostname, runcmd; runcmd count: 5

# Placeholder presence check
python -c "
content = open('bicep/cloud-init/opnsense-bootstrap.yaml').read()
for p in ['__URI__','__ROLE__','__LOCAL_CIDR__','__PEER_IP__']:
    print(p, content.count(p))
"
# __URI__ 3  __ROLE__ 4  __LOCAL_CIDR__ 2  __PEER_IP__ 2
```

---

## Coordination Notes for Clu

1. **File location:** `bicep/cloud-init/opnsense-bootstrap.yaml` — ready for `loadTextContent()`.
2. **Bicep wiring pattern:** Mirror consumer-vm.bicep: `customData: base64(loadTextContent('../../cloud-init/opnsense-bootstrap.yaml'))` — but Clu must do the 4 placeholder substitutions BEFORE base64. Use Bicep `replace()` chained or a Bicep variable that assembles the substituted string.
3. **URI trailing slash:** `configureopnsense.sh` concatenates filename directly to `$1` — caller MUST pass URI with trailing slash. Validate in Bicep parameter description.
4. **Role parameter:** Bicep param should be `'Primary'` or `'Secondary'` — passed as-is; `configureopnsense.sh` branches on exact string match.
5. **LocalCIDR:** Must be `<ip>/<prefix>` form — `get_nic_gw.py` (called inside the script) requires CIDR, not bare IP. Derive from NIC's allocated address + subnet prefix in Bicep.
6. **PeerIP:** Bare IP, no mask. The other NVA's private IP on the trusted subnet.
7. **OPNsense hostname:** The OPNsense config XML (not cloud-init) sets the definitive OPNsense UI hostname (`OPNsense-Primary` / `OPNsense-Secondary`) via sed substitution inside `configureopnsense.sh`. The cloud-init `hostname:` sets the OS-level hostname only.

---

## Post-Deploy Smoke Test for Quorra

After cloud-init completes (poll `cloud-init status --wait` or wait for `PowerState/running` + ~10 min):

```sh
# SSH to NVA (via bastion or jumpbox)
ssh <admin>@<nva-ip>

# 1. Check sentinel
cat /var/run/opnsense-bootstrap-done
# Expected: bootstrap-ok-<ISO8601Z>

# 2. Review bootstrap log
tail -50 /var/log/opnsense-bootstrap.log

# 3. cloud-init native status
cloud-init status --long

# 4. Verify OPNsense config was applied
cat /usr/local/etc/config.xml | grep hostname
# Expected: OPNsense-Primary or OPNsense-Secondary
```
