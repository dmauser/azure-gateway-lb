# Skill: FreeBSD on Azure — Bootstrap Mechanism Decision Tree

**Status:** Authoritative (Round 7 — 2026-05-09)  
**Source:** 7 rounds of live Azure deploy testing; reference repo `dmauser/opnazure`

---

## TL;DR (for AI agents)

Use **`Microsoft.OSTCExtensions.CustomScriptForLinux` v1.5** on image **`thefreebsdfoundation/freebsd-14_1/14_1-release-amd64-gen2-zfs`**. Invoke the shell script via `commandToExecute: 'sh scriptname.sh ...'`. The script must be **POSIX sh compatible** (no `pipefail`, no `ERR` trap). Do NOT use cloud-init, RunCommandLinux, or Azure.Extensions.CustomScript on FreeBSD marketplace images.

---

## Extension Compatibility Matrix

| Mechanism | Image | Result | Notes |
|-----------|-------|--------|-------|
| `CustomScriptForLinux` v1.4.1.0 | freebsd-14_4 | ❌ FAIL | Python 2 `SyntaxError` in handler: `customscript.py:62` octal literal `0700` |
| `CustomScriptForLinux` v1.5 | freebsd-14_1 | ✅ PASS | Python 3 compatible; proven in `dmauser/opnazure` |
| `RunCommandLinux` | freebsd-14_4 | ❌ FAIL | Linux ELF binary — `Exec format error` on FreeBSD |
| `Azure.Extensions.CustomScript` v2.1 | freebsd-14_4 | ❌ FAIL | Linux ELF binary — `Exec format error` on FreeBSD |
| `cloud-init` / `customData` | freebsd-14_4 | ❌ FAIL | cloud-init not installed; customData silently discarded by waagent |
| `cloud-init` / `customData` | freebsd-14_1 | ❌ FAIL | Same — no cloud-init in Azure marketplace FreeBSD images |
| `CustomScriptForLinux` v1.5 | freebsd-14_4 | ⚠️ UNKNOWN | Not tested; avoid (opnazure does not use 14.4) |

**Key rule:** Never assume cloud-init is available on FreeBSD marketplace images. If you see `customData:` in osProfile for a FreeBSD VM, it is silently ignored.

---

## Correct Bootstrap Pattern (CSE v1.5)

### Bicep (inline extension on VM resource)

```bicep
resource vmext 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (!empty(bootstrapUri)) {
  parent: OPNsense
  name: 'CustomScript'
  properties: {
    publisher: 'Microsoft.OSTCExtensions'
    type: 'CustomScriptForLinux'
    typeHandlerVersion: '1.5'
    autoUpgradeMinorVersion: false
    settings: {
      fileUris: ['${bootstrapUri}configureopnsense.sh']
      commandToExecute: 'sh configureopnsense.sh ${bootstrapUri} ${role} ${localIP} ${peerIP}'
    }
  }
}
```

### Image (Bicep)

```bicep
imageReference: {
  publisher: 'thefreebsdfoundation'
  offer: 'freebsd-14_1'
  sku: '14_1-release-amd64-gen2-zfs'
  version: 'latest'
}
plan: {
  publisher: 'thefreebsdfoundation'
  name: '14_1-release-amd64-gen2-zfs'
  product: 'freebsd-14_1'
}
```

### Accept marketplace terms (one-time per subscription)

```bash
az vm image terms accept \
  --publisher thefreebsdfoundation \
  --offer freebsd-14_1 \
  --plan 14_1-release-amd64-gen2-zfs
```

---

## Shell Script Requirements (POSIX sh)

FreeBSD's `/bin/sh` does NOT support bash extensions. When `commandToExecute` uses `sh script.sh`, these are invalid:

```bash
# ❌ INVALID — bash only
set -o pipefail
set -euo pipefail
trap 'echo "Error at line $LINENO"' ERR
```

```sh
# ✅ POSIX sh — valid on FreeBSD /bin/sh
set -eu
```

**Diagnostic tip:** Run `bash -n script.sh` to verify bash syntax, but this does NOT check `pipefail`/ERR compatibility with POSIX sh. Test with `/bin/sh -n` on a FreeBSD host if possible.

---

## VTEP IP Offset Rule (Azure GLB Subnets)

For any Azure GLB-adjacent subnet:

```
Subnet base = X.X.X.Y (first address in CIDR)
Y+0  = network address (Azure reserved)
Y+1  = gateway (Azure reserved)
Y+2  = Azure DNS (Azure reserved)
Y+3  = Azure platform (Azure reserved)
Y+4  = GLB frontend IP (Dynamic allocation — Azure provisions GLB first)
Y+5  = Primary NVA trusted NIC (DHCP)
Y+6  = Secondary NVA trusted NIC (DHCP)
```

**VTEP/VXLAN localIP/peerIP must use offsets +5/+6, not +4/+5.**

This was confirmed empirically via `az network nic show` in round 6 and fixed in round 7. Using +4 causes VTEP to bind to the GLB frontend IP (wrong device).

---

## Full Decision Tree

```
FreeBSD Azure Bootstrap:
├── Need bootstrap after VM provision?
│   ├── YES
│   │   ├── Use custom image (bsdcloudinit pre-installed)?
│   │   │   ├── YES → cloud-init / customData works ✅
│   │   │   └── NO (Azure marketplace FreeBSD image)
│   │   │       ├── Extension choice?
│   │   │       │   ├── CustomScriptForLinux v1.5 + freebsd-14_1 → ✅ USE THIS
│   │   │       │   ├── CustomScriptForLinux v1.4 → ❌ Python 2 SyntaxError
│   │   │       │   ├── RunCommandLinux → ❌ Linux ELF
│   │   │       │   └── Azure.Extensions.CustomScript v2.x → ❌ Linux ELF
│   │   │       └── Script type?
│   │   │           ├── commandToExecute: 'sh script.sh' → POSIX sh required
│   │   │           └── commandToExecute: 'bash script.sh' → only if bash pre-installed
│   └── NO → no extension needed
└── VTEP IP derivation?
    └── GLB subnet +5 = primary, +6 = secondary (NOT +4/+5)
```

---

## Learnings from opnazure (Reference Repo)

Repo: `dmauser/opnazure` — Daniel's proven working OPNsense on Azure deployment.

1. Uses `freebsd-14_1` + `14_1-release-amd64-gen2-zfs` — NOT 14.4
2. Uses `CustomScriptForLinux` v1.5 with `typeHandlerVersion: '1.5'`
3. Script invoked via `sh configureopnsense.sh` (not bash)
4. Script uses `#!/bin/sh` with NO bash-specific syntax
5. Tool usage in script: `fetch` (FreeBSD base tool, like curl) — not wget or curl
6. waagent + WALinuxAgent is installed by the script itself (not pre-installed)
7. OPNsense installed via `opnsense-bootstrap.sh.in -y -r <VERSION>`

---

## References

- Rounds 2–7 in `.squad/agents/quorra/history.md`
- Decision drop: `.squad/decisions/inbox/beck-bootstrap-pivot.md`
- opnazure ref: `dmauser/opnazure` on GitHub
- VTEP empirical data: `.squad/decisions/inbox/quorra-live-deploy-verdict-round6.md` (Finding 5)
