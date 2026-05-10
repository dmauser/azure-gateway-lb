# Validation Checklist: Trusted Launch + Cloud-Init Migration

**Prepared by:** Quorra (Validator / Tester)  
**Date:** 2026-05-09T13:23:58-05:00  
**Status:** PRE-COMMIT GATE — awaiting Clu's implementation  
**References:** `docs/architecture/trusted-launch.md`, `docs/architecture/cloud-init-migration.md`

---

## Scope

| Component | Change Expected |
|-----------|----------------|
| `bicep/modules/VM/opnsense-vm-active-active.bicep` | Add `securityProfile` (vTPM only, no Secure Boot) |
| Consumer VM (currently `deploy.azcli` step 5) | Add `--custom-data` cloud-init OR new Bicep module with `customData + securityProfile` (full TL) |
| `deploy.azcli` step 7 | Remove `az vm extension set` CSE call (after cloud-init migration) |
| `bicep/modules/VM/vmext.bicep` | Unchanged — OPNsense CSE must remain |

---

## 1. Bicep Build Acceptance Criteria

### 1.1 Baseline (pre-Clu commit) — recorded 2026-05-09T13:23:58-05:00

```
Command: az bicep build --file bicep/glb-active-active.bicep
Exit code: 0
Errors: 0
Warnings: 1
  WARNING: A new Bicep release is available: v0.43.8.
           (Tool advisory — not a code issue. Acceptable.)
```

### 1.2 Post-Clu commit acceptance criteria

| Criterion | Expected | Fail condition |
|-----------|----------|----------------|
| Exit code | `0` | Any non-zero exit |
| Compilation errors | `0` | Any error line |
| New BCP037 violations | `0` | Unknown property on any API type |
| `securityProfile` on OPNsense module | Present with `vTpmEnabled: true`, `secureBootEnabled: false` | Missing or inverted |
| `customData` on consumer VM | Present in `osProfile` | Missing |
| CSE module reference for consumer VM | Absent (removed) | Still present |
| CSE module reference for OPNsense VMs | Present (unchanged) | Removed |

**Acceptable warnings (do not fail on these):**
- `WARNING: A new Bicep release is available: vX.Y.Z.` — tool advisory, ignore.
- BCP036 unused variable warnings on pre-existing optional params — carry-forward from Phase 1; not introduced by TL/cloud-init work.

**Run command after Clu's commit:**
```bash
az bicep build --file bicep/glb-active-active.bicep 2>&1
# Exit 0 = PASS; any error = FAIL; diff warning count vs baseline
```

---

## 2. What-If Expected Diff

Run `az deployment group what-if` against the provider resource group for the OPNsense Bicep template, and separately review consumer VM changes via deploy.azcli diff.

### 2.1 OPNsense NVA VMs (provider resource group)

**Expected changes — provider-nva-primary and provider-nva-secondary:**

```
~ Microsoft.Compute/virtualMachines/provider-nva-primary
  + properties.securityProfile:
      securityType: "TrustedLaunch"
      uefiSettings:
        vTpmEnabled:       true      ← NEW
        secureBootEnabled: false     ← NEW (explicitly false)
```

**Expected NO changes on OPNsense VMs:**
- `osProfile.customData` — must NOT appear (FreeBSD does not use cloud-init)
- `properties.storageProfile.imageReference` — unchanged
- `Microsoft.Compute/virtualMachines/extensions/*` — CSE extensions unchanged

### 2.2 Consumer VM (consumer resource group)

Consumer VM is currently deployed imperatively via `az vm create` in `deploy.azcli`. Clu's implementation path determines which what-if applies:

**Path A — az vm create `--custom-data` flag (deploy.azcli change):**
```
Not detectable by Bicep what-if.
Validate: az vm show -g glb-consumer-rg -n consumer-vm --query osProfile.customData
Expected: non-null base64 blob
```

**Path B — New consumer-vm.bicep module (Bicep change):**
```
~ Microsoft.Compute/virtualMachines/consumer-vm
  + properties.osProfile.customData:       "<base64-encoded cloud-config>"  ← NEW
  + properties.securityProfile:
      securityType: "TrustedLaunch"
      uefiSettings:
        secureBootEnabled: true   ← NEW
        vTpmEnabled:       true   ← NEW
  - Microsoft.Compute/virtualMachines/consumer-vm/extensions/CustomScript  ← REMOVED
```

