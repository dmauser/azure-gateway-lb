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
