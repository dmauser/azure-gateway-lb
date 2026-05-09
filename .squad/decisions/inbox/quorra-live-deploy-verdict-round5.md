# Quorra — Live Deploy Verdict: Round 5

**Date:** 2026-05-09T17:40:00-05:00  
**Deploy Attempt:** Round 5 (post-push, origin/main = bd27042)  
**Environment:** MSDN_Dmauser / westus3  
**RGs:** rg-glb-consumer-quorra, rg-glb-provider-quorra  
**Cleanup:** Both RGs deleted (no-wait) at 17:40:29 CDT  

---

## Gate Summary

| Gate | Result | Evidence |
|------|--------|----------|
| 3a Consumer VM running | ✅ PASS | `PowerState/running` |
| 3b Consumer cloud-init success | ✅ PASS | `status: done` via `az vm run-command` |
| 3c nginx serves HTML | ✅ PASS | `curl http://20.38.173.229` → `Test Website on consumer-vm` (direct path, GLB chain not active at time of test) |
| 3d Consumer Trusted Launch | ✅ PASS | `securityType: TrustedLaunch`, `secureBootEnabled: true`, `vTpmEnabled: true` |
| 3e OPNsense securityProfile null | ✅ PASS | Both primary and secondary NVAs: `securityProfile: null` |
| 3f GLB chaining | ✅ PASS | `gatewayLoadBalancer.id` = `/subscriptions/.../rg-glb-provider-quorra/.../provider-nva-glb/frontendIPConfigurations/FW` (manually established after deploy timing issue) |
| 3g VXLAN end-to-end | ❌ FAIL | `curl http://20.38.173.229` times out when GLB chain active — OPNsense VXLAN not configured (see Finding 2) |
| 3h OPNsense bootstrap | ❌ FAIL | OPNsense web GUI (port 443 via NAT 50443/50444) not responding at 67-minute mark; SSH not accessible (no port 22 NAT rule); bootstrap sentinel unverifiable (see Finding 2) |

**Overall verdict: ❌ BLOCKER — 2 of 8 gates failed (3g, 3h)**

---

## Findings

### Finding 1 — GLB Chain Timing (Non-blocking with manual workaround)

**Module:** `deploy.azcli`  
**Owner:** Flynn (deploy.azcli author)  
**Severity:** Non-blocking (manual workaround confirmed)  

**Description:**  
`az network lb frontend-ip update --gateway-lb $glbfeid` fails immediately after the provider Bicep deployment completes with:  
```
ERROR: (InvalidGlobalResourceReference) Resource .../provider-nva-glb/frontendIPConfigurations/FW
 referenced by .../consumer-elb was not found.
```
Root cause: Azure Resource Manager propagation delay. The GLB resource exists in ARM but hasn't fully propagated across all ARM endpoints by the time the consumer-elb update is issued. Retrying the exact same command 2–3 minutes later succeeds (exit code 0, chain confirmed).

**Evidence:**  
- First attempt: `InvalidGlobalResourceReference` error  
- Manual retry 2 min later: exit code 0, `gatewayLoadBalancer.id` non-empty ✅  

**Fix needed:** Add `sleep 60` (or retry-with-backoff) in `deploy.azcli` between the provider Bicep deploy completion and the GLB chain step.

---

### Finding 2 — OPNsense Bootstrap Failure: `python` vs `python3` (BLOCKER)

**Module:** `scripts/configureopnsense.sh`  
**Owner:** Ram's artifact — fix must come from non-Ram author (lockout applies)  
**Severity:** BLOCKER — blocks 3g (VXLAN) and 3h (bootstrap verification)  

**Description:**  
`configureopnsense.sh` calls `python get_nic_gw.py $3` (line ~72) before any Python symlink is created. The script's own `ln -s /usr/local/bin/python3.11 /usr/local/bin/python` (symlink creation) appears later in the script — AFTER the `opnsense-bootstrap.sh.in` installation step. On FreeBSD 14.4 (Azure marketplace image `thefreebsdfoundation/freebsd-14_4/14.4.0`), `python` is NOT available at the time of the call; only `python3`/`python3.11` exist.

Because the script uses `set -euo pipefail`, the script exits immediately at the `python get_nic_gw.py` failure. All downstream steps are skipped:
- `fetch opnsense-bootstrap.sh.in` → never runs
- `sed ... sshd_config` (PermitRootLogin yes) → never runs  
- `sh ./opnsense-bootstrap.sh.in -y -r 25.1` → never runs (OPNsense never installed)
- VXLAN rc.syshook configuration → never runs

