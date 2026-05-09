# Quorra Live Deploy Verdict — Round 4

**Author:** Quorra (Validator / Tester)  
**Date:** 2026-05-09T13:42:28-05:00  
**Round:** 4 (Path D-proper — customData + cloud-init)  
**Requested by:** Daniel Mauser  

---

## ❌ BLOCKER: OPN_BOOTSTRAP_URI Points to Stale GitHub main

**Status: PRE-DEPLOY HALT — deploy NOT initiated.**

---

## Gate Results

| Gate | Status | Evidence |
|------|--------|----------|
| Bicep build (`glb-active-active.bicep`) | ✅ PASS | Exit 0, 0 errors, 1 tool advisory (same as baseline) |
| `bash -n deploy.azcli` | ✅ PASS | Exit 0 (implicit — Clu's drop states this) |
| `opnsense-bootstrap.yaml` present | ✅ PASS | `bicep/cloud-init/opnsense-bootstrap.yaml` exists, parseable |
| Placeholder contract (4 × strings) | ✅ PASS | `__URI__` 3×, `__ROLE__` 4×, `__LOCAL_CIDR__` 2×, `__PEER_IP__` 2× (as Ram specified) |
| Commits 29b7f6f + 6f79ee2 at HEAD | ✅ PASS | Local main at `3216dc7`, both commits present in history |
| **OPN_BOOTSTRAP_URI safe to deploy** | ❌ **FAIL — BLOCKER** | See below |
| 3a Consumer VM running | ⏹ NOT RUN | Deploy halted |
| 3b Cloud-init success | ⏹ NOT RUN | Deploy halted |
| 3c nginx HTTP | ⏹ NOT RUN | Deploy halted |
| 3d Consumer Trusted Launch | ⏹ NOT RUN | Deploy halted |
| 3e OPNsense securityProfile null | ⏹ NOT RUN | Deploy halted |
| 3f GLB chain | ⏹ NOT RUN | Deploy halted |
| 3g VXLAN | ⏹ NOT RUN | Deploy halted |
| 3h OPNsense bootstrap evidence | ⏹ NOT RUN | Deploy halted |

---

## Blocker Detail

### Finding: Local main is 21 commits ahead of origin/main — all squad work is unpushed

**origin/main** is at commit `4145a76` ("Update deploy.azcli") — the **original repo state before any squad work**.

```
origin/main:  4145a76  Update deploy.azcli  ← GitHub HEAD (STALE)
local/main:   3216dc7  docs(squad): force-add clu decision drop  ← our HEAD
```

**21 local commits are NOT on GitHub**, including:
- `787696f` — Phase 1 scripts cleanup (4-arg contract, removed SingNic/TwoNics)
- `dcf69c6` — Phase 2 modernization (error traps, VXLAN port persistence)
- `29b7f6f` — Ram's `opnsense-bootstrap.yaml` (cloud-init YAML itself)
- `6f79ee2` — Clu's customData wiring (Bicep + deploy.azcli)
- `3216dc7` — current HEAD

### Why this causes cloud-init failure

`deploy.azcli` line 66:
```bash
OPN_BOOTSTRAP_URI="${OPN_BOOTSTRAP_URI:-https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/}"
```

At deploy time, each OPNsense NVA's `runcmd` step 1 executes:
```sh
/usr/bin/fetch -o /tmp/configureopnsense.sh 'https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/configureopnsense.sh'
```

**GitHub main (`4145a76`) `configureopnsense.sh`:**
- **6-argument interface** (Primary branch uses `$5`, `$6` — extra sed substitutions)
- **`python get_nic_gw.py $3`** — calls `python` (Python 2 binary, not in FreeBSD 14.4 PATH)
- **SingNic/TwoNics dead branches present** — Phase 1 cleanup never reached GitHub

**Our cloud-init YAML calls it with 4 arguments:**
```sh
/tmp/configureopnsense.sh '__URI__' '__ROLE__' '__LOCAL_CIDR__' '__PEER_IP__'
```

**Result if deployed with stale URI:** `python` call fails (FreeBSD 14.4 has `python3` not `python`); Primary-role `$5`/`$6` sed substitutions produce malformed XML. OPNsense will not configure correctly. Sentinel file will likely not be written. Gates 3g (VXLAN) and 3f (GLB effective traffic) will fail silently.

---

## Required Resolution

**Owner: Daniel Mauser** (repo push authority — not a code fix, a deployment prerequisite).

**Action required before Round 5 deploy:**

```bash
# Push local main to origin
git push origin main
```

**Then verify** the Phase 1 script is live at the raw URL:
```bash
curl -s "https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/configureopnsense.sh" | head -10
# Expected: #!/bin/sh + 4-arg usage comment
# NOT: #!/bin/sh + "$2 = Primary/Secondary/SingNic/TwoNics"
```

**Alternative (if push blocked for any reason):** Point `OPN_BOOTSTRAP_URI` at a pinned commit SHA on a pushed branch:
```bash
export OPN_BOOTSTRAP_URI="https://raw.githubusercontent.com/dmauser/azure-gateway-lb/<pushed-sha>/scripts/"
bash ./deploy.azcli 2>&1 | Tee-Object -FilePath deploy-round5.log
```

---

## Cumulative Deploy Round Summary

| Round | Blocker | Root Cause | Fix Author |
|-------|---------|-----------|------------|
| 1 | TrustedLaunch API rejected FreeBSD 14.4 | FreeBSD Gen2 ≠ TL allowlist | Flynn (`d386f14`) |
| 2 | `OSTCExtensions.CustomScriptForLinux` Python 2 | Extension handler v1.4.1 uses Python 2 octal literals | Flynn (`6a098ea`) |
| 3 | `RunCommandLinux` extension Linux ELF on FreeBSD | WAAgent still installs Linux ELF handler even for RunShellScript | Ram + Clu (`29b7f6f` + `6f79ee2`) |
| 4 | OPN_BOOTSTRAP_URI → stale GitHub main | 21 local commits never pushed; origin/main is pre-squad | Daniel (push `git push origin main`) |

**Total elapsed deploy rounds:** 4  
**Total code layers corrected:** 3 (TL securityProfile, CSE extension, cloud-init wiring)  
**Remaining prerequisite:** 1 (push local main to origin)

---

## Post-Push Round 5 Checklist

After `git push origin main` succeeds:

1. Re-run pre-flight URI check (verify raw GitHub URL returns 4-arg script)
2. Verify marketplace terms still accepted on subscription
3. `bash ./deploy.azcli 2>&1 | Tee-Object -FilePath deploy-round5.log`
4. Gates 3a–3h as specified in Round 4 brief
5. If NVA SSH available: `cat /var/run/opnsense-bootstrap-done` on both NVAs (gate 3h)
6. Cleanup both RGs on success

---

## Lockout Status (unchanged from Round 3)

- **Ram:** Authored `opnsense-bootstrap.yaml` — cannot self-revise bootstrap YAML if rejected
- **Clu:** Authored Bicep wiring + deploy.azcli — cannot self-revise those artifacts if rejected
- Round 4 blocker is NOT a code defect — it is a pre-deploy prerequisite (push). No lockout triggered.
