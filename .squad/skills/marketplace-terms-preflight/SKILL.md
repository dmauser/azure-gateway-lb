# SKILL: Marketplace Terms Preflight in deploy.azcli

**Version:** 1.0  
**Author:** Flynn  
**Date:** 2026-05-09  
**Tags:** azure-cli, marketplace, deploy.azcli, preflight, idempotent, freebsd, opnsense

---

## What this skill does

Provides the pattern for accepting Azure Marketplace image terms as an idempotent preflight step in `deploy.azcli`. Without accepted terms, VM deployments fail with `MarketplacePurchaseEligibilityFailed` on first use in a subscription — even if the image is free.

---

## When to use

- Any Azure Marketplace image with a `plan:` block in Bicep (publisher + offer + plan/sku combination)
- First-time deploys to a new subscription
- CI/CD pipelines — service principals may not have pre-accepted terms
- `thefreebsdfoundation/freebsd-14_4` images specifically (OPNsense GLB lab)

---

## The pattern

Place immediately after the `az bicep install` check in the preflight section of `deploy.azcli`:

```bash
# Accept <image name> marketplace terms — idempotent (safe to re-run; returns accepted: true on repeat runs).
# Publisher/offer/plan match the image reference in bicep/modules/VM/<module>.bicep.
# Required once per subscription; without this, VM deployment fails with "MarketplacePurchaseEligibilityFailed".
az vm image terms accept \
    --publisher <publisher> \
    --offer <offer> \
    --plan <sku/plan-name> \
    --output none
```

### For the GLB lab (OPNsense / FreeBSD 14.4)

```bash
az vm image terms accept \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --plan 14_4-release-amd64-gen2-ufs \
    --output none
```

These values come directly from the `plan:` block in `bicep/modules/VM/opnsense-vm-active-active.bicep`:
```bicep
plan: {
  name: '14_4-release-amd64-gen2-ufs'   // → --plan
  product: 'freebsd-14_4'               // → --offer
  publisher: 'thefreebsdfoundation'     // → --publisher
}
```

> **Rule:** Always source `--publisher`, `--offer`, and `--plan` from the Bicep `plan:` block — never hardcode independently. This ensures the deploy script stays in sync with the Bicep module.

---

## Idempotency guarantee

`az vm image terms accept` is idempotent:
- First run on a subscription: accepts terms, returns `"accepted": true`
- Subsequent runs: terms already accepted, returns `"accepted": true`
- No harm from running on every deploy

---

## How to verify current terms status

```bash
az vm image terms show \
    --publisher thefreebsdfoundation \
    --offer freebsd-14_4 \
    --plan 14_4-release-amd64-gen2-ufs \
    --query accepted \
    -o tsv
# true  → terms accepted
# false → not yet accepted (run az vm image terms accept)
```

---

## Why this matters

Quorra's live deploy (2026-05-09, `MSDN_Dmauser / westus3`) required a manual `az vm image terms accept` before the OPNsense deployment could proceed. Without the preflight step, new subscription deployments (including Quorra's CI runs) would silently fail at the VM provisioning stage after all other infrastructure is already created — leaving partial state and requiring manual cleanup before retry.

Adding it to the preflight section means:
1. It runs before any resource creation
2. Failure is caught early with a clear error
3. Re-runs are safe

---

## References

- [az vm image terms accept — Azure CLI reference](https://learn.microsoft.com/cli/azure/vm/image/terms#az-vm-image-terms-accept)
- [Marketplace image plan requirements in Bicep](https://learn.microsoft.com/azure/virtual-machines/marketplace-images#create-a-vm-with-marketplace-image-using-cli)
