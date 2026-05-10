# SKILL: VXLAN tcpdump Proof — Packet-Level Verification for Tunneled Traffic

**Category:** Network Verification / Debug  
**Applies to:** Azure Gateway Load Balancer (GLB) + OPNsense VXLAN tunnels; generalizes to any VXLAN-over-UDP scenario  
**Author:** Dumont (Operations / Debug Specialist) — 2026-05-09T19:20:21-05:00  
**Full runbook:** `docs/debug/vxlan-proof.md`

---

## Problem

After deploying an Azure GLB with VXLAN-encapsulated NVAs, "it seems to work" (HTTP 200) is insufficient evidence. Need **packet-level proof** that:
1. The GLB is actually encapsulating traffic in VXLAN (not just bypassing the NVA)
2. The NVA is receiving, decapsulating, inspecting, and re-encapsulating traffic
3. The correct VNI and ports are in use

---

## Canonical Two-Terminal Procedure

### Terminal A — NVA shell (serial console or SSH)

```sh
# Capture 10 VXLAN packets on any interface, skip health-probe keep-alives
tcpdump -nn -i any "udp port 10800 or udp port 10801 and greater 100" -c 10
```

### Terminal B — Workstation

```bash
# Generate traffic through the GLB chain
CONSUMER_PIP=$(az network public-ip show \
  -g "$RG_CONSUMER" -n consumer-elb-pip \
  --query ipAddress -o tsv)

curl http://$CONSUMER_PIP
```

---

## What Proves VXLAN is Working

All four of these must appear in tcpdump output:

| Signal | tcpdump line pattern | Meaning |
|--------|---------------------|---------|
| GLB sending VXLAN inbound | `168.63.129.16.10800 > 10.0.1.x.10800` | GLB encapsulating traffic to NVA |
| NVA decapsulating inbound | `vxlan0 In  IP <client> > <dest>` | Inner frame visible on VXLAN iface |
| NVA sending VXLAN return | `10.0.1.x.10801 > 168.63.129.16.10801` | NVA returning traffic to GLB |
| NVA encapsulating outbound | `vxlan1 Out IP <dest> > <client>` | Return inner frame leaving via VXLAN |

**If only health probes appear** (small UDP, ~60 bytes) but no inner frames → GLB health probe passing, but NVA is not processing real traffic. Generate traffic in Terminal B.

**If curl returns 200 but no VXLAN packets** → GLB chain is NOT active. Traffic went consumer-elb → consumer-vm directly (bypassing NVA). Verify `az network lb frontend-ip show --query gatewayLoadBalancer.id`.

---

## Azure GLB VXLAN Constants (this lab)

| Constant | Value | Source |
|----------|-------|--------|
| Inbound UDP port | `10800` | Bicep / OPNsense XML |
| Outbound UDP port | `10801` | Bicep / OPNsense XML |
| Inbound VNI | `800` | OPNsense XML |
| Outbound VNI | `801` | OPNsense XML |
| GLB source IP | `168.63.129.16` | Azure platform constant |
| GLB peer MAC | `12:34:56:78:9a:bc` | Azure platform constant |

---

## Filter Refinements

```sh
# Skip keep-alives (less than 100 bytes UDP payload)
tcpdump -nn -i any "udp port 10800 or udp port 10801 and greater 100" -c 10

# Show only inner TCP frames (de-encapsulated)
tcpdump -nn -i vxlan0 tcp -c 10

# Verbose mode — shows VNI explicitly
tcpdump -nn -i hn0 -v "udp port 10800 or udp port 10801" -c 5
# Look for: VXLAN, flags [I] (0x08), vni 800
```

---

## Proof Discipline (generalizes beyond this lab)

This discipline applies to any scenario with tunneled/encapsulated traffic:

1. **Never declare success from the application layer alone.** HTTP 200 can arrive via a bypass path.
2. **Always verify at the encapsulation layer.** tcpdump on the NVA's physical NIC confirms the tunnel is being used.
3. **Always verify at the de-encapsulation layer.** tcpdump on the VXLAN interface confirms the NVA is actually seeing and processing inner frames.
4. **Use packet counts, not just presence.** `tcpdump ... -c N` captures exactly N packets — if it exits with fewer, traffic is not flowing.
5. **Filter out control/health traffic.** GLB health probes generate constant UDP noise. Use `and greater 100` to isolate data-bearing frames.

---

## Source

Derived from Daniel Mauser's directive on `dmauser/azure-gateway-lb` — Round 6 debug session 2026-05-09. The insight: GLB round-trips are invisible to application-layer tests. Only packet capture on the NVA interface stack provides irrefutable proof.
