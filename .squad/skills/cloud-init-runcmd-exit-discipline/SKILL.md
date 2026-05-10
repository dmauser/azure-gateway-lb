# SKILL: cloud-init runcmd Exit-Code Discipline

**Category:** Cloud-Init / FreeBSD / Sentinel Patterns  
**Discovered:** 2026-05-09T13:42:28-05:00  
**Author:** Flynn (Lead / Azure Architect)  
**Validated by:** Quorra (Round 5 finding — tee masks exit; Round 6 fix pending)

---

## Problem Class

A `runcmd` step in a cloud-config YAML pipes a bootstrap script through `tee` for logging:

```yaml
runcmd:
  - "my-script.sh args 2>&1 | tee /var/log/my-script.log"
  - "echo 'done' > /var/run/my-script-done"
```

The sentinel (`/var/run/my-script-done`) is written **even when the script fails**, because
`tee` always exits 0. Smoke tests that poll the sentinel file get a false positive.

---

## Root Cause

In a shell pipeline `A | B`, the exit code of the pipeline is the exit code of the rightmost
command (`B` = `tee`). `tee` exits 0 unless it cannot write its output file. Therefore:

```sh
false | tee /dev/null  # exits 0 — the 'false' failure is lost
```

`set -o pipefail` would preserve `false`'s exit code, but:
1. cloud-init's `runcmd` executes each item as `/bin/sh -c 'item'`
2. The `-o pipefail` option must be set within that single invocation
3. On some shells/versions this works; on others (especially embedded/older sh), it doesn't
4. The safest approach avoids the pipe entirely

---

## The Rule

**Never pipe through `tee` in a runcmd step if the script's exit code matters.**

Instead, redirect to file, capture `$?`, re-emit the log via `cat`, and write dual sentinels:

```yaml
runcmd:
  # Capture exit code; write sentinel only on success; write failure sentinel on non-zero.
  # 'cat' of the log echoes full output to cloud-init's own log for debuggability.
  - "my-script.sh args > /var/log/my-script.log 2>&1; rc=$?; cat /var/log/my-script.log; [ $rc -eq 0 ] && echo \"done-$(date -u +%Y%m%dT%H%M%SZ)\" > /var/run/my-script-done || echo \"failed-rc=$rc-$(date -u +%Y%m%dT%H%M%SZ)\" > /var/run/my-script-failed; exit $rc"
```

**Key elements:**

| Element | Purpose |
|---------|---------|
| `> /var/log/my-script.log 2>&1` | Capture all output to persistent log |
| `rc=$?` | Capture exit code before any other command can overwrite it |
| `cat /var/log/my-script.log` | Echo log into cloud-init's own output log (`/var/log/cloud-init-output.log`) |
| `[ $rc -eq 0 ] && echo ... > /var/run/my-script-done` | Sentinel only on true success |
| `echo "failed-rc=$rc-..." > /var/run/my-script-failed` | Fast signal for smoke tests on failure |
| `exit $rc` | Propagate failure to cloud-init — instance is marked `error`, not `done` |

---

## Dual Sentinel Pattern

| File | Written when | Content |
|------|-------------|---------|
| `/var/run/my-script-done` | rc = 0 | `done-20260509T184200Z` (ISO timestamp) |
| `/var/run/my-script-failed` | rc ≠ 0 | `failed-rc=1-20260509T184200Z` |

Smoke test can check:
```bash
# From orchestration script (az vm run-command invoke):
test -f /var/run/my-script-done && echo "SUCCESS" || (cat /var/run/my-script-failed && exit 1)
```

---

## Alternative: pipefail in runcmd

If you must keep the `tee` for real-time log streaming AND your target shell supports it:

```yaml
runcmd:
  - "set -o pipefail; my-script.sh args 2>&1 | tee /var/log/my-script.log; rc=$?; [ $rc -eq 0 ] && echo ok > /var/run/done || echo fail-$rc > /var/run/failed; exit $rc"
```

**Warning:** `set -o pipefail` is a shell feature — verify it works on your target OS's `/bin/sh`
before depending on it. FreeBSD 14.4's `/bin/sh` supports it (POSIX 2024), but older images may
not. The redirect-and-capture approach above is always safe.

---

## Applied In

- `bicep/cloud-init/opnsense-bootstrap.yaml` — Round 6 fix (commit `519bf26`):
  - Old: Steps 2 (tee pipe) + 3 (unconditional sentinel)
  - New: Single merged step with redirect + rc capture + dual sentinels + `exit $rc`

---

## Related Skills

- `.squad/skills/freebsd-python-on-azure/SKILL.md` — FreeBSD 14.4 python3 invocation rule
- `.squad/skills/freebsd-on-azure-bootstrap/SKILL.md` — no VM extensions on FreeBSD; use WAAgent
