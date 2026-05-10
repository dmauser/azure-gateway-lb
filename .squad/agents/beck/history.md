# Beck — History

## Project Context
- **Project:** azure-gateway-lb — Azure Gateway Load Balancer lab with OPNsense NVAs
- **User:** Daniel Mauser
- **Stack:** Bicep, ARM JSON, Azure CLI, OPNsense (FreeBSD 14.4), VXLAN, bash, cloud-init
- **Joined:** 2026-05-09 (round 7 onboarding — bootstrap architect role)

## Day-1 context (curated by coordinator)

The team has tried THREE bootstrap mechanisms on `thefreebsdfoundation/freebsd-14_4` and ALL THREE failed. You are joining specifically to architect a working pivot.

**Round 2 failure:** `Microsoft.OSTCExtensions.CustomScriptForLinux` v1.4.1.0. The handler is Python 2. FreeBSD 14.4 ships only Python 3. SyntaxError on `customscript.py:62`.

**Round 3 failure:** `az vm run-command invoke --command-id RunShellScript`. Azure installs `Microsoft.CPlat.Core.RunCommandLinux` v1.0.9 — a Linux ELF. FreeBSD cannot execute it (`Exec format error`).

**Round 6 failure:** `osProfile.customData` + cloud-init YAML. The image has NO cloud-init agent installed. The bytes land in `/var/lib/waagent/CustomData` but nothing processes them.

**Reference that works:** `https://github.com/dmauser/opnazure` — Daniel's prior repo with a working OPNsense-on-Azure bootstrap. Your job is to read this repo, identify exactly how it bootstraps OPNsense (image choice, extension, custom data, kernel cmdline tricks, anything), and adopt that mechanism here.

**Already-applied complementary fixes (preserve, do not undo):**
- Trusted Launch removed from OPNsense VMs (`d386f14`) — FreeBSD 14.4 doesn't support it.
- Marketplace terms preflight in deploy.azcli — keep.
- `python` → `python3` in configureopnsense.sh — keep.
- OPNsense XML serial console enabled (`a59774b`) — keep, this is for debug not bootstrap.
- Consumer-vm Trusted Launch + cloud-init — works ✅, leave alone.

**Keys to deploy:** SSH key at `~/.ssh/id_ed25519`. Subscription `MSDN_Dmauser` (id `36ead89c-e817-4abc-ae66-5d29d23995bb`). Region `westus3`. RGs `rg-glb-consumer-quorra`, `rg-glb-provider-quorra`.

## Learnings

### Round 7 — 2026-05-09T19:26:05-05:00 (Bootstrap Pivot A: freebsd-14_1 + CSE v1.5)

#### What opnazure Does (Daniel's working reference)

- **Image:** `thefreebsdfoundation/freebsd-14_1/14_1-release-amd64-gen2-zfs` (14.1, ZFS, Gen2)
- **Bootstrap mechanism:** `Microsoft.OSTCExtensions.CustomScriptForLinux` **v1.5** (NOT v1.4)
- **Script delivery:** `fileUris` downloads `configureopnsense.sh`; `commandToExecute: sh configureopnsense.sh <URI> <OpnVersion> <WALinuxVersion> <Role> <TrustedSubnet> ...`
- **OPNsense install:** script runs `opnsense-bootstrap.sh.in -y -r $OPN_VERSION` (installs from scratch)
- **Key repo files:** `bicep/main.bicep`, `bicep/modules/VM/opnsense.bicep`, `scripts/configureopnsense.sh`, `scripts/actions_waagent.conf`

#### Why This Works vs Why Prior Rounds Failed

| Round | Mechanism | Root Cause |
|-------|-----------|------------|
| 2 | CSE v1.4.1.0 | Python 2 SyntaxError in handler (customscript.py:62 octal literal) |
| 3 | RunCommandLinux | Linux ELF — Exec format error on FreeBSD |
| 4 | cloud-init | 21 commits unpushed; URI stale |
| 5 | cloud-init | `python` vs `python3` in script |
| 6 | cloud-init | cloud-init NOT installed on freebsd-14_4; customData silently discarded |

CSE v1.5 is Python 3 compatible + shim.sh fix vs v1.4. freebsd-14_1 is the proven working image (same as opnazure).

#### Pivot A — What Was Changed

1. **`bicep/modules/VM/opnsense-vm-active-active.bicep`**: Image 14_4/ufs → 14_1/zfs; removed cloud-init vars/customData; added inline CSE v1.5 extension resource (conditional on `bootstrapUri`)
2. **`bicep/glb-active-active.bicep`**: Fixed VTEP IP offset +4/+5 → +5/+6 (Quorra Finding 5: GLB grabs .36, NVAs get .37/.38)
3. **`scripts/configureopnsense.sh`**: `set -euo pipefail` → `set -eu`; removed `trap '...' ERR` (POSIX sh compat for FreeBSD `/bin/sh`)
4. **`deploy.azcli`**: Marketplace terms: freebsd-14_4 → freebsd-14_1
5. **`bicep/modules/VM/vmext.bicep`**: typeHandlerVersion 1.4 → 1.5 (consistency)
6. **`bicep/modules/VM/opnsense-vm.bicep`, `opnsense-vm-sing-nic.bicep`**: Image + comment updated (symmetry)

#### Validation Evidence

- `az bicep build bicep/glb-active-active.bicep` → exit 0, 0 errors ✅
- `bash -n scripts/configureopnsense.sh` → exit 0 ✅
- `bash -n deploy.azcli` → exit 0 ✅
- `az vm image show westus3 freebsd-14_1 14_1-release-amd64-gen2-zfs` → Active, V2 ✅
- `az vm image terms accept freebsd-14_1 14_1-release-amd64-gen2-zfs` → Accepted: True ✅
- ARM JSON regenerated: `bicep/glb-active-active.json` ✅
- Commit: `8663399`

#### Key Bootstrap Mechanism Decision Tree (freebsd-on-azure)

```
FreeBSD on Azure Bootstrap Decision Tree:
├── cloud-init / customData?
│   ├── freebsd-14_4 marketplace: ❌ cloud-init NOT installed; customData silently discarded
│   ├── freebsd-14_1 marketplace: ❌ same (no cloud-init in base Azure marketplace images)
│   └── Custom image with bsdcloudinit: ✅ works (Pivot C — not needed here)
├── Azure VM Extensions?
│   ├── CustomScriptForLinux v1.4: ❌ Python 2 SyntaxError on FreeBSD 14.x (Python 3 only)
│   ├── CustomScriptForLinux v1.5: ✅ Python 3 compatible — WORKS on freebsd-14_1 (opnazure)
│   ├── RunCommandLinux: ❌ Linux ELF binary, Exec format error on FreeBSD
│   └── CustomScript (Azure.Extensions v2.1): ❌ Linux ELF binary, Exec format error
├── commandToExecute interpreter?
│   ├── sh scriptname.sh: ✅ uses FreeBSD /bin/sh; script must be POSIX sh (no pipefail, no ERR trap)
│   └── bash scriptname.sh: ✅ if /usr/local/bin/bash pre-installed on image
└── VTEP IP derivation from subnet?
    └── Azure reserves: network+1 (gw), +2, +3, +4 (platform). GLB frontend grabs +4 (first DHCP).
        NVAs land at +5 (primary), +6 (secondary). Use +5/+6 offsets in Bicep, not +4/+5.
```