> ⚠️ **ADR Ambiguity (filed):** The cloud-init migration ADR references a "consumer VM Bicep module" that does not currently exist. Consumer VM is deployed entirely via `az vm create` in `deploy.azcli`. Clu must clarify implementation path before proceeding. See decision drop for details.

---

## 3. Post-Deploy Smoke Tests

Execute after `bash deploy.azcli` completes successfully. Substitute real values for `<consumer-rg>`, `<provider-rg>`, `<consumer-elb-pip>`, `<nva-primary-name>`.

### 3a. Consumer VM Boot State

```bash
az vm get-instance-view \
  --resource-group glb-consumer-rg \
  --name consumer-vm \
  --query 'instanceView.statuses[?code==`PowerState/running`]' \
  -o json
```

**PASS:** Array contains one entry with `code: "PowerState/running"`.  
**FAIL:** Empty array, `PowerState/stopped`, or `PowerState/deallocated`.

---

### 3b. Cloud-Init Completion (SSH into consumer-vm)

```bash
# SSH via NAT rule on consumer-elb port 50000
ssh azureuser@<consumer-elb-pip> -p 50000

# On the VM:
sudo cat /var/log/cloud-init-output.log | tail -50
```

**PASS indicators in the log output:**
- `Setting up nginx` or `nginx is already the newest version`
- `cloud-init: finished` or `Cloud-init ... finished` at the end
- `runcmd` lines: `systemctl enable nginx`, `systemctl start nginx`

**FAIL:** Log missing, `cloud-init status: error`, or nginx setup lines absent.

**Additional check:**
```bash
cloud-init status
# Expected: status: done
```

---

### 3c. Nginx Serves HTTP Traffic (via GLB chain)

```bash
curl http://<consumer-elb-pip>
```

**PASS:** Returns `Test Website on consumer-vm` (or nginx default page if ADR content changed).  
**FAIL:** Connection refused, timeout, or 502/504.

> ℹ️ This test validates both nginx install AND GLB chaining in a single check. If curl fails, run 3f first to rule out GLB chain issues.

---

### 3d. Consumer VM Trusted Launch Active

```bash
az vm show \
  --resource-group glb-consumer-rg \
  --name consumer-vm \
  --query 'securityProfile' \
  -o json
```

**PASS:**
```json
{
  "securityType": "TrustedLaunch",
  "uefiSettings": {
    "secureBootEnabled": true,
    "vTpmEnabled": true
  }
}
```
**FAIL:** `null`, missing `securityType`, or `secureBootEnabled: false` on Ubuntu.

---

### 3e. OPNsense vTPM (without Secure Boot)

Run for both NVA instances:

```bash
az vm show \
  --resource-group glb-provider-rg \
  --name provider-nva-primary \
  --query 'securityProfile' \
  -o json

az vm show \
  --resource-group glb-provider-rg \
  --name provider-nva-secondary \
  --query 'securityProfile' \
  -o json
```

**PASS:**
```json
{
  "securityType": "TrustedLaunch",
  "uefiSettings": {
    "secureBootEnabled": false,
    "vTpmEnabled": true
  }
}
```
**FAIL:** `secureBootEnabled: true` (FreeBSD will fail to boot), or `vTpmEnabled: false`, or `null`.

---

### 3f. GLB Chaining Still Works

```bash
az network lb frontend-ip show \
  --resource-group glb-consumer-rg \
  --lb-name consumer-elb \
  --name frontendip1 \
  --query gatewayLoadBalancer.id \
  -o tsv
```

**PASS:** Returns a non-empty resource ID string like:
```
/subscriptions/<sub>/resourceGroups/glb-provider-rg/providers/Microsoft.Network/loadBalancers/provider-nva-glb/frontendIPConfigurations/FW
```
**FAIL:** Empty output or `null`.

---

### 3g. VXLAN Tunnel Verification (OPNsense)

SSH into OPNsense primary via ELB NAT rule (port 50443) or Bastion, then:

