# Archived Files

Files in this folder are preserved for reference but are **no longer maintained**.

## main-two-nics (deprecated 2026-05-08)

`main-two-nics.bicep`, `main-two-nics.json`, and `main-two-nics.parameters.json` represent an
alternative single-NVA, two-NIC deployment pattern. This was deprecated in favour of the
active-active design (`glb-active-active.bicep`) for the following reasons:

- `main-two-nics.bicep` had a BCP037 compilation error (module parameters incorrectly passed).
- The active-active pattern is the canonical production deployment.

> **Security note:** `main-two-nics.parameters.json` previously contained a plaintext password.
> The value has been replaced with `REDACTED-SEE-GIT-HISTORY-FOR-WHY-THIS-WAS-REMOVED`.
> The original value is visible in git history — treat that history as compromised and rotate
> any credentials that matched that password.

These files are kept solely in case Daniel Mauser wants to revive the two-NIC pattern.
They should **not** be used as-is; a fresh Bicep compilation and parameter file would be required.
