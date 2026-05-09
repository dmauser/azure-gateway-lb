# Flynn — History

## Project Context
- **Project:** azure-gateway-lb — Azure Gateway Load Balancer lab with OPNsense NVAs
- **User:** Daniel Mauser
- **Stack:** Bicep, ARM JSON, Azure CLI, OPNsense (FreeBSD), VXLAN
- **Layout:** `bicep/`, `ARM/`, `scripts/`, `deploy.azcli`, `linux-vxlan.azcli`

## Learnings

### 2026-05-08: Architecture Audit - Critical Blockers Identified

**Session:** Full architecture audit on request from Daniel Mauser  
**Finding:** Lab is documented but operationally broken - not deployable end-to-end  

#### Critical Issues Discovered:
1. **Missing PIP Resource** - `deploy.azcli` creates consumer-elb without public IP, then tries to reference non-existent `PublicIPconsumer-elb`. This is the immediate blocker preventing any end-to-end deployment.
2. **Dual IaC Maintenance Burden** - 21 Bicep modules + ARM folder create maintenance split; no clear source of truth. Bicep is richer but ARM folder suggests legacy dual-path.
3. **Non-Idempotent Script** - Interactive prompts, hardcoded subscription names, inconsistent `--no-wait`, incomplete error handling. Script fails on retry and in Cloud Shell.
4. **Template Deployment Sync** - Provider GLB template uses `--no-wait` but chaining immediately follows without polling for readiness.
5. **Weak Security Defaults** - Hardcoded passwords (Msft123Msft123), no managed identity, no SSH key option, default OPNsense creds.

#### Architecture Review Completed:
- ✓ Traffic flow documented in README matches template architecture
- ✓ All referenced media files exist and are current
- ✓ Bicep modules well-structured (vnet, lb, gwlb, VM, resource-group)
- ✗ README link to GLB docs should reference GA, not preview
- ✗ "Coming soon" placeholders for Layer 7 and IDS are misleading

#### Deliverable:
- Audit report written to `.squad/decisions/inbox/flynn-architecture-audit.md`
- Three-phase remediation plan: Phase 1 (unblock), Phase 2 (modernize), Phase 3 (polish)
- Clear strategic question for Daniel: Consolidate on Bicep, retire ARM folder

#### Recommendations:
- Phase 1: Fix PIP creation, add deployment polling, remove interactive prompts, complete cleanup
- Phase 2: Make Bicep canonical, add managed identity, improve docs
- Phase 3: Trusted Launch, cloud-init, CI/CD pipeline, troubleshooting guide

**Estimated Effort:** 7-10 days total across 3 phases (Clu owns tactical, Flynn owns architecture/validation, Ralph owns CI/CD)

---

### 2026-05-08: Phase 1 — deploy.azcli Rewrite Complete

**Session:** Phase 1 execution on request from Daniel Mauser  
**Deliverable:** Fully rewritten `deploy.azcli` — passes `bash -n`, CI-safe, no interactive prompts

#### Changes Made:
1. **`set -euo pipefail`** added — script now aborts on any error
2. **Preflight guards:** `az account show` login check; `az bicep version || az bicep install`; `SSH_PUBLIC_KEY` required-var guard; `@file` path existence check
3. **Env-var contract established** — `SSH_PUBLIC_KEY` (required), `LOCATION`, `RG_CONSUMER`, `RG_PROVIDER`, `ADMIN_USERNAME`, `BASTION_DEPLOY`, `SUBSCRIPTION_ID`
4. **consumer-elb-pip created explicitly** (Standard Static) before `az network lb create` — fixes the primary blocker (`PublicIPconsumer-elb` was never created)
5. **Consumer VM uses SSH key auth** (`--ssh-key-values "$SSH_PUBLIC_KEY"`) instead of password
6. **Provider Bicep deployment is synchronous** — no `--no-wait`; uses local `bicep/glb-active-active.bicep` via `$SCRIPT_DIR`
7. **TempPassword auto-generated** (`GlbLab$(openssl rand -hex 6)Az1!`) — ephemeral, complexity-compliant, not hardcoded
8. **Bastion is optional** — gated on `BASTION_DEPLOY=true`
9. **Cleanup section** — proper `cleanup()` function as commented-out block
10. **Subscription selection** — `SUBSCRIPTION_ID` env var replaces hardcoded `VSE-SUB`/`DMAUSER-MS`

#### GLB Chaining Pattern (key for future agents):

The GLB "bump-in-the-wire" chain requires two steps after both sides are deployed:

```bash
# Step 1: Get GLB frontend IP config resource ID (lb name = provider-nva-glb, frontend name = FW)
glbfeid=$(az network lb frontend-ip show \
    -g "$provider_rg" \
    --lb-name provider-nva-glb \
    --name FW \
    --query id \
    --output tsv)

# Step 2: Chain consumer ELB frontend to GLB (consumer ELB PIP must already exist)
az network lb frontend-ip update \
    -g "$consumer_rg" \
    --name frontendip1 \
    --lb-name consumer-elb \
    --public-ip-address consumer-elb-pip \
    --gateway-lb "$glbfeid" \
    --output none
```