The cloud-init pipeline `configureopnsense.sh ... 2>&1 | tee opnsense-bootstrap.log` returns 0 (tee's exit code), so the cloud-init sentinel step still writes `/var/run/opnsense-bootstrap-done`. The sentinel's existence is therefore NOT reliable evidence of successful bootstrap.

**Observed evidence (67 minutes after NVA creation):**  
- OPNsense web GUI on port 443 (via NAT 50443→443): HTTP 000 (connection refused) — no service listening  
- `curl http://consumer-elb-pip` via GLB chain: timeout — OPNsense VXLAN not forwarding traffic  
- Both primary and secondary NVAs exhibit identical failure  
- NVAs remain at `PowerState/running` (plain FreeBSD 14.4 running, OPNsense absent)  

**SSH access note:**  
SSH to the NVAs is not directly accessible — NAT rules on `provider-nva-elb` only expose port 443 (50443→443, 50444→443). No port 22 NAT rule exists. Bastion was not deployed (`BASTION_DEPLOY=false`). Cannot SSH to verify `/var/run/opnsense-bootstrap-done` or tail `/var/log/opnsense-bootstrap.log` directly.

**Fix required (non-Ram author):**  
Option A (minimal): Replace `python get_nic_gw.py $3` with `python3 get_nic_gw.py $3` in the `if/elif` block.  
Option B (robust): Move `ln -s /usr/local/bin/python3.11 /usr/local/bin/python` to the TOP of the script (before the `if/elif` block) so the symlink exists when needed. Note: if Python 3.11 isn't in the image, this would fail — should also add a fallback check.  
Option C (robust): Check for `python` in PATH at script start; if absent, alias to `python3`.

---

### Finding 3 — Redeploy Breaks GLB Chain (Observation)

**Module:** `bicep/consumer-vm.bicep` / `deploy.azcli`  
**Owner:** Clu (consumer-vm.bicep) / Flynn (deploy.azcli)  
**Severity:** Observation (non-blocking for single clean deploys; blocking for re-runs)  

**Description:**  
Running `bash ./deploy.azcli` a second time (attempting re-deploy when consumer/provider RGs already exist) causes the consumer Bicep to re-deploy `consumer-elb`. The consumer Bicep does NOT reference the `gatewayLoadBalancer` property, so it overwrites `frontendip1` without the GLB chain reference, silently removing a previously established GLB chain.

**Impact:** After a redeploy, the GLB chain must be manually re-established with:  
```bash
glbfeid=$(az network lb frontend-ip show -g $provider_rg --lb-name provider-nva-glb --name FW --query id -o tsv)
az network lb frontend-ip update -g $consumer_rg --name frontendip1 --lb-name consumer-elb \
    --public-ip-address consumer-elb-pip --gateway-lb $glbfeid
```

---

## Deploy Timing Summary

| Event | Time (CDT) | Delta |
|-------|-----------|-------|
| Deploy started | 16:25:54 | T+0 |
| VMs created | ~16:30:01 | T+4m |
| Provider Bicep deploy complete | ~16:33:00 | T+7m |
| GLB chain first attempt (FAIL) | ~16:33:00 | T+7m |
| GLB chain manual retry (PASS) | 16:35:29 | T+9m |
| 3b, 3d, 3e, 3f verified | ~16:37:00 | T+11m |
| 3c verified (direct path) | ~16:39:00 | T+13m |
| Cleanup initiated | 17:40:29 | T+75m |

**Total elapsed from deploy start to cleanup:** ~75 minutes  
**Total elapsed across all 5 rounds:** R1–R4 pre-push static validation; R5 live deploy ~75 minutes.

---

## Round Totals (Rounds 1–5)

| Round | Outcome | Blocker |
|-------|---------|---------|
| Round 1 | BLOCKED | TrustedLaunch not supported for FreeBSD 14.4 (fixed by Flynn d386f14) |
| Round 2 | BLOCKED | `OSTCExtensions.CustomScriptForLinux` Python 2 vs FreeBSD Python 3 (fixed by Flynn 6a098ea → Path D-prime) |
| Round 3 | BLOCKED | `RunCommandLinux` Linux ELF on FreeBSD 14.4 (fixed by Ram 29b7f6f + Clu 6f79ee2 → Path D-proper) |
| Round 4 | BLOCKED | `OPN_BOOTSTRAP_URI` stale (21 commits unpushed) — blocked pre-deploy |
| Round 5 | BLOCKED | `configureopnsense.sh` calls `python` (unavailable on FreeBSD 14.4; only `python3` exists) |

---

## Skill Extraction

**Pattern: FreeBSD-on-Azure script compatibility checklist**  
Before any shell script targeting FreeBSD 14.4 is committed:
1. All `python` calls → must be `python3` (Python 2 is absent; `python` symlink may not exist)
2. All `python3` commands should be tested against known image version (`python3.11` on thefreebsdfoundation/freebsd-14_4/14.4.0)
3. Symlink creation (`ln -s python3.11 python`) must precede any `python` call if symlink is relied upon
4. Bootstrap log (`/var/log/opnsense-bootstrap.log`) + sentinel (`/var/run/opnsense-bootstrap-done`) are unreliable if script uses `set -euo pipefail` piped to `tee` (tee masks exit code — sentinel written even on failure)
5. SSH access requires NAT rule for port 22 on provider-nva-elb; current Bicep only exposes port 443 (50443/50444) — no direct SSH verification possible without Bastion or SSH NAT rule

**Store in:** `.squad/skills/freebsd-azure-compat-checklist/SKILL.md`
