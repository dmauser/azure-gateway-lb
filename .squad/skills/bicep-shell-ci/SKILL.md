# SKILL: Bicep + Shell CI Scaffolding

**Version:** 1.0  
**Author:** Flynn  
**Date:** 2026-05-09  
**Tags:** bicep, shellcheck, ci, github-actions, azure

---

## What this skill does

Provides a reusable GitHub Actions CI workflow pattern for Azure Bicep + shell-script repositories. Three jobs: Bicep build, Bicep lint, ShellCheck — all without requiring Azure credentials.

---

## When to use

Use this skill when a repository contains:
- One or more `.bicep` files (entrypoint templates, not just modules)
- Shell scripts (`.sh`) or Azure CLI scripts (`.azcli`)
- A need for PR reviewer gate validation that doesn't require live Azure resources

---

## Pattern

### Workflow skeleton

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  bicep-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
      - run: az bicep install
      - run: |
          find <bicep-dir> -maxdepth 1 -name '*.bicep' | while read -r f; do
            az bicep build --file "$f" --outfile /dev/null
          done

  bicep-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
      - run: az bicep install
      - run: |
          find <bicep-dir> -maxdepth 1 -name '*.bicep' | while read -r f; do
            az bicep lint --file "$f"
          done

  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y shellcheck
      - run: |
          find scripts -name '*.sh' | while read -r f; do
            shellcheck --shell=bash --severity=warning "$f"
          done
      - run: shellcheck --shell=bash --severity=warning deploy.azcli
```

### Key decisions

| Decision | Rationale |
|----------|-----------|
| `az bicep install` via AZ CLI | No separate action needed; AZ CLI is pre-installed on ubuntu-latest |
| `find -maxdepth 1` for Bicep | Only compile entrypoint templates, not individual modules (modules have unresolved references) |
| `--outfile /dev/null` | Discards compiled ARM JSON; we only want compilation errors |
| `--shell=bash` on ShellCheck | `.azcli` files not recognized by extension; explicit flag required |
| `--severity=warning` | Suppresses `info`-level style notices; keeps CI gate signal-to-noise high |
| Actions pinned to `@v4` | Avoids floating `@main` security risk |

### Adapting for other projects

- Change `<bicep-dir>` to your top-level Bicep directory
- Add `--exclude <path>` to the `find` command to skip archived/legacy templates
- Adjust `--severity` to `error` for a more lenient gate or `style` for maximum strictness
- To add ARM JSON validation, install `arm-ttk` or use the `azure/arm-ttk-action` action

---

## Validation

Test YAML syntax locally before committing:
```bash
python -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('valid')"
```

---

## References

- [az bicep CLI reference](https://learn.microsoft.com/cli/azure/bicep)
- [ShellCheck](https://www.shellcheck.net/)
- [GitHub Actions: ubuntu-latest pre-installed software](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2204-Readme.md)
