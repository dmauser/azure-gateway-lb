# SKILL: OPNsense XML VXLAN Port Persistence

**Category:** NVA / OPNsense Configuration  
**Applies to:** OPNsense 24.x / 25.x XML config templates

---

## Problem

OPNsense VXLAN interfaces configured with non-standard ports (e.g., 10800/10801 instead of the default 4789) lose their port settings after an OPNsense config reload if those ports are not declared in the XML config. Relying solely on `rc.syshook` boot hooks is fragile: the hooks run once at boot, but OPNsense config reloads (e.g., after GUI changes) will re-apply the XML and overwrite the interface settings.

---

## Solution

Declare `<vxlanlocalport>` and `<vxlanremoteport>` explicitly inside each `<vxlan>` block in the OPNsense XML config. This ensures the correct ports survive both reboots and config reloads.

### XML structure

Under `<OPNsense><vlans>` → `<vxlans version="1.0.1">` → each `<vxlan>` child:

```xml
<vxlans version="1.0.1">
  <vxlan uuid="...">
    <deviceid>vxlan0</deviceid>
    <vxlanid>800</vxlanid>
    <vxlanlocal>LOCAL_IP_PLACEHOLDER</vxlanlocal>
    <vxlanremote>PEER_IP_PLACEHOLDER</vxlanremote>
    <vxlanlocalport>10800</vxlanlocalport>   <!-- ADD THIS -->
    <vxlanremoteport>10800</vxlanremoteport> <!-- ADD THIS -->
    <vxlangroup/>
    <vxlandev/>
  </vxlan>
  <vxlan uuid="...">
    <deviceid>vxlan1</deviceid>
    <vxlanid>801</vxlanid>
    <vxlanlocal>LOCAL_IP_PLACEHOLDER</vxlanlocal>
    <vxlanremote>PEER_IP_PLACEHOLDER</vxlanremote>
    <vxlanlocalport>10801</vxlanlocalport>   <!-- ADD THIS -->
    <vxlanremoteport>10801</vxlanremoteport> <!-- ADD THIS -->
    <vxlangroup/>
    <vxlandev/>
  </vxlan>
</vxlans>
```

### Placement rule

Insert port tags **after** `<vxlanremote>` and **before** `<vxlangroup/>`. OPNsense parses sibling tags in the `<vxlan>` block order-independently, but keeping them adjacent to `<vxlanlocal>`/`<vxlanremote>` is conventional.

---

## Port assignment for Azure GLB pattern

| Interface | `<vxlanid>` | Role | Local port | Remote port |
|-----------|-------------|------|------------|-------------|
| vxlan0 | 800 | Internal (GLB ↔ NVA) | 10800 | 10800 |
| vxlan1 | 801 | External (NVA ↔ backend) | 10801 | 10801 |

---

## Defence in depth: keep rc.syshook too

Even with XML port tags, keep the `rc.syshook` `25-azure` boot hook as a secondary safeguard. It ensures the correct `ifconfig vxlan* vxlanlocalport … vxlanremoteport …` commands run at boot, which covers edge cases where the XML isn't applied before networking starts.

---

## References

- `scripts/glb-config.xml` — Secondary NVA config template
- `scripts/glb-config-active-active-primary.xml` — Primary NVA config template
- `scripts/configureopnsense.sh` — Script that applies sed substitutions and deploys the XML
- Phase 2 decision drop: `.squad/decisions/inbox/ram-phase2-scripts.md`
