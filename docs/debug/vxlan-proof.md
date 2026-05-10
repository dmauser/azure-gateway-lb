# VXLAN Proof Runbook — Packet-Level Verification

**Scope:** Proving VXLAN traffic is actually flowing between the Azure Gateway Load Balancer and the OPNsense NVAs.  
**Daniel's directive:** *"Inferred end-to-end is not enough. He wants packet-level proof."*  
**Author:** Dumont (Operations / Debug Specialist) — 2026-05-09T19:20:21-05:00  
**See also:** [serial-console.md](./serial-console.md) · [boot-diagnostics.md](./boot-diagnostics.md) · [../troubleshooting.md](../troubleshooting.md)

---

## Table of Contents

- [Architecture Context](#architecture-context)
- [Prerequisites — NVA Access](#prerequisites--nva-access)
- [Step-by-Step: Packet Capture Procedure](#step-by-step-packet-capture-procedure)
- [Interpreting tcpdump Output](#interpreting-tcpdump-output)
- [OPNsense Web UI Access](#opnsense-web-ui-access)
- [Smoke Test Bundle — 30-Second Confirmation](#smoke-test-bundle--30-second-confirmation)
- [Troubleshooting VXLAN Failures](#troubleshooting-vxlan-failures)

---

## Architecture Context

The Azure Gateway Load Balancer (GLB) encapsulates traffic in VXLAN before forwarding to the OPNsense NVAs:

```
Internet client
      │ HTTP request
      ▼
consumer-elb (Standard LB, Public IP)
      │ GLB-chained frontend — VXLAN encapsulation added
      ▼
provider-nva-glb (Gateway LB, SKU=Gateway)
      │ VXLAN UDP 10800 → NVA trusted IP (10.0.1.4 or 10.0.1.5)
      ▼
OPNsense NVA (provider-nva-1 or provider-nva-2)
      │ Inspect / filter traffic
      │ VXLAN UDP 10801 → GLB return path
      ▼
provider-nva-glb (return)
      │ De-encapsulates VXLAN
      ▼
consumer-elb → consumer-vm (nginx)
```

### VXLAN port / VNI mapping

| Interface | Direction | UDP Port | VNI | Azure-side entity |
|-----------|-----------|----------|-----|-------------------|
| `vxlan0` | Inbound (GLB → NVA) | 10800 | 800 | External (Internet → consumer) |
| `vxlan1` | Outbound (NVA → GLB) | 10801 | 801 | Internal (consumer → backend) |

**Azure GLB source IP:** `168.63.129.16` (the Azure platform wire server / health probe IP)  
**Hardcoded peer MAC:** `12:34:56:78:9a:bc` (Azure GLB VIP MAC — OPNsense uses this as the remote MAC for VXLAN)

> ℹ️ These values are hardcoded in the OPNsense XML config applied by `configureopnsense.sh`. They match the Azure GLB design specification and should not be changed.

---

## Prerequisites — NVA Access

You need a shell on one OPNsense NVA. Two paths:

### Path A: Serial console (out-of-band — always available)

```bash
export SUBSCRIPTION_ID="<your-subscription-id>"
export RG_PROVIDER="rg-glb-provider-quorra"

az serial-console connect \
  -g "$RG_PROVIDER" \
  -n provider-nva-1 \
  --subscription "$SUBSCRIPTION_ID"
```

At the OPNsense menu: press `8` for shell.  
Full procedure: [serial-console.md](./serial-console.md)

### Path B: SSH via Azure Bastion

If Bastion was deployed (`BASTION_DEPLOY=true` in deploy.azcli):

```bash
az network bastion ssh \
  -g "$RG_CONSUMER" \
  -n consumer-bastion \
  --target-resource-id "$(az vm show -g $RG_PROVIDER -n provider-nva-1 --query id -o tsv)" \
  --auth-type password \
  --username root
```

### Path C: SSH via NAT rule (if port 22 NAT rule exists)

The default Bicep only exposes port 443 (NAT 50443→443 and 50444→443) on `provider-nva-elb`. There is **no port 22 NAT rule by default**. If one was added:

```bash
NVA_ELB_PIP=$(az network public-ip show \
  -g "$RG_PROVIDER" \
  -n provider-nva-elb-pip \
  --query ipAddress -o tsv)

ssh root@"$NVA_ELB_PIP" -p 50022   # if custom NAT rule added
```

---

## Step-by-Step: Packet Capture Procedure

This is the canonical procedure for proving VXLAN works end-to-end.

### Session layout

You need **two terminal windows** (or tmux panes):

- **Terminal A:** NVA shell (serial console or SSH)
- **Terminal B:** Operator workstation or any machine with internet access to send traffic

### Step 1 — Get the consumer ELB public IP (Terminal B)

```bash
CONSUMER_PIP=$(az network public-ip show \
  -g "$RG_CONSUMER" \
  -n consumer-elb-pip \
  --query ipAddress \
  -o tsv)
echo "Consumer ELB PIP: $CONSUMER_PIP"
```

### Step 2 — Start the packet capture (Terminal A — NVA shell)

```sh
# On the OPNsense NVA (from Option 8 shell or SSH)
# Capture 10 VXLAN packets on any interface
tcpdump -nn -i any "udp port 10800 or udp port 10801" -c 10
```

Leave this running — it will block until 10 packets arrive.

**Alternative filter to skip GLB health-probe keep-alives** (which are small UDP datagrams):

```sh
# Filter out keep-alives (UDP length <= 100 bytes) — only show real encapsulated frames
tcpdump -nn -i any "udp port 10800 or udp port 10801 and greater 100" -c 10
```

### Step 3 — Generate traffic (Terminal B — workstation)

While the tcpdump is running on the NVA, send HTTP requests through the GLB chain:

```bash
# Send 5 HTTP requests to the consumer ELB (routed via GLB → NVA → consumer-vm nginx)
for i in $(seq 1 5); do
  curl -s -o /dev/null -w "Request $i: HTTP %{http_code} in %{time_total}s\n" \
    "http://$CONSUMER_PIP"
  sleep 1
done
```

### Step 4 — Observe tcpdump output (Terminal A)

The tcpdump should capture and print packets. Move to [Interpreting tcpdump Output](#interpreting-tcpdump-output).

### Step 5 — Record evidence

Save the tcpdump output as proof:

```sh
# On the NVA — capture 20 packets, write to file, also print to console
tcpdump -nn -i any "udp port 10800 or udp port 10801 and greater 100" -c 20 \
  -w /tmp/vxlan-capture.pcap \
  2>&1 | tee /tmp/vxlan-capture.txt

cat /tmp/vxlan-capture.txt
```

---

## Interpreting tcpdump Output

### Expected output — healthy VXLAN flow

```
tcpdump: verbose output suppressed, use -v or -vv for full protocol decode
listening on any, link-type LINUX_SL2 (Linux cooked v2), capture size 262144 bytes

# Inbound: GLB → NVA (VXLAN encapsulated, UDP port 10800, VNI 800)
19:20:21.123456 hn0   In  IP 168.63.129.16.10800 > 10.0.1.4.10800: UDP, length 154
19:20:21.123500 vxlan0 In  IP <client-ip>.54321 > <consumer-elb-pip>.80: TCP Flags [S], seq 12345, ...

# Outbound: NVA → GLB (VXLAN encapsulated, UDP port 10801, VNI 801)
19:20:21.125000 hn0   Out IP 10.0.1.4.10801 > 168.63.129.16.10801: UDP, length 66
19:20:21.125100 vxlan1 Out IP <consumer-elb-pip>.80 > <client-ip>.54321: TCP Flags [S.], seq 98765, ...

10 packets captured
10 packets received by filter
0 packets dropped by kernel
```

### What each line tells you

| Element | Example value | Meaning |
|---------|--------------|---------|
| Interface `hn0` | `hn0 In` | Packet arrived on the physical NIC (WAN/untrusted) |
| Source IP `168.63.129.16` | `168.63.129.16.10800` | Azure GLB platform IP — this IS the GLB encapsulating traffic |
| Destination IP | `10.0.1.4.10800` | NVA's trusted-subnet IP, port 10800 = VXLAN inbound tunnel |
| Interface `vxlan0` | `vxlan0 In` | De-encapsulated inner frame seen on VXLAN interface — **this proves the VXLAN tunnel is working** |
| Inner frame | `<client-ip>.N > <consumer-pip>.80` | Original HTTP request — GLB decapsulated and forwarded |
| Interface `hn0 Out` | `hn0 Out` | Return packet leaving the physical NIC |
| Destination `168.63.129.16.10801` | port 10801 | VXLAN return tunnel to GLB |
| Interface `vxlan1` | `vxlan1 Out` | Inner return frame leaving via VXLAN return path |

### Proof checklist — declare VXLAN working when ALL of these are true

- [ ] Lines with `168.63.129.16 > 10.0.1.x:10800` appear (GLB is sending VXLAN to NVA)
- [ ] Lines with `vxlan0` appear (NVA is decapsulating inbound VXLAN)
- [ ] Lines with `10.0.1.x > 168.63.129.16:10801` appear (NVA is sending VXLAN back to GLB)
- [ ] Lines with `vxlan1` appear (NVA is encapsulating outbound VXLAN)
- [ ] `curl http://$CONSUMER_PIP` returns HTTP 200 with nginx HTML

### If tcpdump output is overwhelming (health probe flood)

The Azure GLB sends constant UDP health probes sourced from `168.63.129.16`. If these flood the output:

```sh
# Exclude small health-probe-sized UDP (≤ 100 bytes) — only show real data frames
tcpdump -nn -i any \
  "udp port 10800 or udp port 10801" \
  and "udp[8:2] > 100" \
  -c 10
```

Or filter to only show the inner HTTP frames on the vxlan interfaces:

```sh
# Show only de-encapsulated TCP frames on VXLAN interfaces (port 80 or any)
tcpdump -nn -i vxlan0 tcp -c 10
tcpdump -nn -i vxlan1 tcp -c 10
```

### VNI verification (verbose mode)

For definitive VNI confirmation, use verbose output:

```sh
tcpdump -nn -i hn0 -v "udp port 10800 or udp port 10801" -c 5
```

Look for `VXLAN, flags [I] (0x08), vni 800` (inbound) and `vni 801` (outbound) in the decoded output.

---

## OPNsense Web UI Access

The OPNsense management UI (HTTPS, port 443) is **not exposed publicly** by default. The Bicep template creates NAT rules on `provider-nva-elb`:

| NAT Frontend Port | Backend | Target |
|-------------------|---------|--------|
| `50443` → `443` | provider-nva-1 | OPNsense primary web UI |
| `50444` → `443` | provider-nva-2 | OPNsense secondary web UI |

### Access via Bastion (recommended)

If Bastion is deployed:

```bash
# Get provider NVA ELB public IP
NVA_ELB_PIP=$(az network public-ip show \
  -g "$RG_PROVIDER" \
  -n provider-nva-elb-pip \
  --query ipAddress -o tsv)

echo "OPNsense Primary:   https://$NVA_ELB_PIP:50443"
echo "OPNsense Secondary: https://$NVA_ELB_PIP:50444"
```

Open in a browser — accept the self-signed certificate warning.

**Credentials:** `root` / `opnsense` (factory default — or whatever was configured during bootstrap)

### What the Web UI proves

If the OPNsense web UI loads and shows the dashboard:
- Bootstrap ran to completion (OPNsense installed)
- Networking is up (at least the WAN/management interface)
- config.xml was applied (UI reflects lab configuration)

Check **Interfaces → Assignments** to verify `vxlan0` and `vxlan1` appear.  
Check **Interfaces → VXLAN** for the VNI and port configuration.

### Access via direct VM IP (if Bastion available for tunnel)

```bash
# SSH tunnel to NVA via Bastion, then browse localhost:8443
az network bastion tunnel \
  -g "$RG_CONSUMER" \
  -n consumer-bastion \
  --target-resource-id "$(az vm show -g $RG_PROVIDER -n provider-nva-1 --query id -o tsv)" \
  --resource-port 443 \
  --port 8443
# Then open https://localhost:8443 in browser
```

---

## Smoke Test Bundle — 30-Second Confirmation

Copy-paste this entire block into a PowerShell terminal after a successful deploy. It stitches together the consumer ELB IP retrieval, NVA access verification, and VXLAN proof into a single procedure.

```powershell
# ============================================================
# VXLAN SMOKE TEST BUNDLE — Azure Gateway LB Lab
# Prerequisites: RG_PROVIDER and RG_CONSUMER env vars set;
#                az CLI authenticated; serial-console extension installed
# ============================================================

$ErrorActionPreference = "Stop"
$RG_PROVIDER = $env:RG_PROVIDER ?? "rg-glb-provider-quorra"
$RG_CONSUMER  = $env:RG_CONSUMER  ?? "rg-glb-consumer-quorra"

Write-Host "`n[1/5] Getting Consumer ELB public IP..." -ForegroundColor Cyan
$consumerPIP = az network public-ip show `
  -g $RG_CONSUMER -n consumer-elb-pip `
  --query ipAddress -o tsv
Write-Host "      Consumer ELB PIP: $consumerPIP"

Write-Host "`n[2/5] Verifying GLB chain is active..." -ForegroundColor Cyan
$chainId = az network lb frontend-ip show `
  -g $RG_CONSUMER --lb-name consumer-elb --name frontendip1 `
  --query "gatewayLoadBalancer.id" -o tsv 2>$null
if ($chainId) {
  Write-Host "      GLB chain ACTIVE: $($chainId.Split('/')[-3])" -ForegroundColor Green
} else {
  Write-Host "      ⚠️  GLB chain NOT active — curl will bypass NVA" -ForegroundColor Yellow
}

Write-Host "`n[3/5] HTTP test via GLB chain (5 requests)..." -ForegroundColor Cyan
1..5 | ForEach-Object {
  $result = curl.exe -s -o NUL -w "%{http_code}" "http://$consumerPIP" 2>$null
  $status = if ($result -eq "200") { "✅ $result" } else { "❌ $result" }
  Write-Host "      Request $_: $status"
  Start-Sleep -Seconds 1
}

Write-Host "`n[4/5] Fetching NVA boot log keyword scan..." -ForegroundColor Cyan
$bootlog = az vm boot-diagnostics get-boot-log `
  -g $RG_PROVIDER -n provider-nva-1 2>$null
$keywords = @('bootstrap-ok','bootstrap-failed','vxlan','python3','panic','Error on line')
foreach ($kw in $keywords) {
  $hits = ($bootlog | Select-String $kw -AllMatches).Matches.Count
  $icon = if ($kw -in @('bootstrap-ok','vxlan','python3') -and $hits -gt 0) { "✅" } `
          elseif ($kw -in @('bootstrap-failed','panic','Error on line') -and $hits -gt 0) { "❌" } `
          else { "➖" }
  Write-Host ("      {0} {1,-25}: {2} hit(s)" -f $icon, $kw, $hits)
}

Write-Host "`n[5/5] VXLAN packet capture instructions..." -ForegroundColor Cyan
Write-Host "      Run in a SEPARATE terminal (Terminal A):" -ForegroundColor White
Write-Host "        az serial-console connect -g $RG_PROVIDER -n provider-nva-1" -ForegroundColor DarkGray
Write-Host "        [At OPNsense menu] Press 8 for shell, then run:" -ForegroundColor DarkGray
Write-Host "        tcpdump -nn -i any 'udp port 10800 or udp port 10801 and greater 100' -c 10" -ForegroundColor DarkGray
Write-Host "      Then run in THIS terminal (Terminal B) to generate traffic:" -ForegroundColor White
Write-Host "        curl http://$consumerPIP" -ForegroundColor DarkGray
Write-Host ""
Write-Host "      Expected tcpdump: packets from 168.63.129.16:10800 to NVA trusted IP" -ForegroundColor White
Write-Host "      + packets on vxlan0/vxlan1 interfaces = VXLAN PROVEN ✅" -ForegroundColor Green

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "Smoke test bundle complete. Review results above." -ForegroundColor Cyan
```

---

## Troubleshooting VXLAN Failures

### tcpdump shows no VXLAN packets

1. **GLB chain is not active.** Verify: `az network lb frontend-ip show -g $RG_CONSUMER --lb-name consumer-elb --name frontendip1 --query "gatewayLoadBalancer.id" -o tsv` — must be non-empty. If empty, see [GLB Chaining Race Condition in troubleshooting.md](../troubleshooting.md#glb-chaining-race-condition).

2. **NVA is not in the GLB backend pool.** Verify: `az network lb address-pool show -g $RG_PROVIDER --lb-name provider-nva-glb --name provider-nva-bepool --query "backendIPConfigurations[].id" -o table`

3. **GLB health probe failing.** The NVA must respond on UDP 10800/10801. If `sockstat -l -P udp | grep -E '10800|10801'` shows nothing, VXLAN interfaces are not up — bootstrap failed.

### tcpdump shows GLB packets BUT no traffic decapsulated on vxlan0

**Symptom:**
```
168.63.129.16.10800 > 10.0.1.4.10800: UDP, length 60   ← health probe only, no data
```

**Interpretation:** GLB is sending health probes (they are small, ~60 bytes). No real HTTP traffic is being forwarded. Check:
- Is the GLB backend health probe passing? (NVA must return traffic on the same VXLAN flow)
- Are there active HTTP requests going through the consumer ELB? (Generate traffic in Terminal B)
- Is the NVA's VXLAN interface correctly returning probes? Run: `tcpdump -nn -i hn0 'udp port 10801' -c 5` — you should see return probe packets to `168.63.129.16`.

### curl returns HTTP 200 but tcpdump shows no VXLAN

**Interpretation:** The GLB chain is not active — traffic is going directly consumer-elb → consumer-vm (bypassing OPNsense). Verify the GLB chain step 3f ran successfully. See [GLB chaining verification in troubleshooting.md](../troubleshooting.md#verifying-glb-chaining).

### curl times out after GLB chain is active

**Interpretation:** The OPNsense NVA is dropping or not forwarding traffic. Check:

```sh
# On the NVA — are firewall rules blocking?
pfctl -s rules | grep -v "^#"

# Is the NVA forwarding IP traffic?
sysctl net.inet.ip.forwarding   # must be 1

# Are VXLAN interfaces up?
ifconfig vxlan0 | grep flags    # must show UP,RUNNING
ifconfig vxlan1 | grep flags    # must show UP,RUNNING
```

If `net.inet.ip.forwarding = 0`, IP forwarding is not enabled — the bootstrap may have failed before writing the sysctl config. Check `/var/log/opnsense-bootstrap.log`.

### VXLAN interfaces present but VNI or port is wrong

Verify the VXLAN config matches the Bicep-defined ports:

```sh
# FreeBSD — show VXLAN interface config
ifconfig vxlan0
ifconfig vxlan1
```

Expected:
- `vxlan0`: VNI 800, local-port 10800, remote-port 10800
- `vxlan1`: VNI 801, local-port 10801, remote-port 10801

If wrong, the XML config substitution may have failed. Check `/usr/local/etc/config.xml` for the VXLAN stanza.

---

*Cross-references: [serial-console.md](./serial-console.md) · [boot-diagnostics.md](./boot-diagnostics.md) · [../troubleshooting.md](../troubleshooting.md) · [../troubleshooting-freebsd-on-azure.md](../troubleshooting-freebsd-on-azure.md)*
