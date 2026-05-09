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
