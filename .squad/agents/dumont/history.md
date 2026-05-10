## Round 7 Deployment Close-out
- **Date:** 2026-05-09
- **Status:** ✅ ALL GATES GREEN
- **Session:** End-to-end deployment validated; VXLAN tcpdump confirmed bidirectional; all RGs cleaned; CI workflow staged
- **Key Outcome:** Full session arc logged, decisions merged, team expanded to 8 members
- **Next:** Deployment proof via bash deploy.azcli with SSH_PUBLIC_KEY set
# Dumont — History

## Project Context
- **Project:** azure-gateway-lb — Azure Gateway Load Balancer lab with OPNsense NVAs
- **User:** Daniel Mauser
- **Stack:** Bicep, ARM JSON, Azure CLI, OPNsense (FreeBSD 14.4), VXLAN, bash, cloud-init
- **Joined:** 2026-05-09
- **Role:** Operations / Debug Specialist — in-VM diagnostics and out-of-band access

## Day-1 context (curated by coordinator)
- The team has been through 6 deploy iterations. See `.squad/decisions.md` for the complete arc.
- Critical FreeBSD-on-Azure constraints: NO Trusted Launch, NO VM extensions, cloud-init is the only first-boot mechanism.
- OPNsense bootstrap ships via `osProfile.customData` (cloud-init). Sentinel files: `/var/run/opnsense-bootstrap-done` (success) and `/var/run/opnsense-bootstrap-failed` (failure with exit code).
- **Daniel-supplied operational knowledge:** OPNsense VMs are reachable via Azure serial console (`az serial-console connect`) and boot diagnostics (`az vm boot-diagnostics get-boot-log`). This is the canonical out-of-band path when SSH is unreachable.
- VXLAN ports: UDP 10800 (local) / 10801 (remote). VNI 800/801. Hardcoded peer MAC `12:34:56:78:9a:bc` for Azure VIP 168.63.129.16.
- Current branch: `main`. Latest commit at start of Dumont's tenure: `519bf26` (Flynn round-6 fixes — python3, exit-code-preserving runcmd, GLB chain poll).

## Learnings

### Day-1 Runbooks — 2026-05-09T19:20:21-05:00

**What shipped:**
- `docs/debug/serial-console.md` — interactive OPNsense console runbook (attach, menu nav, 5 canonical diagnostics, troubleshooting, detach)
- `docs/debug/boot-diagnostics.md` — non-interactive log retrieval (enable, get-boot-log, PowerShell grep recipe, screenshot blob, empty-log troubleshooting)
- `docs/debug/vxlan-proof.md` — packet-level VXLAN proof (two-terminal procedure, tcpdump interpretation, smoke test bundle PowerShell, VXLAN failure troubleshooting)
- `.squad/skills/azure-serial-console-ops/SKILL.md` — operational serial console skill (distinct from existing opnsense-azure-serial-console which covers XML config)
- `.squad/skills/vxlan-tcpdump-proof/SKILL.md` — tcpdump discipline for tunneled traffic

**FreeBSD console quirks learned:**
- OPNsense console serial output requires `<secondaryconsole>serial</secondaryconsole>` in config.xml + 115200 baud (covered in existing `opnsense-azure-serial-console` skill)
- At the OPNsense menu, shell access is option 8. Raw FreeBSD login (`login:`) = bootstrap not completed
- Ctrl+] is the clean detach sequence; closing the terminal can lock the serial port for 30–60s
- Boot loader interrupt window is ~3 seconds — attach console BEFORE issuing `az vm restart`
- IME (Input Method Editor) on Windows can interfere with serial console input — disable or use Portal browser console

**az command surfaces relevant to operators:**
- `az serial-console connect -g $RG -n $VM` — interactive serial session (requires `serial-console` extension)
- `az vm boot-diagnostics enable -g $RG -n $VM` — idempotent, no reboot required
- `az vm boot-diagnostics get-boot-log -g $RG -n $VM` — full serial log to stdout (pipe to Select-String for grep)
- `az vm boot-diagnostics get-boot-log-uris -g $RG -n $VM` — SAS URIs for screenshot + serial log blobs
- `az network lb frontend-ip show --query gatewayLoadBalancer.id` — verify GLB chain is active (null = not chained)

**Sentinel reliability note (critical):**
- Round 5 bug: `tee` pipeline masked `configureopnsense.sh` exit code → `bootstrap-done` sentinel written even on failure
- Current YAML (Round 6+): explicit `[ $rc -eq 0 ]` check → sentinel IS reliable evidence of success
- Always cross-check sentinel with `cloud-init status --long` and OPNsense GUI responsiveness

**VXLAN proof discipline:**
- HTTP 200 alone cannot prove the NVA is in the traffic path (GLB chain might be inactive)
- Must capture on both `hn0` (physical NIC — proves VXLAN encapsulation) AND `vxlan0`/`vxlan1` (proves decapsulation)
- GLB sends health probes from `168.63.129.16` constantly — filter with `and greater 100` to isolate real traffic
- `sockstat -l -P udp | grep -E '10800|10801'` confirms OPNsense is listening on VXLAN ports

**Coordination outcomes:**
- No conflict with Flynn (docs/architecture/*) — docs/debug/* is a new folder
- Cross-links added: runbooks link to each other and to ../troubleshooting.md + ../troubleshooting-freebsd-on-azure.md
- Decision drop filed: `.squad/decisions/inbox/dumont-debug-runbooks.md`

