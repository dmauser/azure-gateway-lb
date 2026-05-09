# SKILL: Shell Script Parameter Contract Header

**Category:** Shell Scripting / Documentation  
**Applies to:** Any `sh`/`bash` script with a fixed positional-argument contract

---

## Problem

Scripts that accept multiple positional arguments (`$1`, `$2`, …) are opaque to callers unless the contract is explicitly documented. In Azure Custom Script Extension deployments, callers (Bicep/ARM templates) assemble the argument string from separate parameters; any mismatch silently produces broken sed substitutions or wrong runtime behaviour.

---

## Pattern

Write a structured comment block at the top of the script (after the shebang) that documents:

1. **Script purpose** — one sentence
2. **Usage line** — canonical invocation signature
3. **Each parameter** — positional index, human name, type, example value, and where in the script it is used
4. **Derived values** — anything computed from a parameter (e.g., IP stripped of CIDR)
5. **Placeholder mapping** — for template files, map placeholders → computed values
6. **Example invocations** — at least one per distinct mode/role
7. **Invocation context** — who calls this script and how (e.g., Azure CSE, CI pipeline)

---

## Template

```sh
#!/bin/sh

# <One-line description of what this script does>
#
# Usage:
#   <script_name>.sh <param1> <param2> <param3> <param4>
#
# Parameters:
#   $1  <Name>     Type: <type description>
#                  Example: <example value>
#                  Used: <where/how in the script>
#
#   $2  <Name>     Type: <type description>
#                  Example: <example value>
#                  Used: <where/how in the script>
#
#   $3  <Name>     Type: <type description>
#                  Example: <example value>
#                  Used: <where/how in the script>
#
#   $4  <Name>     Type: <type description>
#                  Example: <example value>
#                  Used: <where/how in the script>
#
# Derived values:
#   <varname>  = <derivation expression> (e.g., IP portion of $3 with CIDR stripped)
#
# Template placeholder mapping (if applicable):
#   PLACEHOLDER  -> <value and source>
#
# Example invocations:
#   Mode A:
#     sh <script>.sh <arg1> ModeA <arg3> <arg4>
#
#   Mode B:
#     sh <script>.sh <arg1> ModeB <arg3> <arg4>
#
# Invocation context:
#   Called by <caller> via <mechanism>. Caller maps parameters as:
#     <CallerParam> -> $N

set -euo pipefail
trap 'echo "[ERR] line $LINENO (exit $?)" >&2' ERR
```

---

## Real example: `configureopnsense.sh`

```sh
#!/bin/sh

# Configure OPNsense for Azure Gateway Load Balancer (active-active NVA pair).
#
# Usage:
#   configureopnsense.sh <uri_prefix> <role> <local_ip_cidr> <peer_ip>
#
# Parameters:
#   $1  URI prefix    Type: URL string (trailing slash required)
#                     Example: https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/
#                     Used: base URL for fetch of XML templates and helper scripts
#
#   $2  Role          Type: string — "Primary" or "Secondary"
#                     Example: Primary
#                     Used: selects XML template; controls HA-sync substitution
#
#   $3  Local CIDR    Type: IPv4/prefix (CIDR notation)
#                     Example: 10.0.1.5/24
#                     Used: passed to get_nic_gw.py → yyy placeholder; IP portion → lll placeholder
#
#   $4  Peer IP       Type: IPv4 address (no prefix)
#                     Example: 10.0.1.6
#                     Used: rrr placeholder (both roles); xxx placeholder (Primary HA-sync only)
#
# XML placeholder mapping:
#   yyy.yyy.yyy.yyy  -> LAN gateway (derived from $3 via get_nic_gw.py)
#   xxx.xxx.xxx.xxx  -> peer NVA IP / HA-sync target ($4, Primary only)
#   lll.lll.lll.lll  -> local NVA IP (IP portion of $3, CIDR stripped)
#   rrr.rrr.rrr.rrr  -> peer NVA IP ($4)
```

---

## Key rules

- **Always document at the top** — before any executable code, after the shebang.
- **Match actual usage** — verify each documented placeholder/parameter against `sed`, `awk`, or variable assignments in the body. Drift between doc and code is worse than no doc.
- **Include CIDR vs bare-IP distinction** — if a parameter must include or exclude the prefix, say so explicitly and give an example that matches.
- **Name the caller** — scripts invoked by infrastructure tools (Bicep CSE, Terraform remote-exec) must document where each `$N` originates so IaC authors know what to pass.

---

## References

- `scripts/configureopnsense.sh` — canonical example of this pattern in this repo
- Phase 2 decision drop: `.squad/decisions/inbox/ram-phase2-scripts.md`