**Critical constraint:** The consumer ELB public IP (`consumer-elb-pip`) must be named and present before `az network lb create` AND before `az network lb frontend-ip update`. These two operations must reference the same PIP name. This is why the original script failed — `PublicIPconsumer-elb` was referenced in the update but never created.

**Cross-subscription:** Capture `$glbfeid` while provider subscription is active; switch to consumer subscription before the `frontend-ip update`. Inline commented `az account set` lines guide the user.

**Validation:** `az network lb frontend-ip show ... --query gatewayLoadBalancer.id -o tsv` returns the GLB resource ID if chained, empty if not.

#### Bicep Template Facts (for future agents):
- GLB resource name: `provider-nva-glb` (hardcoded in Bicep variable `internalLoadBalanceName`)
- GLB frontend name: `FW` (hardcoded in Bicep variable `internalLoadBalanceFIPConfName`)
- ELB resource name: `provider-nva-elb` (hardcoded in Bicep variable `externalLoadBalanceName`)
- ELB public IP: `provider-nva-elb-pip` (derived from `publicIPAddressName = '${externalLoadBalanceName}-pip'`)
- Bicep expects VNet and subnets to pre-exist (`existingVirtualNetworkName`, `existingUntrustedSubnet`, `existingTrustedSubnet`)
- `TempPassword` is `@secure()` — required by Bicep but OPNsense bootstrap may not retain it post-deploy

#### Open Questions for Future Phases:
- Does `configureopnsense.sh` actually use `TempPassword` or is it discarded after VM provisioning? (Ask Ram)
- `az network lb inbound-nat-rule create` may require `--frontend-ip-name` on newer Azure CLI for Standard SKU — watch for this in Quorra's test run
- Consumer and provider both default to `10.0.0.0/24` — acceptable for separate RGs/subs, but collides if peered

**Status:** Ready for Quorra's live deployment test.

---

### 2026-05-09: Phase 3 — Documentation Consolidation Complete

**Session:** Phase 3 documentation tasks on request from Daniel Mauser  
**Deliverable:** Linux VXLAN tutorial migrated to docs/, README modernized with prerequisites and quick-start

#### Key Learnings:

1. **Tutorial vs. Script Distinction:** Files containing vim interactive commands (`:wq`) are inherently manual tutorials, not deployable scripts. Moving such files to `docs/` clarifies intent and reduces user confusion.

2. **VNI Scope Clarity:** The linux-vxlan tutorial uses VNI 900/901 (independent test setup). This is separate from the main lab's VXLAN tunnel IDs (800/801). Documenting this upfront prevents tunnel misconfiguration when users adapt the tutorial.

3. **Environment Variable Contract Critical:** Users deploying `deploy.azcli` without documentation of required/optional env vars hit friction. Phase 1 established the contract (SSH_PUBLIC_KEY required, LOCATION/RG_*/ADMIN_USERNAME optional with defaults). Exposing this in README prevents misdeployments.

4. **Documentation Links Must Point to GA:** `docs.microsoft.com` URLs often redirect to preview or legacy docs. `learn.microsoft.com` is now the authoritative GA reference for Azure services. Link drift impacts user confidence.

5. **Placeholder Removal Requires Direction:** "Coming soon" sections should be replaced with clear scope statements and links to related docs, not left ambiguous. Users interpret "coming soon" as "will definitely work in future"—a promise we can't keep.

#### Phase 3 Changes:

- **Moved:** `linux-vxlan.azcli` → `docs/linux-vxlan-tutorial.md` (git mv preserves history)
- **Reformatted:** Tutorial now has clear header, numbered steps, code blocks, VNI scope explanation
- **Updated README:**
  - GLB docs link: `docs.microsoft.com` → `learn.microsoft.com`
  - Added Prerequisites section with env var table (8 vars, defaults documented)
  - Added Quick start code snippet
  - Replaced "(coming soon)" on Layer 7/IDS with scope + OPNsense doc links
  - Added archived template note
  - Updated TOC to reference new Prerequisites section

#### Documentation Maintenance Principles (Consolidate):

1. Distinguish between reference materials (docs/) and executable scripts (root + scripts/)
2. Always document env var contracts at deployment entrypoint
3. Replace vague "coming soon" with explicit "out of scope" or "achievable via [reference]"
4. Prefer GA documentation URLs; avoid preview/legacy redirects
5. Interactive tutorials belong in docs/ with explicit "manual walkthrough" headers

**Status:** Phase 3 complete. All three phases (1=unblock, 2=modernize, 3=polish) now concluded. Repository operationally ready for production use by team.

