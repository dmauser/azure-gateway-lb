# Orchestration Log Entry

### 2026-05-09T04:56Z — Clu Image Investigation

| Field | Value |
|-------|-------|
| **Agent routed** | Clu (IaC Engineer) |
| **Why chosen** | Deep-dive on OPNsense FreeBSD image availability after audit flagged EOL concern |
| **Mode** | background |
| **Why this mode** | Investigation is independent; produces decision input for Phase 1 planning |
| **Files authorized to read** | Azure Marketplace image lists (CLI queries), OPNsense vendor docs |
| **File(s) agent must produce** | `.squad/decisions/inbox/clu-image-investigation.md` |
| **Outcome** | Completed — confirmed FreeBSD 12.0 EOL; recommended migration to thefreebsdfoundation FreeBSD 14.4 (pending OPNsense compatibility validation) |

---

## Summary

Clu investigated OPNsense image availability:
- **Finding:** FreeBSD 12.0 (MicrosoftOSTC) is EOL; no available versions in Marketplace
- **Alternative 1:** FreeBSD 11.3 (MicrosoftOSTC) — older, not recommended
- **Alternative 2:** thefreebsdfoundation FreeBSD 14.4 — modern, Gen2 support (recommended)
- **Risk:** OPNsense compatibility with FreeBSD 14.4 unknown; requires vendor verification

Recommended immediate action: Verify OPNsense compatibility with FreeBSD 14.4; proceed with Option C migration if compatible.