```bash
# On OPNsense primary — capture VXLAN encapsulated traffic
# Generate test traffic first: curl http://<consumer-elb-pip> from an external host
tcpdump -n -i hn1 udp port 10800 or udp port 10801 -c 10
```

**PASS:** Packets captured on UDP 10800 (internal tunnel, type Internal) and/or 10801 (external tunnel, type External).  
**FAIL:** No packets after 30 seconds while traffic is actively flowing.

**Alternative verification (from deploy.azcli connectivity check section):**
```bash
# On OPNsense — verify VXLAN interfaces see traffic
tcpdump -n -i vxlan0    # inbound external
tcpdump -n -i vxlan1    # outbound external
```

---

## 4. Rollback Procedure

If any smoke test fails after Clu's changes are deployed:

### Step 1 — Isolate scope

| Failing test | Likely cause | Rollback action |
|---|---|---|
| 3a (VM not running) | secureBootEnabled=true on FreeBSD → boot failure | Redeploy NVA with `secureBootEnabled: false` |
| 3b (cloud-init fail) | cloud-init YAML syntax error, or wrong path | Check `/var/log/cloud-init.log` for parse errors; redeploy consumer VM with corrected YAML |
| 3c (nginx not serving) | cloud-init didn't complete before probe; CSE removed too early | Temporarily re-enable CSE step in deploy.azcli step 7 |
| 3d (TL not on consumer) | `--custom-data` not passed or securityProfile missing | Verify az vm create command includes `--custom-data` and image is Gen 2 |
| 3e (wrong TL on OPNsense) | secureBootEnabled=true; VM won't start | Redeploy NVA: set `secureBootEnabled: false` in Bicep |
| 3f (GLB chain broken) | `az network lb frontend-ip update --gateway-lb` step failed | Re-run GLB chaining section of deploy.azcli |
| 3g (VXLAN down) | NVA didn't boot (see 3a) or configureopnsense.sh failed | Check CSE extension status on NVA; check OPNsense VXLAN config |

### Step 2 — Hard rollback

```bash
# Re-deploy provider NVAs from last known-good Bicep (pre-Clu commit)
az deployment group create \
  --name "${nva}-rollback-$(date +%s)" \
  --resource-group "$provider_rg" \
  --template-file "${SCRIPT_DIR}/bicep/glb-active-active.bicep" \
  --parameters ... \
  --output none

# Re-enable CSE for consumer VM if cloud-init rollback needed
az vm extension set \
  --resource-group "$consumer_rg" \
  --vm-name consumer-vm \
  --name CustomScript \
  --settings '{"commandToExecute": "apt-get -y update && apt-get -y install nginx && echo Test Website on consumer-vm > /var/www/html/index.html"}' \
  --publisher Microsoft.Azure.Extensions \
  --output none
```

> ⚠️ Trusted Launch cannot be toggled on existing VMs. A full VM redeploy is required for any securityProfile change.

---

## 5. Gate Summary

| Gate | Command / Check | PASS criteria |
|---|---|---|
| Bicep build | `az bicep build --file bicep/glb-active-active.bicep` | Exit 0, 0 errors |
| Consumer VM securityProfile | `az vm show ... --query securityProfile` | Full TL (SB+vTPM=true) |
| Consumer VM cloud-init log | SSH + `cat /var/log/cloud-init-output.log` | nginx + "finished" |
| Consumer VM nginx | `curl http://<consumer-elb-pip>` | 200 + content |
| OPNsense securityProfile | `az vm show ... --query securityProfile` | vTPM=true, SB=false |
| GLB chain | `az network lb frontend-ip show ... --query gatewayLoadBalancer.id` | Non-empty resource ID |
| VXLAN tunnel | tcpdump UDP 10800/10801 on OPNsense | Packets captured |

**Overall verdict:** All 7 gates must pass for APPROVE. Any single FAIL = REJECT (see rollback procedure).

---

## 6. Round 6 Learnings (Appended 2026-05-09T19:20:21-05:00 by Flynn)

> This section extends Quorra's checklist with empirical corrections from live deploy rounds 1–6.
> Do not modify sections 1–5 above.

