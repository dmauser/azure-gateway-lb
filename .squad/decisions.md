# Squad Decisions

## Active Decisions

### Phase 0: Strategic Decisions (2026-05-08)
- **Q1 IaC strategy:** Bicep is canonical. ARM/ folder retained as **compiled output only** — auto-generated from Bicep, versioned, never hand-edited.
- **Q2 main-two-nics.bicep:** Deprecate. Move to `archived/` (preferred) or delete. Currently does not compile (BCP037).
- **Q4 SingNic/TwoNics modes:** Remove dead-code branches in `configureopnsense.sh`. Keep only the active-active path.
- **Q5 leaked password:** Daniel declined to rotate externally. Repo will scrub `P@ssw0rd!1234&Azure` from `main-two-nics.parameters.json` and add `@secure()` to all password params, but the credential remains in git history. ⚠️ Anyone who cloned this repo has that password.

### Phase 1: IaC Consolidation
- **Bicep as canonical source:** `bicep/glb-active-active.bicep` + 21 modular components
- **Compiled ARM:** `bicep/glb-active-active.json` auto-generated, checked in with version
- **Deprecated templates:** `main-two-nics.bicep` moved to `archived/` (BCP037 compilation error, security password hardcoded)
- **Stale files cleaned:** `bicep/glb-active-active.bkp`, `bicep/temp.json`, `ARM/glb-active-active.json` removed

### Phase 1: Security Hardening
- **VM Extension API:** `vmext.bicep` updated from `2015-06-15` → `2024-07-01`
- **Secure password parameters:** `@secure()` decorator added to all `TempPassword` params across VM modules
- **OPNsense image EOL:** FreeBSD 12.0 (MicrosoftOSTC) is EOL; migrate to `thefreebsdfoundation` FreeBSD 14.4 (pending compatibility verification)

### Phase 1: Deploy Script Modernization
- **SSH keys default:** Consumer VM uses SSH key auth (env var `SSH_PUBLIC_KEY`), not passwords
- **Env var contract:** `SUBSCRIPTION_ID`, `RG_CONSUMER`, `RG_PROVIDER`, `LOCATION`, `ADMIN_USERNAME`, `BASTION_DEPLOY` replace hardcoded values
- **Synchronous provider deploy:** Bicep template deployment now waits (removed `--no-wait`) before chaining
- **Consumer ELB PIP:** Explicit creation before LB (fixes missing `PublicIPconsumer-elb` reference)
- **Idempotent script:** No interactive prompts, full error handling, `set -euo pipefail`

### Phase 1: Scripts Refactor
- **CRLF → LF:** `configureopnsense.sh` line endings corrected
- **Dead code removed:** `SingNic` and `TwoNics` branches removed; only `Primary`/`Secondary` active-active modes remain
- **Unified parameter contract:** Both roles now accept identical 4-argument signature (URI, Role, LocalCIDR, PeerIP)
- **VXLAN consolidation:** Shared config for both roles; no branching on roles for tunnel setup

### Phase 3: Trusted Launch + Cloud-Init Implementation (2026-05-09)

#### Path Decision: Consumer VM Bicep Module (Path B)

**Author:** Clu (IaC Engineer)  
**Commits:**
- `86732d8` — `feat(iac): Trusted Launch + cloud-init for consumer and OPNsense VMs` (initial)
- `9c369e8` — `feat(iac): Path B — top-level consumer-vm.bicep + deploy.azcli rewire` (Path B)

**Implementation Path:** Path B chosen (per Quorra finding). Rationale: Phase 0 Q1 decision — "Bicep is canonical; deploy.azcli is an orchestrator, not a VM author." Created `bicep/modules/VM/consumer-vm.bicep` and top-level `bicep/consumer-vm.bicep`.

**Trusted Launch Changes:**
- **Consumer VM:** `secureBootEnabled=true`, `vTpmEnabled=true` (Ubuntu 22.04 Gen2 with signed UEFI shim)
- **OPNsense VMs:** `secureBootEnabled=false`, `vTpmEnabled=true` (FreeBSD 14.4 — no signed shim)
- **Image:** Consumer uses `Canonical/0001-com-ubuntu-server-jammy/22_04-lts-gen2` (explicit Gen2 required)

**Cloud-Init Track:**
- Cloud-init YAML at `bicep/cloud-init/consumer-vm.yaml` (nginx setup)
- Consumer VM module implements `customData: base64(loadTextContent(...))`
- `deploy.azcli` step 5 rewired: `az deployment group create --template-file bicep/consumer-vm.bicep`
- Step 7 (`az vm extension set` for CSE) removed; cloud-init handles nginx
- Both Bicep templates build clean (exit code 0)

#### Validation Checkpoint (Quorra)

**Status:** Reviewer gate in flight. Verdict pending at `.squad/decisions/inbox/quorra-tl-cloudinit-verdict.md`.

**Pre-commit findings (quorra-tl-cloudinit-validation.md):**
- ✅ Bicep build baseline: clean (exit 0)
- ✅ ADR Finding 3: `securityType: 'TrustedLaunch'` required for vTPM-only — correctly implemented
- ✅ ADR Finding 4: CSE removal scope is `deploy.azcli` step 7, not `vmext.bicep` — verified, `vmext.bicep` untouched
- ⚠️ ADR Finding 2: Image ref mismatch (ADR says `14_1`, codebase uses `14_4`) — update ADR command when running
- ✅ Consumer Bicep Integration: complete; future task to wrap full consumer side in `bicep/consumer.bicep`
- ⏳ What-If Validation: deferred to post-commit smoke tests per `docs/validation/trusted-launch-cloudinit-checklist.md`

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
