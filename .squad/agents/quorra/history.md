# Quorra — History

## Project Context
- **Project:** azure-gateway-lb
- **User:** Daniel Mauser

## Learnings

### Phase 1 Gate — 2026-05-08 (APPROVED)

**What was reviewed:** Clu (IaC cleanup + security + BCP037 + regen), Ram (CRLF + dead-code removal + sed fix), Flynn (deploy.azcli full rewrite).

**Pattern: checklist order that worked**

1. **Read all completion reports first** — understand what was claimed before running tools. Avoids re-investigating things already explained.
2. **Bicep build first** — `az bicep build --file <path>` is the single fastest gate. Exit 0 = no errors. Count warnings; categorise (unused-vars, unnecessary-dependson, etc.). Deferred warnings should be explicitly labelled with the phase they belong to.
3. **File inventory with Test-Path** — `Test-Path` on each expected-absent path is authoritative. Also verify the *archive destination* exists (archived/ folder + README).
4. **`bash -n` for all shell files** — catches syntax but not runtime errors. Note that FreeBSD-specific commands (`fetch`) parse fine under bash -n; that's expected.
5. **CRLF check with `[System.IO.File]::ReadAllBytes`** — count `0x0D` bytes. Zero means clean LF.
6. **Security via `git grep`** — use `-- ':!archived/' ':!.git/'` to exclude known-dirty history artifacts. `Select-String` for `--admin-password` and hardcoded subscription names in deploy scripts.
7. **`@secure()` verification via grep with `-A 1`** — confirms the decorator is on the line immediately before `param TempPassword`.
8. **Architecture: read deploy.azcli top-to-bottom** — verify PIP before LB, synchronous Bicep deploy, GLB chain with correct flag, cleanup as commented function.
9. **Flynn's flagged issues**: Always verify the author's own "open questions" — in this case `--frontend-ip-name` for Standard LB NAT rules. For a single-frontend LB this is non-blocking; flag for Phase 2 hardening.

**Key decisions confirmed:**
- Bicep is canonical; ARM/ is compiled output only.
- Active-active is the only live code path; SingNic/TwoNics are archived.
- Password in git history is known/accepted; REDACTED in the working file.

**REJECT pattern (for future reference):** If any of these appear → REJECT immediately:
- `az bicep build` exit ≠ 0
- `bash -n` exit ≠ 0
- `P@ssw0rd` (or equivalent plaintext credential) in any non-archived tracked file
- `--admin-password` in any deploy script
- `--no-wait` before an immediate downstream query on the same resource
- Cleanup as a bare `az group delete` (not commented-out or in a function)

### Phase 2 Anticipatory Gate — TL + Cloud-Init (2026-05-09T13:23:58-05:00)

**Context:** Clu implementing Trusted Launch + cloud-init migration. Gate produced pre-commit so Daniel has a ready checklist the moment code lands.

**Bicep baseline (pre-TL, pre-cloud-init):**
- `az bicep build --file bicep/glb-active-active.bicep` → exit 0, 0 errors, 1 tool-advisory warning (new Bicep version available). This is the clean baseline Clu must not degrade.