### 6a. Gate 3e correction — OPNsense securityProfile must be NULL

The original checklist (section 3e) expected OPNsense NVAs to have `securityProfile` with
`vTpmEnabled: true, secureBootEnabled: false`. **This is wrong.** Quorra Round 1 confirmed that ANY
`securityType: 'TrustedLaunch'` on `thefreebsdfoundation/freebsd-14_4` causes `BadRequest`.

**Corrected 3e PASS criteria:**

```json
null
```

Both `provider-nva-primary` and `provider-nva-secondary` must show `securityProfile: null`.
This has been the deployed state since commit `d386f14` (Flynn).

### 6b. Gate 3h — OPNsense bootstrap evidence (NEW required gate)

**What to verify:**

```bash
# SSH into each NVA (via Bastion or SSH NAT if available)
cat /var/run/opnsense-bootstrap-done
# Expected: bootstrap-ok-<ISO8601Z>   ← reliable only on post-519bf26 code
cat /var/run/opnsense-bootstrap-failed
# Expected: file does NOT exist

tail -50 /var/log/opnsense-bootstrap.log
# Expected: OPNsense bootstrap completion lines; no Python errors; no "not found" lines

cloud-init status --long
# Expected: status: done
```

**PASS:** `opnsense-bootstrap-done` exists AND `opnsense-bootstrap-failed` does NOT exist.  
**FAIL:** `opnsense-bootstrap-failed` exists (check log for root cause) OR neither file exists
(cloud-init may still be running — wait and retry after 5 minutes).

> ⚠️ **Sentinel reliability:** Before commit `519bf26` (Round 6 fix), the sentinel was written
> unconditionally even when the bootstrap script failed (tee masked the exit code). Verify you're
> running post-`519bf26` code before trusting the sentinel.

### 6c. Gate 3g — VXLAN tcpdump proof (REQUIRED by Daniel Mauser)

The original 3g gate suggested tcpdump on `hn1`. The definitive test is on UDP ports 10800/10801
at the physical-NIC level. This proves encapsulation is happening — not just that OPNsense interfaces exist.

**Required tcpdump command:**

```bash
# On OPNsense NVA — while external traffic is actively flowing to consumer-elb-pip:
tcpdump -nn -i any "udp port 10800 or udp port 10801"
```

**Required observed output (must show packets from both directions):**

```
HH:MM:SS.XXXXXX IP <glb-vtep-ip>.NNNNN > <nva-trusted-ip>.10800: UDP, length NN
HH:MM:SS.XXXXXX IP <nva-trusted-ip>.10801 > <glb-vtep-ip>.NNNNN: UDP, length NN
```

Inferred end-to-end (nginx HTTP succeeding) is **not sufficient** — nginx can respond directly if
the GLB chain has a timing gap. The tcpdump is the only proof that encapsulation is in the data path.

### 6d. Updated Gate Summary (post-Round-6)

| Gate | Command / Check | PASS criteria | Round introduced |
|------|-----------------|---------------|------------------|
| Bicep build | `az bicep build --file bicep/glb-active-active.bicep` | Exit 0, 0 errors | Phase 3 |
| Consumer VM securityProfile | `az vm show ... --query securityProfile` | Full TL (SB=true, vTPM=true) | Round 2 ✅ |
| Consumer VM cloud-init log | SSH + `cat /var/log/cloud-init-output.log` | nginx + "finished" | Round 2 ✅ |
| Consumer VM nginx | `curl http://<consumer-elb-pip>` | 200 + `Test Website on consumer-vm` | Round 2 ✅ |
| OPNsense securityProfile | `az vm show ... --query securityProfile` | **null** (TL not supported) | **Corrected Round 1** |
| OPNsense bootstrap evidence | SSH + sentinel + log | `opnsense-bootstrap-done` present; `opnsense-bootstrap-failed` absent | Round 6 (gate 3h) |
| GLB chain | `az network lb frontend-ip show ... --query gatewayLoadBalancer.id` | Non-empty resource ID | Round 5 ✅ |
| VXLAN tcpdump | `tcpdump -nn -i any "udp port 10800 or udp port 10801"` on NVA | Packets on both ports | **Required (Daniel)** |

