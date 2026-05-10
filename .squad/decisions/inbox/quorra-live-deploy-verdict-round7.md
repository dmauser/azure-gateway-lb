# Quorra — Live Deploy Verdict: Round 7

**Date:** 2026-05-10T22:00:00Z  
**Deploy Attempt:** Round 7 (FreeBSD 14.1 + CSE v1.5 pivot)  
**Environment:** MSDN_Dmauser / westus3  
**RGs:** rg-glb-consumer-quorra, rg-glb-provider-quorra  
**Commit at deploy:** post-commit fixes applied in-session  

---

## Gate Summary

| Gate | Result | Evidence |
|------|--------|----------|
| 3a Consumer VM running | ✅ PASS | `PowerState/running` |
| 3b Consumer cloud-init / nginx | ✅ PASS | `status: done`, nginx active |
| 3c nginx direct (pre-chain) | ✅ PASS | `curl http://172.182.235.76` → `Test Website on consumer-vm` |
| 3d Consumer Trusted Launch | ✅ PASS | `securityType: TrustedLaunch`, `secureBootEnabled: true`, `vTpmEnabled: true` |
| 3e OPNsense securityProfile null | ✅ PASS | Both NVAs: `securityProfile: null` |
| 3f GLB chain established | ✅ PASS | `gatewayLoadBalancer.id` = GLB FW resource ID |
| 3c (via GLB chain) | ✅ PASS | `curl http://172.182.235.76` → `Test Website on consumer-vm` (exit 0, 5× confirmed) |
| 3g VXLAN tcpdump evidence | ✅ PASS | Bidirectional VXLAN captured — see below |
| 3h Bootstrap evidence | ✅ PASS | OPNsense 25.1.12 on both NVAs; CSE v1.5 delivered configureopnsense.sh |

**Overall verdict: ✅ PASS — all 9 gates green**

---

## VXLAN Tcpdump Evidence (Daniel's hard requirement)

Captured on primary NVA (10.0.0.37) interface `hn1` during live curl requests:

```
21:51:36.707724 IP 10.0.0.36.56020 > 10.0.0.37.10801: UDP, length 66   ← GLB→NVA inbound (glbext)
21:51:36.707802 IP 10.0.0.37.8267  > 10.0.0.36.10800: UDP, length 66   ← NVA→GLB bounce (glbint)
21:51:41.331769 IP 10.0.0.36.47556 > 10.0.0.37.10801: UDP, length 74   ← GLB→NVA inbound
21:51:41.331863 IP 10.0.0.37.10451 > 10.0.0.36.10800: UDP, length 74   ← NVA→GLB bounce
21:51:41.334785 IP 10.0.0.36.64246 > 10.0.0.37.10800: UDP, length 74   ← GLB→NVA outbound (glbint)
21:51:41.334814 IP 10.0.0.37.59672 > 10.0.0.36.10801: UDP, length 74   ← NVA→GLB bounce (glbext)
21:51:41.374965 IP 10.0.0.36.47556 > 10.0.0.37.10801: UDP, length 62   ← GLB→NVA inbound
21:51:41.374988 IP 10.0.0.36.47556 > 10.0.0.37.10801: UDP, length 140  ← GLB→NVA (HTTP data)
21:51:41.375027 IP 10.0.0.37.10451 > 10.0.0.36.10800: UDP, length 62   ← NVA→GLB bounce
21:51:41.375029 IP 10.0.0.37.10451 > 10.0.0.36.10800: UDP, length 140  ← NVA→GLB bounce
10 packets captured
```

- Port 10801 = VNI 801 (`glbext`) — GLB sends inbound traffic TO NVA
- Port 10800 = VNI 800 (`glbint`) — NVA bounces BACK to GLB; also used for outbound path
- Fully bidirectional VXLAN confirmed ✅

---

## Findings (P1 Bugs Found and Fixed)

### Finding 1 — `/24` hardcoded CIDR prefix in Bicep (Root Cause #1)