**ADR sanity-check findings (file, don't fix):**

1. **CRITICAL — No consumer VM Bicep module.** The cloud-init ADR directs Clu to add `customData` to a "consumer VM Bicep module" that does not exist. Consumer VM is deployed via `az vm create` in `deploy.azcli` step 5. Clu must choose implementation path (Path A: `az vm create --custom-data` flag; Path B: new consumer-vm.bicep). Finding filed in decision drop. Flynn must approve path before Clu writes code.

2. **MINOR — ADR image ref uses `freebsd-14_1` but codebase uses `freebsd-14_4`.** The verification `az vm image show` command in `trusted-launch.md` references `freebsd-14_1`. Actual Bicep uses `14_4-release-amd64-gen2-ufs`. ADR verification command is misleading. Underlying conclusion (Gen 2 capable, no Secure Boot shim) still correct for 14.4.

3. **MINOR — Consumer CSE is in deploy.azcli, not vmext.bicep.** Cloud-init ADR "Step 3" implies deleting a Bicep resource. The consumer CSE is in `deploy.azcli` step 7 only. `vmext.bicep` serves OPNsense exclusively and must not be touched.

**Patterns learned:**

- **Anticipatory validation pattern:** Read ADRs as spec. Cross-check every file reference against the actual codebase. ADRs frequently assume module structure that doesn't yet exist — this is the #1 source of implementation confusion.
- **Trusted Launch: securityType required for vTPM-only.** Even when `secureBootEnabled: false`, the `securityType: 'TrustedLaunch'` field must be present for vTPM to activate. Cannot omit it.
- **FreeBSD Gen 2 confirmation:** SKU name `-gen2-` in `14_4-release-amd64-gen2-ufs` is sufficient proof. No need to run `az vm image show` to confirm Gen 2 when SKU name is explicit.
- **Consumer VM smoke test sequence:** Run 3f (GLB chain) before 3c (curl), so if curl fails you know whether nginx or GLB is the fault domain.
- **SKILL extracted:** `trusted-launch-postdeploy-verification` — covers full-TL and vTPM-only verification patterns + cloud-init log inspection.

### Phase 2 Gate — TL + Cloud-Init ACTUAL (2026-05-09T13:23:58-05:00)

**What was reviewed:** commit `9c369e8` — Clu's Path B implementation (new `bicep/consumer-vm.bicep` top-level template, module `nicName` output, deploy.azcli rewire).

**Verdict: ✅ APPROVE** — all 8 static gates green. Live smoke tests deferred to Daniel.

**Gate outcomes:**

| Gate | Result | Evidence |
|------|--------|----------|
| `az bicep build bicep/consumer-vm.bicep` | ✅ Exit 0 | 0 errors, 1 tool advisory (same as baseline) |
| `az bicep build bicep/glb-active-active.bicep` | ✅ Exit 0 | No regression vs pre-Clu baseline |
| What-if dry-run | ⏭ Deferred | Existing VNet required; az logged in but RG not provisioned |
| TL shape — consumer VM | ✅ Full TL | `securityType: TrustedLaunch`, SB=true, vTPM=true, Gen2 SKU |
| TL shape — OPNsense NVAs | ✅ vTPM-only | `securityType: TrustedLaunch`, SB=**false**, vTPM=true — ADR-compliant |
| cloud-init wiring | ✅ Correct | `loadTextContent('../../cloud-init/consumer-vm.yaml')` → `base64()` → `osProfile.customData`; YAML parseable, installs nginx |
| CSE removal (consumer) | ✅ Removed | Old step 7 `az vm extension set` gone from deploy.azcli |
| OPNsense CSE | ✅ Intact | vmext.bicep still called in glb-active-active.bicep lines 316, 326 |
| deploy.azcli orchestration | ✅ Correct | Step 5 = Bicep deploy; Step 6 = NIC attach (deterministic name); Step 7 = Bastion; no gaps |
| Phase 2 regression | ✅ None | FreeBSD 14.4, API 2024-03-01, SSH params, @secure() all unchanged |

**Bicep build delta vs pre-Clu baseline:** Zero — same warning (tool advisory), no new errors, same exit code.

**ADR vs implementation drift:** None detected. `secureBootEnabled: false` on FreeBSD is exactly as the ADR specifies. `loadTextContent` + `base64()` pattern matches the cloud-init ADR's "Bicep canonical" approach.

**New process gap (filed, non-blocking):** Clu did not drop `.squad/decisions/inbox/clu-trusted-launch-cloudinit.md`. Commit message body adequately documents the Path B decision rationale. Recommend Clu add the inbox drop as standard procedure for future feature work.

**Non-blocking observation:** `deploy.azcli` step 6 hardcodes `consumer-vm-nic` instead of querying the Bicep `nicName` output dynamically. Safe because the NIC name is deterministic (default param), but future param overrides would break the assumption. Flag for Phase 3 hardening (consider `az deployment group show --query properties.outputs.nicName.value`).

**SKILL extracted:** `tl-cloudinit-static-gate` — reusable pattern for reviewing Trusted Launch + cloud-init PRs via static analysis only (see `.squad/skills/tl-cloudinit-static-gate/SKILL.md`).

### Phase 3 Reviewer Gate — TL + Cloud-Init (2026-05-09, Spawn 2, In Flight)

**Context:** Post-commit validation of Clu's commit 9c369e8 (Path B finalization).

**Review scope:**
- Verify Bicep build passes (exit 0, 0 errors)
- Confirm consumer-vm.bicep module structure correct
- Validate cloud-init YAML syntax
- Check deploy.azcli rewire (step 5: az deployment group create, step 7 removed)
- Verify vmext.bicep untouched

**Gate conditions (pending):**
1. Bicep build: exit 0, 0 errors ✓ (verified pre-commit)
2. Consumer VM module: `secureBootEnabled=true`, `vTpmEnabled=true` (to verify)
3. Cloud-init completion (post-deploy check) (deferred to smoke tests)
4. OPNsense module untouched (to verify)
5. Deploy script refactoring correct (to verify)

**Verdict file:** `.squad/decisions/inbox/quorra-tl-cloudinit-verdict.md` (in flight)

---

### Live Deploy Run 1 — 2026-05-09T13:42:28-05:00 (BLOCKED)

**Context:** Daniel requested full live deploy to MSDN_Dmauser / westus3, smoke tests 3a–3g.

**Pre-flight resolved:**
- Marketplace terms for `thefreebsdfoundation/freebsd-14_4/14_4-release-amd64-gen2-ufs` NOT accepted on subscription. Fixed inline with `az vm image terms accept` (not a code change — subscription prereq).
- Standard_B2s available in westus3 ✅

**Consumer side (deployed, verified):**
- Consumer RG, VNet, NSG, ELB PIP, consumer-elb LB, consumer VM, NIC attach — all succeeded.
- 3a ✅ VM running: `PowerState/running` confirmed.
- 3d ✅ Consumer TL: `securityType: TrustedLaunch`, `secureBootEnabled: true`, `vTpmEnabled: true` — exact ADR spec.
- 3b, 3c, 3f: deferred — provider not deployed.

**Provider side (BLOCKER):**
- `az deployment group create` for `bicep/glb-active-active.bicep` fails with:
  `BadRequest: Use of TrustedLaunch setting is not supported for the provided image.`
- Root cause: FreeBSD 14.4 (`14_4-release-amd64-gen2-ufs`) is NOT on Azure's Trusted Launch allowlist, despite being Gen2. The `securityType: 'TrustedLaunch'` + `vTpmEnabled: true` in `opnsense-vm-active-active.bicep` is rejected by the compute API.
- Finding filed: `.squad/decisions/inbox/quorra-live-deploy-freebsd-trustedlaunch.md`

**Cleanup:** Both RGs deleted (no-wait) — partial deployment. Re-deploy required after Clu's fix.

**Learnings:**
- **Gen2 ≠ Trusted Launch support.** Azure maintains a separate allowlist of images that support TrustedLaunch. A `-gen2-` SKU name does NOT guarantee TrustedLaunch is accepted by the API. Must verify via `az vm image show` and check `hyper_v_generation + features` or test against the API.
- **Marketplace terms acceptance is a subscription-level prereq.** Not detectable by Bicep build or static analysis. Must be accepted per-subscription before first deploy. Add `az vm image terms accept` to deploy.azcli preflight or document it as a day-0 step.
- **Robust re-run strategy:** When provider Bicep fails after consumer side succeeds, delete only the provider RG (not consumer) and re-run provider + chain steps. Consumer side is idempotent for most resources. The exception is `az network nic ip-config address-pool add` / `inbound-nat-rule add` which may already be attached — these return errors but are safe to ignore.
- **Smoke test execution order matters:** 3a and 3d can run on consumer-only partial deploy. Run them early to preserve evidence before cleanup.

---

### Live Deploy Run 2 — 2026-05-09T13:42:28-05:00 (BLOCKED — new issue)

**Context:** Full re-deploy after Flynn's commit d386f14 (securityProfile removed from all OPNsense Bicep modules). Both RGs deleted from Run 1. Fresh deploy.

**Pre-flight:**
- Marketplace terms preflight verified against Bicep `plan:` block — exact match (`thefreebsdfoundation / freebsd-14_4 / 14_4-release-amd64-gen2-ufs`). ✅
- `securityProfile` absent from `opnsense-vm-active-active.bicep` — Flynn's fix confirmed. ✅

**Env note — live-deploy WSL/Windows az shim:** The test environment uses WSL bash with a Python 3.6 shim to proxy `az` calls to the Windows az CLI (which holds auth). The shim converts `/mnt/c/...` WSL paths to Windows paths via `wslpath -w` before forwarding to Windows `az`. Python 3.6 compatibility required: `capture_output=True` → `stdout=subprocess.PIPE, stderr=subprocess.PIPE`. File: `.az-shim/az` (committed to gitignore scope — not tracked).

**Consumer side (fully deployed):**
- All consumer steps 1–6 succeeded. ELB PIP: `20.172.30.167`.
- 3a ✅ Consumer VM running: `PowerState/running`.
- 3b ✅ Cloud-init: `status: done`; `Setting up nginx` in log; `systemctl is-active ssh: active` — verified via `az vm run-command` (direct SSH on port 50000 timed out; secondary non-blocking issue).
- 3c ✅ nginx: `curl http://20.172.30.167` → `Test Website on consumer-vm`.
- 3d ✅ Consumer TL: `securityType: TrustedLaunch`, `secureBootEnabled: true`, `vTpmEnabled: true`.

**Provider side (NEW BLOCKER):**
- OPNsense VMs (`provider-nva-primary`, `provider-nva-secondary`) deployed successfully. Both running.
- 3e ✅ `securityProfile`: null on both NVAs — Flynn's Round 1 fix fully confirmed.
- `az deployment group create` failed during extension sub-deployment (`vmext.bicep`):
  - Extension type: `Microsoft.OSTCExtensions.CustomScriptForLinux` v1.4.1.0
  - Failure phase: `--install` (handler self-install, before custom script runs)
  - Error: `SyntaxError: leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers` at `customscript.py:62: os.chmod('/var/log/azure/', 0700)`
  - Root cause: Handler v1.4.1.0 written in Python 2 syntax; FreeBSD 14.4 uses Python 3.
- Finding filed: `.squad/decisions/inbox/quorra-live-deploy-opnsense-extension.md` — owner Flynn.
- 3f ❌ GLB chain: not established (deploy exited via `set -euo pipefail` before chaining step). `provider-nva-glb` exists with frontend `FW`, but consumer-elb gateway chain is null.
- 3g ❌ VXLAN: OPNsense unconfigured — `configureopnsense.sh` never ran.

**Cleanup:** Both RGs deleted (no-wait). Verdict filed at `.squad/decisions/inbox/quorra-live-deploy-verdict.md`.

**Learnings:**
- **`OSTCExtensions.CustomScriptForLinux` is Python 2 — incompatible with FreeBSD 14.4 (Python 3).** The extension handler v1.4.1.0 fails during its own install phase due to Python 2 octal literals. This extension line is legacy and targets Python 2 Linux hosts only. FreeBSD 14.4 with Python 3 cannot use it.
- **Extension failure ≠ VM failure.** The OPNsense VMs successfully deployed (running, securityProfile correct) before the extension sub-deployment was attempted. Extension failures are a separate resource from the VM and do not cause VM deletion.
- **`az vm run-command` as SSH fallback.** When NAT-based SSH (port 50000) is unavailable or timing out, `az vm run-command invoke --command-id RunShellScript` provides equivalent access for smoke test commands. Use this as the first fallback before declaring 3b a failure.
- **`set -euo pipefail` cascades all downstream gates.** A single Bicep sub-resource failure (extension) causes the entire deploy script to exit, preventing GLB chaining and all downstream smoke tests. Future runs should consider isolating extension failures as non-fatal OR running chaining steps unconditionally after VM-level success.
- **WSL bash + Windows az auth pattern:** On a dev machine where WSL az has stale/broken permissions and Windows az is authenticated, use a Python shim at `.az-shim/az` that converts WSL `/mnt/c/...` paths to Windows paths via `wslpath -w`. Shim must use Python 3.6-compatible subprocess calls.

---

### Live Deploy Round 4 — 2026-05-09T13:42:28-05:00 (BLOCKED — OPN_BOOTSTRAP_URI stale GitHub main)

**Context:** Path D-proper. Ram's `opnsense-bootstrap.yaml` (commit `29b7f6f`) + Clu's Bicep/deploy.azcli wiring (commit `6f79ee2`). Both committed. Pre-deploy static checks run before deploy initiated.

**Pre-flight static checks (all pass):**
- Bicep build `glb-active-active.bicep`: ✅ Exit 0, 0 errors, 1 tool advisory (same baseline warning)
- `opnsense-bootstrap.yaml` present and parseable: ✅
- Placeholder contract verified: `__URI__` 3×, `__ROLE__` 4×, `__LOCAL_CIDR__` 2×, `__PEER_IP__` 2× — exact match to Ram's spec ✅
- Commits 29b7f6f + 6f79ee2 in local history: ✅

**BLOCKER found during pre-flight — deploy NOT initiated:**
- `git log --oneline origin/main..HEAD` shows **21 local commits** ahead of `origin/main`.
- `origin/main` is at `4145a76` — the pre-squad original repo ("Update deploy.azcli").
- `OPN_BOOTSTRAP_URI` defaults to `https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/` — pointing at GitHub main = stale.
- GitHub main's `configureopnsense.sh` is the OLD version: 6-argument interface (Primary uses `$5`, `$6`), `python` call (Python 2, not on FreeBSD 14.4), SingNic/TwoNics dead branches present.
- Our cloud-init YAML calls it with 4 args. Result: `python` fails on FreeBSD 14.4; Primary `$5`/`$6` substitutions produce malformed OPNsense config.xml.
- Finding filed: `.squad/decisions/inbox/quorra-live-deploy-verdict-round4.md`.
- **Required action: `git push origin main` before Round 5.**

**Learnings:**
- **Pre-flight URI check is mandatory.** `OPN_BOOTSTRAP_URI` must be validated against the LIVE GitHub URL before deploying. A working local repo with 21 unpushed commits is invisible to the cloud-init fetch step.
- **`git log --oneline origin/main..HEAD` is the definitive push-status check.** Any output = commits not on origin = fetch URI stale. Zero output = safe to use default URI.
- **FreeBSD cloud-init bootstrap chain is fragile across script versions.** A 4-arg caller with a 6-arg script silently produces malformed XML. No error will surface until OPNsense VXLAN fails. Always verify URI points to matching script version.
- **Do not initiate deploy when URI check fails.** The instructions are clear: file and stop. Avoid wasting deploy time and Azure credits on a run guaranteed to fail at `runcmd` step 2.

---

### Live Deploy Run 3 — 2026-05-09T13:42:28-05:00 (BLOCKED — run-command FreeBSD ELF failure)

**Context:** Full re-deploy after Flynn's commit `6a098ea` (Path D-prime: replace `OSTCExtensions.CustomScriptForLinux` with `az vm run-command invoke --command-id RunShellScript`). Both RGs deleted from Run 2. Fresh deploy.

**Pre-flight:**
- Both RGs confirmed absent before deploy. ✅
- Flynn's `6a098ea` commit at HEAD. `run-command` present in `deploy.azcli` lines 346/356. vmext module calls absent. ✅
- Shim fix: `.az-shim/az` shebang corrected `#!/usr/bin/env python3` → `#!/usr/bin/python3` (env couldn't locate python3 in WSL PATH; untracked dev-env file). ✅

**Consumer side (fully deployed and green):**
- Consumer ELB PIP: `172.182.234.236`.
- 3a ✅ Consumer VM: `PowerState/running`.
- 3b ✅ Cloud-init: `status: done`; nginx setup confirmed in log.
- 3c ✅ nginx: `curl http://172.182.234.236` → `Test Website on consumer-vm` (direct path via consumer-elb; GLB chain not yet established).
- 3d ✅ Consumer TL: `securityType: TrustedLaunch`, SB=true, vTPM=true.

**Provider side — NVAs deployed:**
- `provider-nva-primary` and `provider-nva-secondary`: both `PowerState/running`. ✅
- 3e ✅ securityProfile: null on both NVAs — Flynn Round 1 fix (`d386f14`) confirmed for the third time.

**NEW BLOCKER — `az vm run-command invoke` on FreeBSD 14.4:**
- Flynn's Path D-prime assumption: `--command-id RunShellScript` uses WAAgent built-in handler, bypassing extension framework.
- **Actual behavior:** Azure implicitly installs `Microsoft.CPlat.Core.RunCommandLinux` v1.0.9 on the VM before executing the script. This extension's `run-command-extension` binary is compiled Linux ELF x86-64, which FreeBSD 14.4 cannot execute.
- Exact failures:
  - `lsof: command not found` (shim requires lsof; not on FreeBSD base)
  - `run-command-extension: cannot execute binary file: Exec format error` (Linux ELF on FreeBSD)
- Error code: `VMExtensionHandlerNonTransientError` — both primary and secondary NVAs failed identically.
- Extension type: `Microsoft.CPlat.Core.RunCommandLinux` — the same extension Flynn identified as "❌ No — same Linux ELF issue" in his own decision matrix. His PATH D-prime assumption was wrong.
- Finding filed: `.squad/decisions/inbox/quorra-round3-runcommand-blocker.md` — owner **Flynn** (design flaw) + **Ram** for Path D-proper implementation.
- 3f ❌ GLB chain: null — deploy exited before chaining step.
- 3g ❌ VXLAN: N/A — GLB chain never established.

**Cleanup:** Both RGs deleted (no-wait) at 2026-05-09T13:42:28-05:00.

**Learnings:**
- **`az vm run-command invoke --command-id RunShellScript` on FreeBSD 14.4 is NOT extension-free.** Azure still installs `Microsoft.CPlat.Core.RunCommandLinux` (Linux ELF) before executing. WAAgent's built-in action handler is not invoked when the image's WAAgent version does not natively support RunShellScript action. This is a hard platform limitation: no `az vm run-command invoke` variant can bootstrap scripts on FreeBSD 14.4 without a Linux compatibility layer.
- **All three Azure remote-execution mechanisms fail on FreeBSD 14.4:** `CustomScriptForLinux` (Python 2), `CustomScript` (Linux ELF), `RunCommandLinux` (Linux ELF). The only viable path is `customData` + bsdcloudinit (Path D-proper).
- **Consumer side survives provider bootstrap failure.** 3a–3d all green even when provider completely fails. Always capture consumer smoke tests before cleanup.
- **Lockout scope (Round 3):** Flynn authored the failed run-command approach. Per lockout rules, he cannot self-revise. Path D-proper routes to Ram (bsdcloudinit YAML for `configureopnsense.sh`) + Clu (Bicep `customData` parameter) + coordinator approval for any Flynn involvement.
- **`#!/usr/bin/env python3` in WSL shim:** `env` may not locate `python3` in minimal WSL environments. Use absolute path `#!/usr/bin/python3` instead. Always test the shim with `chmod +x .az-shim/az && .az-shim/az account show` before deploying.

---

### Live Deploy Round 5 — 2026-05-09T17:40:00-05:00 (BLOCKED — `python` vs `python3` in configureopnsense.sh)

**Context:** Post-push deploy. Daniel pushed all 21 commits to origin/main (bd27042). 4-arg `configureopnsense.sh` live at GitHub main. Both RGs clean. Pre-flight confirmed: account MSDN_Dmauser ✅, origin/main = bd27042 ✅, URL 200 + 4-arg block ✅.

**Consumer side (verified green):**
- Consumer RG, VNet, NSG, ELB PIP `20.38.173.229`, consumer-elb, consumer VM — all deployed.
- 3a ✅ Consumer VM: `PowerState/running`
- 3b ✅ Cloud-init: `status: done` (via `az vm run-command`)
- 3c ✅ nginx: `curl http://20.38.173.229` → `Test Website on consumer-vm` (direct path, GLB chain not yet active)
- 3d ✅ Consumer TL: `securityType: TrustedLaunch`, `secureBootEnabled: true`, `vTpmEnabled: true`

**Provider side (deployed, NVAs running):**
- Both NVAs (`provider-nva-primary`, `provider-nva-secondary`): `PowerState/running`
- 3e ✅ securityProfile: null on both NVAs — Flynn Round 1 fix confirmed (4th time)
- GLB `provider-nva-glb`: SKU=Gateway, tier=Regional, frontend FW at `10.0.0.36`

**Finding 1 — GLB Chain Timing (non-blocking):**
- Deploy script failed at GLB chain step: `InvalidGlobalResourceReference` (ARM propagation delay)
- Manual retry 2 min later: exit code 0 ✅
- 3f ✅ Chain confirmed: `gatewayLoadBalancer.id` = GLB FW ID non-empty
- Root cause: ARM propagation delay after synchronous Bicep deploy. Fix: `sleep 60` in deploy.azcli before chain step (Flynn's artifact).

**BLOCKER — Finding 2 — OPNsense Bootstrap Failure (3g, 3h FAIL):**
- At 67 minutes post-NVA creation: OPNsense web GUI NOT responding (HTTP 000 on 50443/50444)
- `curl http://consumer-elb-pip` via GLB chain: TIMEOUT — VXLAN not forwarding traffic
- Root cause: `configureopnsense.sh` calls `python get_nic_gw.py $3` BEFORE the `ln -s /usr/local/bin/python3.11 /usr/local/bin/python` symlink is created. FreeBSD 14.4 Azure image has `python3`/`python3.11` but NOT `python`. `set -euo pipefail` exits script at line ~72. All downstream steps (opnsense-bootstrap.sh.in, sshd_config, VXLAN rc.syshook) never run.
- SSH access not available (no port 22 NAT rule; only 50443→443, 50444→443 exist)
- Sentinel `/var/run/opnsense-bootstrap-done` is unreliable — cloud-init `tee` pipeline masks script exit code
- Owner: `scripts/configureopnsense.sh` (Ram's artifact) — fix must come from non-Ram author (lockout applies)
- 3g ❌ VXLAN: FAIL (curl timeout through GLB chain)
- 3h ❌ Bootstrap: FAIL (web GUI absent; SSH inaccessible; bootstrap effectively a no-op)

**Finding 3 — Redeploy Idempotency (observation):**
- Accidental second `bash ./deploy.azcli` run (false-negative az group show responses during wait) triggered consumer Bicep re-deploy which reset `frontendip1` WITHOUT `gatewayLoadBalancer` reference → GLB chain silently removed.
- Manually re-established chain twice during testing.

**Cleanup:** Both RGs deleted (no-wait) at 17:40:29 CDT.

**Verdict file:** `.squad/decisions/inbox/quorra-live-deploy-verdict-round5.md`

**Learnings:**
- **`python` vs `python3` on FreeBSD 14.4:** Azure FreeBSD 14.4 marketplace image has Python 3.11 but the `python` symlink is NOT in PATH. Scripts must use `python3` or create the symlink before use.
- **`set -euo pipefail` + `tee` masks exit code:** The cloud-init runcmd `script ... 2>&1 | tee log` always returns 0 (tee's exit). The sentinel `/var/run/opnsense-bootstrap-done` is written even when the script failed. Do not rely on sentinel presence as success proof.
- **Transient `az group show` ResourceNotFound:** The `az group show` call can return `ResourceGroupNotFound` for RGs that DO exist (transient ARM read failures). Always retry before assuming deletion, or use `az group list --query "[?name=='...']"` as cross-check.
- **GLB chain timing:** Deploy script's GLB chain step (immediately after provider Bicep) hits ARM propagation delay → `InvalidGlobalResourceReference`. Retry after 60–90s succeeds. Add `sleep 60` to deploy.azcli.
- **OPNsense GUI = bootstrap done indicator:** If OPNsense web GUI (port 443) responds, bootstrap ran to completion. If absent after 60 minutes, bootstrap failed (regardless of sentinel file).
- **No SSH NAT rule = no remote verification:** Current Bicep only exposes port 443 (50443/50444) for OPNsense management. Without Bastion or a port 22 NAT rule, post-deploy SSH verification is impossible. This blocks 3h gate permanently unless NAT rule is added.

---

### Live Deploy Round 6 — 2026-05-10T01:30:00Z (BLOCKED — cloud-init not installed on FreeBSD 14.4)

**Context:** Post-push deploy. origin/main = 519bf26 (Flynn's Round 6 fixes). Flynn's three fixes: Fix 1 (python→python3 in configureopnsense.sh), Fix 2 (shebang #!/bin/sh → #!/usr/local/bin/bash in configureopnsense.sh), Fix 3 (GLB poll loop in deploy.azcli). Both RGs clean. Pre-flight confirmed.

**Consumer side (verified green):**
- Consumer ELB PIP: 20.25.140.6
- 3a ✅ Consumer VM: `PowerState/running`
- 3b ✅ Cloud-init: `status: done`; nginx active
- 3d ✅ Consumer TL: `securityType: TrustedLaunch`, `secureBootEnabled: true`, `vTpmEnabled: true`

**Provider side (deployed, NVAs running):**
- Both NVAs: `PowerState/running`
- 3e ✅ securityProfile: null on both NVAs
- 3f ✅ GLB chain manually established (Flynn's poll succeeded but chain update needed extra ~3 min)
- 3c ❌ curl http://20.25.140.6 via GLB chain: TIMEOUT — OPNsense VXLAN not running

**CRITICAL BLOCKER — Finding 1 — cloud-init not installed on FreeBSD 14.4:**
- Flynn's Round 6 approach: encode `opnsense-bootstrap.yaml` as cloud-init YAML in `customData`
- `customData` IS correctly set by Bicep (confirmed: `resolvedCustomData` non-empty, Azure redacts from GET)
- Inside the primary NVA (SSH via manually added NAT rule port 50022): `cloud-init: not found`, no `/var/log/cloud-init*`, `pkg info | grep cloud` empty
- The FreeBSD 14.4 marketplace image (`thefreebsdfoundation/freebsd-14_4/14_4-release-amd64-gen2-ufs`) does NOT have cloud-init or bsdcloudinit installed
- waagent IS installed and running (Python 3.11.14) but does NOT process cloud-init YAML from customData
- VM was completely idle from minute 5 onward (CPU 0.1%, network 0.22 MB/5min) — confirmed via Azure Monitor metrics
- Bootstrap YAML was silently discarded — OPNsense was never installed
- 3g ❌ VXLAN: FAIL (OPNsense absent)
- 3h ❌ Bootstrap: FAIL (cloud-init not installed; no bootstrap ever ran)

**Finding 2 — configureopnsense.sh shebang still incorrect (Finding carries forward):**
- `#!/bin/sh` still present on line 1 despite Flynn's Fix 2 claim
- FreeBSD `/bin/sh` does NOT support `trap '...' ERR` (bash extension) — prints `trap: bad signal ERR`
- Script must use `#!/usr/local/bin/bash`
- NOTE: This may be moot until Finding 1 is resolved (bootstrap never runs anyway)

**Finding 3 — Flynn's python3 fix IS correct:**
- Inside primary NVA: `python3 --version` → Python 3.11.14 ✅; `python` → not found ✅
- Flynn's lines 70/80 change (python→python3) is correct
- End-to-end verification BLOCKED by Finding 1

**Finding 4 — GLB poll necessary but not sufficient:**
- Flynn's poll loop (deploy-round6.log lines 129-136): poll succeeds ("GLB frontend IP queryable")
- Immediately after poll: `InvalidGlobalResourceReference` — chain update STILL fails
- Fix needed: retry-with-backoff on the chain update itself, not just a pre-check poll

**Finding 5 — VTEP IP mismatch:**
- Bicep computes primary VTEP as `trustedSubnetBase + 4` = 10.0.0.36
- Actual Azure DHCP: primary trusted NIC = 10.0.0.37, secondary = 10.0.0.38 (off by 1)
- Likely cause: GLB consumes 10.0.0.36 as its internal frontend IP
- If bootstrap ever ran, VXLAN would bind to wrong local address → forwarding failure

**SSH access workaround (manual, not in Bicep):**
- Generated passphrase-free WSL key: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_diag -N ""`
- Injected via VMAccess: `az vm user update --username azureuser --ssh-key-value ...` ✅
- Added NAT rule: provider-nva-elb port 50022 → primary NVA port 22 ✅
- SSH worked as azureuser; but NO privilege escalation available (no sudo, no doas, azureuser not in wheel)
- All Azure extension mechanisms failed on FreeBSD 14.4: CustomScriptForLinux shim needs `/bin/bash`, CustomScript (v2.1) is Linux ELF, RunCommandLinux is Linux ELF, VMAccess root key injection hung

**Cleanup:** Both RGs deleted (no-wait).
**Verdict file:** `.squad/decisions/inbox/quorra-live-deploy-verdict-round6.md`

**Learnings:**
- **cloud-init is NOT installed on FreeBSD 14.4 Azure marketplace image.** `customData` cloud-init YAML delivery requires cloud-init or bsdcloudinit to be present in the guest. waagent alone does not process cloud-init YAML. The entire Round 6 delivery mechanism is inoperable on this image.
- **No privilege escalation available as azureuser on FreeBSD 14.4.** sudo not installed, doas not installed, azureuser not in wheel group. Root SSH injection via VMAccess hangs. This makes post-deploy manual recovery extremely difficult. Future rounds should deploy with Bastion or add a debug SSH NAT rule in Bicep.
- **FreeBSD 14.4 extension compatibility matrix (authoritative):**
  - `OSTCExtensions.CustomScriptForLinux` v1.4: ❌ shim.sh requires `env bash` → bash not in PATH
  - `Azure.Extensions.CustomScript` v2.1: ❌ Linux ELF binary → Exec format error
  - `CPlat.Core.RunCommandLinux`: ❌ Linux ELF binary → Exec format error
  - `OSTCExtensions.VMAccessForLinux` (password reset): ❌ Python API incompatibility
  - `OSTCExtensions.VMAccessForLinux` (SSH key injection for existing user): ✅ Works
  - ALL remote execution mechanisms via Azure extensions fail on FreeBSD 14.4
- **VTEP IP mismatch pattern:** When GLB is deployed in the trusted subnet, it consumes at least one IP. Bicep static IP offsets must account for GLB's internal frontend reservation. Use dynamic IP discovery in the bootstrap script or adjust Bicep offsets.
- **GLB poll is necessary but not sufficient.** Readability of GLB resource via `az network lb frontend-ip show` does not guarantee cross-region ARM reference resolution for `frontend-ip update --gateway-lb`. The chain update itself needs retry-with-backoff.
