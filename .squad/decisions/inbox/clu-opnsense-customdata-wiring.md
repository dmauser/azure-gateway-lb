# Clu Decision Drop — Path D-proper: OPNsense customData Wiring Shipped

**Author:** Clu (IaC Engineer)
**Date:** 2026-05-09T13:42:28-05:00
**Round:** 4 (addressing Quorra round 3 blocker)
**Commit:** `6f79ee2`
**Files changed:** `bicep/modules/VM/opnsense-vm-active-active.bicep`, `bicep/glb-active-active.bicep`, `bicep/glb-active-active.json`, `deploy.azcli`

---

## What Shipped

### Track 1 — Bicep customData Wiring

**`bicep/modules/VM/opnsense-vm-active-active.bicep`**
- Added parameters: `role string = ''`, `localIP string = ''`, `peerIP string = ''`, `bootstrapUri string = ''`, `customData string = ''`
- Added compile-time template load: `var cloudInitTemplate = loadTextContent('../../cloud-init/opnsense-bootstrap.yaml')`
- Added runtime substitution chain: `replace × 4` → `__URI__`, `__ROLE__`, `__LOCAL_CIDR__`, `__PEER_IP__`
- Wired `osProfile.customData: resolvedCustomData` (conditional: bootstrapUri → template path; else raw customData; else null)

**`bicep/glb-active-active.bicep`**
- Added `param bootstrapUri string = 'https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/'`
- Added VTEP IP derivation vars from `trustedSubnet.properties.addressPrefix` using `split` + `int` arithmetic
- Both `opnSensePrimary` and `opnSenseSecondary` module calls now pass: `role`, `localIP`, `peerIP`, `bootstrapUri`
- **Removed** outputs: `primaryTrustedIP`, `secondaryTrustedIP`, `trustedSubnetPrefix`
- **Removed** comment referencing `az vm run-command invoke` as bootstrap path

### Track 2 — deploy.azcli Rework

- **Added** `OPN_BOOTSTRAP_URI` env var (default: GitHub raw URL for scripts/)
- **Added** `bootstrapUri="$OPN_BOOTSTRAP_URI"` to `az deployment group create --parameters`
- **Deleted** step 3 in entirety:
  - `opn_script_uri` variable
  - Both `az deployment group show` output queries
  - Both `az vm run-command invoke` blocks (parallel `&` + `wait`)
  - 90 s grace sleep + 20×30 s restart poll loop
- Renumbered step 4 Bastion → step 3

---

## Bicep Build Evidence

```
$ az bicep build --file bicep/glb-active-active.bicep
WARNING: A new Bicep release is available: v0.43.8.
EXIT: 0
```

Zero errors. The upgrade-available warning is from `az` CLI, not a Bicep compilation error — same pre-existing warning as baseline.

```
$ bash -n deploy.azcli
EXIT: 0
```

---

## Path D-prime Artifact Verification

| Artifact | Status |
|---|---|
| `az vm run-command invoke` in deploy.azcli | ✅ GONE |
| `primaryTrustedIP` Bicep output | ✅ GONE |
| `secondaryTrustedIP` Bicep output | ✅ GONE |
| `trustedSubnetPrefix` Bicep output | ✅ GONE |
| Restart-wait poll loop | ✅ GONE |
| `opn_script_uri` variable | ✅ GONE |

---

## Coordination Outcome with Ram

Ram's `bicep/cloud-init/opnsense-bootstrap.yaml` was already present and committed (Ram authored it in parallel per squad plan). Placeholder contract matched exactly:

| Placeholder | Clu substitution source |
|---|---|
| `__URI__` | `bootstrapUri` param |
| `__ROLE__` | `'Primary'` / `'Secondary'` literal |
| `__LOCAL_CIDR__` | `primaryLocalIP` / `secondaryLocalIP` (base+4/5 VTEP, /24 mask) |
| `__PEER_IP__` | `primaryPeerIP` / `secondaryPeerIP` |

---

## IP Derivation Approach

Trusted subnet prefix (e.g. `10.0.0.32/27`) → VTEP IPs via Bicep `split` + `int` arithmetic:
- Primary: `localIP = 10.0.0.36/24`, `peerIP = 10.0.0.37`
- Secondary: `localIP = 10.0.0.37/24`, `peerIP = 10.0.0.36`

Chosen over `cidrHost()` for Bicep version portability.

---

## Next Action

**Quorra:** Round 4 deploy. Watch for:
- Both OPNsense NVAs deploying without error
- cloud-init / bsdcloudinit completing bootstrap at first boot
- Sentinel file `/var/run/opnsense-bootstrap-done` present on both NVAs (SSH check)
- GLB chain established (gate 3f)
- VXLAN traffic flowing through OPNsense (gate 3g)