**File:** `bicep/glb-active-active.bicep` line 131  
**Bug:** `var primaryLocalIP = '.../24'` hardcoded prefix instead of deriving from subnet  
**Impact:** `get_nic_gw.py('10.0.0.37/24')` computed gateway = 10.0.0.1 (network base of /24).  
Actual gateway for 10.0.0.32/27 = 10.0.0.33. pfctl `reply-to` used wrong gateway → probe traffic replied on wrong interface.  
**Fix applied:** Added `var trustedPrefix = split(trustedSubnet.properties.addressPrefix, '/')[1]`  
and changed both `primaryLocalIP` and `secondaryLocalIP` to use `/${trustedPrefix}`.  
**Manual workaround during session:** Edited config.xml + rules.debug on both NVAs to set LAN_GW=10.0.0.33.

### Finding 2 — syshook ordering (Root Cause #2) — ALREADY CORRECT

**Assessment:** The summary described a syshook ordering bug, but inspection of `configureopnsense.sh` shows syshooks ARE written AFTER `sh ./opnsense-bootstrap.sh.in` (lines 131-148 come after line 110). Ordering is correct; this was a mischaracterisation. No fix needed.

### Finding 3 — vxlanremote = peer NVA IP instead of GLB frontend IP (Root Cause #3)

**Files:** `scripts/glb-config-active-active-primary.xml`, `scripts/glb-config.xml`, `scripts/configureopnsense.sh`  
**Bug:** `rrr.rrr.rrr.rrr` placeholder substituted with `$4` = peer NVA IP (e.g., 10.0.0.38).  
Azure GLB sends VXLAN from its frontend IP (10.0.0.36), and NVAs must send VXLAN BACK to 10.0.0.36.  
FreeBSD VXLAN with `vxlanremote = 10.0.0.38` sent VXLAN to the wrong destination; GLB ignored it.  
**Impact:** curl via GLB chain timed out. Inbound VXLAN decapsulated correctly, but return path silently black-holed.  
**Fix applied:**  
- Added `var glbFrontendIP = '${ipBase3}.${string(int(trustedOctets[3]) + 4)}'` in Bicep  
- Added `param glbIP string = ''` to `opnsense-vm-active-active.bicep`  
- Updated CSE `commandToExecute` to pass `${glbIP}` as `$5`  
- Changed all `rrr.rrr.rrr.rrr` sed substitutions in `configureopnsense.sh` to use `$5`  
- Changed 25-azure syshook `vxlanremote` from `$4` to `$5`  
**Manual workaround during session:** `service configd stop` then `ifconfig vxlanX vxlanremote 10.0.0.36` on both NVAs.

### Finding 4 — pfil_member=1 blocks bridge member pf filtering (Root Cause #4)

**File:** `scripts/configureopnsense.sh` (missing sysctl)  
**Bug:** FreeBSD default `net.link.bridge.pfil_member=1` enables pf filtering on vxlan0/vxlan1 (bridge members).  
No pf rules exist for VXLAN interfaces → default deny drops all bridged VXLAN traffic.  
`net.link.bridge.pfil_bridge=0` (bridge-level filtering) was already off; the member-level was the issue.  
**Impact:** Even with correct vxlanremote, tcpdump on vxlan1 showed no inner frames until this was fixed.  
**Fix applied:**  
- Added `sysctl net.link.bridge.pfil_member=0` to the 25-azure syshook  
- Added `echo "net.link.bridge.pfil_member=0" >> /etc/sysctl.conf` for persistence across reboots  
**Manual workaround during session:** `sysctl net.link.bridge.pfil_member=0` on both NVAs.

### Finding 5 — OPNsense configd continuously resets vxlan remotes (Root Cause #5)

