# Ram — History

## Project Context
- **Project:** azure-gateway-lb
- **User:** Daniel Mauser
- **Files owned:** `scripts/`, `linux-vxlan.azcli`

## Learnings

### 2026-05-08: NVA Scripts Audit - Repo Broken, Requires Consolidation

**Key Findings:**
- **Syntax errors** in configureopnsense.sh (line 21, likely CRLF/LF mismatch on Windows)
- **Three divergent versions** of deployment scripts with conflicting OPNsense (21.7 vs 25.1) and WALinuxAgent (v2.4.0.2 vs v2.12.0.4)
- **Missing XML configs** (config-snic.xml, config.xml) referenced but not in repo
- **Parameter mapping bug** in Primary server path: xxx.xxx.xxx.xxx (sync IP) never replaced by sed
- **VXLAN port persistence issue**: XML doesn't define vxlanlocalport/vxlanremoteport; only rc.syshook sets them (port 10800/10801, ID 800/801 are correct)
- **Duplicate/cruft files**: configureopnsense copy.sh, glb-config copy.xml, config-active-active-primary copy.xml should be deleted

**VXLAN Validation:** ✅ Ports and IDs correct (10800/10801 external, 10801 internal; IDs 800/801)

**Modernization Priorities:**
1. Fix bash syntax (line endings)
2. Consolidate to single configureopnsense.sh (v25.1)
3. Add VXLAN port definitions to XML (persistence concern)
4. Fix Primary server parameter contract and sync IP substitution
5. Add error handling (set -e, traps) to scripts
6. Document linux-vxlan.azcli purpose (currently appears to be manual vim tutorial, not runnable)

**aws-gateway-lb Pattern:** This repo mirrors a multi-NVA active-active GLB lab where two OPNsense instances inspect VXLAN-tunneled traffic from Azure GWLB. Firewall sync (HA state replication) is critical and currently broken due to parameter mapping issue.

### 2026-05-08: Phase 1 Script Fixes - COMPLETE

**Changes made:**
- Archived cruft files (`configureopnsense copy.sh`, `glb-config copy.xml`, `config-active-active-primary copy.xml`, `original.config.xml`) to `archived/scripts/` via `git mv`.
- Fixed CRLF line endings in `configureopnsense.sh` (was causing `bash: syntax error near unexpected token 'elif'` at line 21).
- Removed SingNic/TwoNics dead-code branches (referenced missing XML files).
- Collapsed asymmetric VXLAN if/elif into a single shared block.
- Removed duplicate `chmod +x` in Secondary branch.

**Canonical parameter contract for `configureopnsense.sh` (4 args, both roles):**

| Param | Meaning |
|-------|---------|
| `$1`  | URI prefix — base URL to fetch remote files from |
| `$2`  | Role — `"Primary"` or `"Secondary"` |
| `$3`  | Local NVA private IP **with CIDR** (e.g. `10.0.1.4/24`) |
| `$4`  | Peer NVA private IP (no CIDR) |

**XML placeholder mapping:**
- `yyy.yyy.yyy.yyy` → LAN gateway (derived from `$3` via `get_nic_gw.py`)
- `xxx.xxx.xxx.xxx` → peer IP / HA-sync target (`$4`, Primary XML only)
- `lll.lll.lll.lll` → this NVA's IP (IP portion of `$3`, CIDR stripped)
- `rrr.rrr.rrr.rrr` → peer IP (`$4`)

**Key pattern:** `get_nic_gw.py` takes an IP/CIDR string and returns the first host (gateway). So `$3` must always be `<ip>/<prefix>` form — not bare IP. Callers (Bicep/ARM customScriptExtension) must pass the NIC's full CIDR, not just the IP.

**Phase 2 remaining:** `set -e` + error traps, VXLAN port persistence in XML, version bumps, shellcheck CI.

---

## Phase 2 TODO: FreeBSD Image Migration (Cross-Team)

**Decision (Phase 0):** Migrate OPNsense images from MicrosoftOSTC FreeBSD 12.0 (EOL) to TheFreeBSDFoundation FreeBSD 14.4 (modern, maintained).

**Impact on Ram's scripts:** When Bicep templates are updated with new image publisher/sku, the OPNsense VM boot sequence and provisioning will change (FreeBSD 14.4 may have different system utilities, Python paths, WALinuxAgent behavior). Ram should:
- Verify `configureopnsense.sh` compatibility with FreeBSD 14.4 environment
- Test WALinuxAgent v2.12.0.4 (or newer) on FreeBSD 14.4
- Validate Python 3.11 availability in new OS image
- Ensure `get_nic_gw.py` runs correctly on FreeBSD 14.4

**Pending:** Clu to confirm OPNsense vendor support for FreeBSD 14.4 compatibility before Ram begins testing.
