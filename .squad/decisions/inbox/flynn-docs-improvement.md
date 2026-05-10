# Flynn — Documentation Improvement Decision Drop

**Author:** Flynn (Lead / Azure Architect)  
**Date:** 2026-05-09T19:20:21-05:00  
**Trigger:** Daniel Mauser directive — "improve, and add the missing points on the documentation."
**Scope:** Docs-only pass (no Bicep, no scripts, no deploy.azcli modified)

---

## Files Modified (5 existing + 1 new)

| File | Change type | Summary |
|------|-------------|---------|
| `README.md` | Major update | Added `OPN_BOOTSTRAP_URI` to env table; added "What Gets Deployed" table; added "Validation Walkthrough" with tcpdump proof; added "Known Constraints" section; added "Cleanup" section; updated TOC |
| `docs/troubleshooting.md` | Additive expansion | Added Round 1–6 failure Q+As; expanded VXLAN proof to include tcpdump-level procedure; updated OPNsense bootstrap check from CSE to cloud-init; added "README Validation Discipline" section |
| `docs/architecture/trusted-launch.md` | Status + evidence | Updated status from "Partially Implemented" → "Implemented (consumer-only); FreeBSD opted-out per Azure platform constraint"; added Round 2–5 empirical evidence table; added commit references |
| `docs/architecture/cloud-init-migration.md` | Major update | Updated from "Proposed" → "Implemented"; expanded scope to include OPNsense NVAs; added templating contract (`__URI__`, `__ROLE__`, `__LOCAL_CIDR__`, `__PEER_IP__`); added exit-code-preserving runcmd pattern; added commit references |
| `docs/validation/trusted-launch-cloudinit-checklist.md` | Additive (section 6) | Added Round 6 learnings: corrected 3e (OPNsense securityProfile must be null); added 3h (bootstrap sentinel gate); added mandatory tcpdump proof for VXLAN; added updated gate summary table |
| `docs/troubleshooting-freebsd-on-azure.md` | **NEW FILE** | Single-source FreeBSD-on-Azure constraints guide: No TL, no VM extensions (with full evidence), cloud-init only, `fetch` not `curl`, `python3` not `python`, `/bin/sh` runcmd, marketplace terms, image SKU reference |

---

## What Was Already Accurate

- README diagram description and traffic flow — accurate to current architecture
- README architecture overview (consumer ELB → GLB → VXLAN → OPNsense) — correct
- `docs/troubleshooting.md` VXLAN ports (10800/10801, VNI 800/801) — correct
- `docs/troubleshooting.md` Azure VIP MAC `12:34:56:78:9a:bc` — correct
- `docs/architecture/trusted-launch.md` FreeBSD empirical finding section — accurate
- `docs/validation/trusted-launch-cloudinit-checklist.md` gates 3a–3g — accurate (with corrections in section 6)
- `docs/linux-vxlan-tutorial.md` — accurate; VNI 900/901 scope disclaimer is correct and sufficient

---

## Gaps Closed

1. **`OPN_BOOTSTRAP_URI` was missing from README env var table** — this is the most consequential omission (Round 4 blocker). Now documented with the "must point to pushed code" warning.

2. **Validation walkthrough was absent from README** — the README showed how to deploy but not how to verify. The new "Validation Walkthrough" section has 7 steps mirroring the smoke test gate sequence, with the tcpdump proof procedure as a required final step.

3. **VXLAN proof was insufficiently documented** — tcpdump on `vxlan0`/`vxlan1` is easier to understand but doesn't prove encapsulation. The new procedure shows `tcpdump -nn -i any "udp port 10800 or udp port 10801"` with expected output — this is the level Daniel requires.

4. **OPNsense bootstrap check in troubleshooting.md referenced CSE** — the old doc told users to check `az vm extension show ... --name CustomScript`. CSE was removed in Round 3. Updated to cloud-init sentinel files.

5. **cloud-init-migration.md still said OPNsense uses CSE** — the "OPNsense path — no change" section was the original proposal stance. OPNsense now uses cloud-init too. Updated with the complete templating contract.

6. **Trusted Launch ADR still said "Partially Implemented"** — the status has been fully resolved since Round 1. Updated to reflect final state with commit references.

7. **No single-source FreeBSD-on-Azure constraint reference** — the new `docs/troubleshooting-freebsd-on-azure.md` consolidates all empirical findings from Rounds 1–6.

8. **"What gets deployed" section missing from README** — users had to read deploy.azcli to understand the resource topology. The new table lists both resource groups with all key resources.

9. **Cleanup section missing from README** — the `az group delete` commands were not in the README. Added with wait commands.

10. **Known constraints section missing** — FreeBSD limitations were scattered across ADRs. Consolidated into a single table in README.

---

## Validation Summary

- ✅ All linked files exist (no broken local links introduced)
- ✅ Every env var in README table verified against `deploy.azcli` grep output: `SSH_PUBLIC_KEY`, `SUBSCRIPTION_ID`, `LOCATION`, `RG_CONSUMER`, `RG_PROVIDER`, `ADMIN_USERNAME`, `BASTION_DEPLOY`, `OPN_BOOTSTRAP_URI` — all confirmed present in script
- ✅ Resource names in README (consumer-elb-pip, consumer-elb, provider-nva-glb, provider-nva-elb-pip) verified against Bicep and deploy.azcli
- ✅ TOC updated with new sections
- ✅ Quorra's files untouched (checklist extended in section 6 only — additive)

---

## Principle Established

**README must mirror deploy.azcli env contract.** Every environment variable that `deploy.azcli`
reads (with default, required-vs-optional, and behavior) must appear in the README prerequisites
table. Discrepancies between README and script are a documentation bug, not just a style issue —
they cause deploy failures (as Round 4's `OPN_BOOTSTRAP_URI` omission demonstrated).