**Root cause (observed, not directly fixed in source):** OPNsense `configd` daemon owns vxlan interface config.  
When vxlan interfaces are manipulated via `ifconfig`, configd detects state changes and re-applies from config.xml.  
After fixing config.xml via `sed -i.bak`, configd overwrote it back from its in-memory state.  
**Impact:** Manual vxlanremote fixes were reversed within seconds.  
**Resolution:**  
- Root cause #3 fix (using correct GLB IP in config.xml via `$5`) is the proper permanent fix.  
- configd is the OPNsense-blessed way to manage vxlan config; the fix is to give it correct data.  
- At boot, configd reads config.xml (which will have correct `rrr.rrr.rrr.rrr` → GLB IP substitution).  
- The 25-azure syshook also sets vxlanremote correctly as a secondary safeguard.  
**Manual workaround during session:** `service configd stop` on both NVAs, then re-apply ifconfig.

---

## Architecture Confirmed

Azure GLB VXLAN flow (end-to-end verified):

```
curl → Consumer ELB (172.182.235.76) → GLB frontend (10.0.0.36)
  → NVA vxlan1 [port 10801, VNI 801] (GLB→NVA inbound encapsulated)
  → bridge0 (NVA internal bridge)
  → NVA vxlan0 [port 10800, VNI 800] (NVA→GLB bounce)
  → GLB → Consumer ELB → consumer-vm (10.x.x.x)
  ← reverse path symmetric
```

- Primary NVA trusted IP: 10.0.0.37 (`hn1`)
- Secondary NVA trusted IP: 10.0.0.38 (`hn1`)
- GLB frontend IP: 10.0.0.36 (subnet 10.0.0.32/27, first usable = base+4)

---

## Source Code Fixes Applied This Round

| File | Change | Bug Fixed |
|------|--------|-----------|
| `bicep/glb-active-active.bicep` | Added `trustedPrefix` + `glbFrontendIP` vars; fixed `/24` → `/${trustedPrefix}` | #1 CIDR prefix |
| `bicep/glb-active-active.bicep` | Pass `glbIP: glbFrontendIP` to both NVA module calls | #3 vxlanremote |
| `bicep/modules/VM/opnsense-vm-active-active.bicep` | Added `param glbIP`; updated `commandToExecute` to pass `$5` | #3 vxlanremote |
| `scripts/configureopnsense.sh` | Changed `rrr.rrr.rrr.rrr` sed to use `$5`; changed syshook vxlanremote to `$5`; added `pfil_member=0` to syshook + sysctl.conf | #3 vxlanremote, #4 pfil_member |
| `scripts/configureopnsense.sh` | Updated parameter docs (`$5` = GLB frontend IP) | documentation |

**Bicep build after changes:** exit 0, 0 errors ✅

---

## Deployment Variables (Round 7)

- Consumer ELB PIP: `172.182.235.76`
- Provider ELB PIP: `57.154.10.156`
- GLB frontend IP: `10.0.0.36` (private, trusted subnet 10.0.0.32/27)
- GLB frontend resource ID: `/subscriptions/36ead89c-e817-4abc-ae66-5d29d23995bb/resourceGroups/rg-glb-provider-quorra/providers/Microsoft.Network/loadBalancers/provider-nva-glb/frontendIPConfigurations/FW`

---

## Open Items / Recommended Follow-up

1. **Cleanup:** Delete NAT rules `primary-nva-ssh` and `secondary-nva-ssh` from `provider-nva-elb`; delete both RGs when Daniel is satisfied.
2. **Reboot test:** Round 7 fixes were applied manually; source code fixes are in place but not deployed fresh. A Round 8 clean deploy (no manual intervention) should be run to confirm all 5 bugs are fixed end-to-end automatically.
3. **configd management:** Consider adding `service configd stop` + correct vxlanremote check to the 25-azure syshook as a defense against configd interfering. Alternatively, verify configd correctly picks up the new config.xml values on a clean boot.
4. **Static ARP for GLB frontend:** In the live session, VXLAN to 10.0.0.36 worked without a static ARP entry (Azure virtual network resolved MAC normally). No action needed.
