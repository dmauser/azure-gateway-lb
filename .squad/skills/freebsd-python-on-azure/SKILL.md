# SKILL: FreeBSD Python on Azure — Always Use python3

**Category:** Azure / FreeBSD / Shell Scripts  
**Discovered:** 2026-05-09T13:42:28-05:00  
**Author:** Flynn (Lead / Azure Architect)  
**Validated by:** Quorra (Round 5 live deploy — confirmed blocker; Round 6 fix pending)

---

## Problem Class

A shell script targeting FreeBSD 14.4 on Azure calls `python` (not `python3`). The script fails
silently (or loudly, if `set -e` is active) because no `python` symlink exists on first boot.

---

## Root Cause

`thefreebsdfoundation/freebsd-14_4` ships:
- `python3.11` at `/usr/local/bin/python3.11`
- `python3` at `/usr/local/bin/python3` (symlink to 3.11)
- **No** `/usr/local/bin/python` symlink at first boot

Scripts that rely on `python` must either:
1. Call `python3` directly, OR
2. Create the symlink (`ln -s python3.11 python`) BEFORE the first `python` invocation

Option 1 is always preferred. Option 2 is fragile — if the symlink line is placed even one line
after the first `python` call, the script fails.

---

## The Rule

**Always use `python3` in shell scripts targeting FreeBSD 14.4 on Azure. Never use `python`.**

```sh
# ❌ Wrong — fails on FreeBSD 14.4 first boot
gwip=$(python get_nic_gw.py "$3")

# ✅ Correct
gwip=$(python3 get_nic_gw.py "$3")
```

**Corollary:** If you create a `python` symlink anywhere in the script, check whether it is still
needed after all `python` invocations are replaced with `python3`. If not, delete it — dead
symlink creation is a sign that the underlying bug wasn't fully fixed.

---

## Python Script Compatibility Audit

When a `.py` script is called from a FreeBSD bootstrap, also audit the script itself:

| Syntax | Python 2 | Python 3 | Action |
|--------|----------|----------|--------|
| `print "x"` | ✅ | ❌ | → `print("x")` |
| `print(x)` | ✅ (2.6+) | ✅ | no change |
| `5 / 2 == 2` | ✅ (integer div) | ❌ (= 2.5) | → `5 // 2` if integer expected |
| `f"..."` f-string | ❌ | ✅ | fine for python3-only |
| `#!/usr/bin/env python3` shebang | — | ✅ | add if missing |

---

## Applied In

- `scripts/configureopnsense.sh` — Round 6 fix (commit `519bf26`):
  - `python get_nic_gw.py $3` → `python3 get_nic_gw.py $3` (×2, Primary and Secondary branches)
  - Removed dead `ln -s python3.11 python` symlink line
- `scripts/get_nic_gw.py` — Already Python 3 compatible; no changes needed

---

## Related Skills

- `.squad/skills/freebsd-on-azure-bootstrap/SKILL.md` — no VM extensions on FreeBSD; use WAAgent
  run-command or bsdcloudinit
- `.squad/skills/cloud-init-runcmd-exit-discipline/SKILL.md` — don't lose exit codes in runcmd
