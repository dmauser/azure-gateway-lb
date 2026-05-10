# SKILL: CLI Secure Prompt Pattern — env-var-or-prompt with confirmation

**Category:** Shell Scripting / Security  
**Extracted by:** Clu (IaC Engineer)  
**Date:** 2026-05-10T15:57:11-05:00  
**Source context:** `deploy.azcli` — consumer VM password switch (Session 6)

---

## Problem

A deploy script needs a sensitive input (password, token, secret) that:
- Must **not** appear in scripts as a hardcoded value  
- Should support **interactive use** (human prompts) and **non-interactive / CI** (env-var pre-set)  
- Needs **confirmation** for interactive entry to catch typos  
- Must be compatible with `set -euo pipefail`  

---

## Pattern

```bash
# --- Secure input: env-var-or-prompt with confirmation ---
# Works with: set -euo pipefail
# Usage (interactive):     bash deploy.sh          → prompts
# Usage (non-interactive): SECRET='...' bash deploy.sh  → skips prompt

if [[ -z "${SECRET:-}" ]]; then
  while true; do
    read -r -s -p "Enter <description> (complexity requirements): " SECRET
    echo
    read -r -s -p "Confirm <description>: " SECRET_CONFIRM
    echo
    if [[ "$SECRET" == "$SECRET_CONFIRM" ]]; then
      break
    fi
    echo "<Name> don't match. Try again."
  done
  export SECRET
fi

# Optional: client-side minimum length guard (server enforces full complexity)
if [[ "${#SECRET}" -lt 12 ]]; then
  echo "ERROR: <NAME> must be at least 12 characters." >&2
  exit 1
fi
```

---

## Key Design Rules

| Rule | Why |
|------|-----|
| `"${SECRET:-}"` (not `"$SECRET"`) in the `-z` test | Safe under `set -u` — unset var doesn't cause abort |
| `read -r -s` | `-r` prevents backslash interpretation; `-s` hides input (no echo) |
| `echo` after each `read -r -s` | Moves terminal cursor to next line (silent read leaves no newline) |
| `export SECRET` | Makes it available to child processes (`az`, `curl`, etc.) without extra env passing |
| Length check after prompt | Catches the most common user error early, before a slow API call rejects it |
| Keep the env-var path first | CI/scripted callers set the var and bypass the prompt entirely — zero friction |

---

## Bicep Integration (`@secure()`)

When passing the secret to a Bicep deployment:

```bash
az deployment group create \
    --parameters \
        adminPassword="$ADMIN_PASSWORD" \
    ...
```

In Bicep:
```bicep
@secure()
param adminPassword string
```

**Effect:** `@secure()` prevents the value from being stored in ARM deployment history or logged in activity logs. The value is still in the shell environment for the duration of the script — advise users to use a strong, unique secret.

---

## Azure VM Password Complexity (reference)

Azure requires VM `osProfile.adminPassword` to meet:
- **Length:** 12–72 characters  
- **Must include at least 3 of:** uppercase letter, lowercase letter, digit, special character  
- **Must not contain:** username or `123456`, `password`, or other common sequences  

Document these requirements in the `@secure()` param description for discoverability:

```bicep
@sys.description('Admin password for the VM. Azure requires 12-72 chars with uppercase, lowercase, digit, and special character. Passed as @secure() — not stored in deployment history.')
@secure()
param adminPassword string
```

---

## Anti-Patterns to Avoid

| Anti-pattern | Problem |
|---|---|
| `read -p "Password: " SECRET` (no `-s`) | Password echoed to terminal — visible in screen recordings / shoulder surfing |
| Hardcoding fallback: `SECRET="${SECRET:-MyP@ss}"` | Hardcoded default ends up in scripts and version control |
| Requiring the env var (hard exit if unset) | Forces CI friction **and** interactive users to pre-export |
| Single `read` without confirmation | Typos silently create a password the user can't SSH/login with |
| `echo "Secret: $SECRET"` for debug | Leaks secret to terminal history and logs — use `echo "Secret is set (${#SECRET} chars)"` instead |

---

## References

- `deploy.azcli` — Session 6 implementation  
- `.squad/decisions/inbox/clu-password-auth-switch.md` — decision drop with validation evidence  
- Azure VM `osProfile.adminPassword` ARM API docs  
