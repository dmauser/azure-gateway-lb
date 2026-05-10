# Troubleshooting Guide — Azure Gateway Load Balancer Lab

**In this article**

- [deploy.azcli Failure Modes](#deployazcli-failure-modes)
- [OPNsense Bootstrap Failures (Rounds 1–6)](#opnsense-bootstrap-failures-rounds-16)
- [VXLAN Tunnel Debugging and Proof](#vxlan-tunnel-debugging-and-proof)
- [Standard LB Inbound NAT Rule Pitfall](#standard-lb-inbound-nat-rule-pitfall)
- [Cross-Subscription Deploy Gotchas](#cross-subscription-deploy-gotchas)
- [OPNsense Access](#opnsense-access)
- [Verifying GLB Chaining](#verifying-glb-chaining)
- [README Validation Discipline](#readme-validation-discipline)

---

## deploy.azcli Failure Modes

### Password too short or missing

**Symptom:** Script exits with:
```
ERROR: ADMIN_PASSWORD must be at least 12 characters.
```

**Fix:** Use a strong password that meets Azure complexity requirements (12-72 chars, uppercase, lowercase, digit, special character). Either set it as an env var before running or let the interactive prompt guide you:

```bash
# Interactive (default — script prompts if ADMIN_PASSWORD is not set):
bash deploy.azcli

# Non-interactive / CI:
ADMIN_PASSWORD='MyP@ssw0rd!' bash deploy.azcli
```

> **Note:** The password is passed to Bicep as `@secure()` — it is **not** stored in the ARM deployment history. However, it is present in your shell environment for the duration of the deployment. Use a strong unique password and avoid reusing personal credentials.

> **Debug SSH access:** To SSH into the consumer VM after deployment, you can use `ssh-copy-id` or `az vm user update` to inject a public key post-deploy. Set `SSH_PUBLIC_KEY` if you want to document the key for reference, but it is not consumed by `deploy.azcli`.

---

### How do I avoid the password prompt for CI?

Set `ADMIN_PASSWORD` in the environment before running `deploy.azcli`:

```bash
export ADMIN_PASSWORD='MyP@ssw0rd!'
bash deploy.azcli
```

Or inline:

```bash
ADMIN_PASSWORD='MyP@ssw0rd!' bash deploy.azcli
```

The script skips the interactive prompt when `ADMIN_PASSWORD` is already set.

---

### Wrong or missing subscription

**Symptom:** Resources deploy to the wrong subscription, or `az account show` returns the wrong tenant.

**Fix:** Set `SUBSCRIPTION_ID` before running:
```bash
export SUBSCRIPTION_ID="<your-subscription-id>"
bash deploy.azcli
```

Verify the active subscription:
```bash
az account list --query "[?isDefault==\`true\`].{Name:name, Id:id}" -o table
```

---

### Pre-existing resource group conflicts

**Symptom:** `az group create` succeeds (idempotent), but a resource inside the RG already exists with conflicting settings — typically the VNet or LB. Error looks like:
```
Another resource with the same name ... already exists
```

**Fix (clean slate):** Delete the existing RGs and re-run:
```bash
az group delete -n glb-consumer-rg --yes --no-wait
az group delete -n glb-provider-rg --yes --no-wait
# Wait for deletion to complete before re-running deploy.azcli
az group wait --deleted -n glb-consumer-rg
az group wait --deleted -n glb-provider-rg
```

**Fix (partial re-run):** Identify and delete only the conflicting resource, then re-run the relevant section.

---

### GLB chaining race condition

**Symptom:** The `az network lb frontend-ip update --gateway-lb` call fails with a resource-not-found or validation error even though the Bicep deployment "completed".

**Root cause:** The Bicep deployment returns success when the ARM deployment is accepted, but the GLB frontend IP resource may still be provisioning. If the script somehow ran without `--no-wait` removed (older versions), the chaining step can race ahead.

**Fix:** Verify the GLB frontend is fully provisioned before chaining:
```bash
az network lb frontend-ip show \
    -g glb-provider-rg \
    --lb-name provider-nva-glb \
    --name FW \
    --query provisioningState \
    -o tsv
# Expected: Succeeded
```

If it shows `Updating` or `Deleting`, wait and retry. The current `deploy.azcli` removes `--no-wait` from the Bicep deployment step to prevent this race.

---

## OPNsense Bootstrap Failures (Rounds 1–6)

These are platform-level blockers encountered and resolved during live deploy rounds on
`thefreebsdfoundation/freebsd-14_4` in Azure westus3. All are empirically confirmed.

### "Use of TrustedLaunch setting is not supported for the provided image" (Round 1)

**Full error:**
```
BadRequest: Use of TrustedLaunch setting is not supported for the provided image.
Please select Trusted Launch Supported Gen2 OS Image.
```

**Cause:** The Bicep template had `securityProfile.securityType: 'TrustedLaunch'` on the OPNsense
VM resource. FreeBSD 14.4 (`thefreebsdfoundation/freebsd-14_4`) is NOT on Azure's Trusted Launch
allowlist — regardless of `secureBootEnabled` value. Even vTPM-only mode (`secureBootEnabled: false,
vTpmEnabled: true`) is rejected.

**Fix:** Remove the `securityProfile` block entirely from OPNsense VM resources. Do not set
`securityType: 'Standard'` — just omit the block. FreeBSD deploys correctly as a standard Gen2 VM.

See also: [`docs/architecture/trusted-launch.md`](./architecture/trusted-launch.md) and
[`docs/troubleshooting-freebsd-on-azure.md`](./troubleshooting-freebsd-on-azure.md#1-no-trusted-launch-support).

---

### "Microsoft.OSTCExtensions.CustomScriptForLinux ... SyntaxError" (Round 2)

**Full error:**
```
SyntaxError: leading zeros in decimal integer literals are not permitted;
use an 0o prefix for octal integers
  File ".../customscript.py", line 62: os.chmod('/var/log/azure/', 0700)
```

**Cause:** The `Microsoft.OSTCExtensions.CustomScriptForLinux` extension handler (v1.4.1.0) is
written in Python 2 syntax. FreeBSD 14.4 has Python 3 only. The handler fails at its own
installation — your custom script never executes.

**Fix:** Do not use any Azure VM extension on FreeBSD 14.4. Use cloud-init (`customData`) instead.
This lab migrated to cloud-init in Round 3+ (see `bicep/cloud-init/opnsense-bootstrap.yaml`).

See also: [`docs/troubleshooting-freebsd-on-azure.md`](./troubleshooting-freebsd-on-azure.md#2-no-vm-extensions-work).

---

### "az vm run-command invoke ... cannot execute binary file: Exec format error" (Round 3)

**Full error:**
```
Non-zero exit code: 126,
/var/lib/waagent/Microsoft.CPlat.Core.RunCommandLinux-1.0.9/bin/run-command-shim install
+ .../bin/run-command-extension install
  cannot execute binary file: Exec format error
```

**Cause:** `az vm run-command invoke --command-id RunShellScript` **implicitly installs**
`Microsoft.CPlat.Core.RunCommandLinux` before executing. This extension's binary is a Linux ELF.
FreeBSD 14.4 cannot run Linux ELF binaries without the `linuxulator` kernel module (not loaded by
default on Azure-hosted images). The `az vm run-command` path does **not** bypass the extension
framework on this image.

**Fix:** Use cloud-init (`customData`) for all FreeBSD first-boot configuration. The current
`deploy.azcli` does this via `bootstrapUri` passed to the Bicep template.

---

### "cloud-init fetches stale configureopnsense.sh from GitHub" (Round 4)

**Symptom:** OPNsense bootstrap runs but uses the old 6-argument `configureopnsense.sh` interface
or the pre-Phase-1 version with `python` calls. Bootstrap may appear to complete but VXLAN is not
configured.

**Cause:** `OPN_BOOTSTRAP_URI` defaults to
`https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/`. If your local `main`
branch has changes that have not been pushed, cloud-init fetches the old script from GitHub. The
OPNsense NVM VM's `runcmd` runs at first boot — it fetches from GitHub at that exact moment.

**Fix:** Push your changes to the branch that `OPN_BOOTSTRAP_URI` points to before deploying:

```bash
git push origin main
# Verify the updated script is live:
curl -s "https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/configureopnsense.sh" | head -5
```

**Alternative:** Point `OPN_BOOTSTRAP_URI` to a specific commit SHA or pinned branch:

```bash
export OPN_BOOTSTRAP_URI="https://raw.githubusercontent.com/dmauser/azure-gateway-lb/<commit-sha>/scripts/"
bash deploy.azcli
```

---

### "configureopnsense.sh fails with `python: not found`" (Round 5)

**Symptom:** OPNsense VMs are running but OPNsense web UI is not responding. Bootstrap log (`/var/log/opnsense-bootstrap.log`) either does not exist or contains only a few lines. VXLAN interfaces are absent.

**Cause:** FreeBSD 14.4 has `python3` and `python3.11` but no `python` symlink. The bootstrap script
called `python get_nic_gw.py $3` under `set -euo pipefail`, causing immediate exit before OPNsense
was installed. The sentinel file (`/var/run/opnsense-bootstrap-done`) was still written (due to tee
masking the exit code — a separate bug fixed in Round 6), making the failure invisible.

**Fix (Round 6, commit `519bf26`):** `configureopnsense.sh` now calls `python3 get_nic_gw.py $3`.

**Audit rule:** On FreeBSD 14.4, replace every `python` call with `python3`. Never assume a `python`
symlink exists.

---

### "OPNsense bootstrap silently completes but VXLAN never comes up" (Rounds 5/6)

**Symptom:** `/var/run/opnsense-bootstrap-done` exists on NVAs, but OPNsense web UI does not
respond and VXLAN traffic does not flow. The sentinel file's existence alone is not proof of
successful bootstrap.

**Cause (pre-Round-6):** The `runcmd` step used `configureopnsense.sh ... | tee logfile`. `tee`
always exits 0. The downstream sentinel-write step ran unconditionally — writing "bootstrap-done"
even when the script had failed and exited with a non-zero code.

**Fix (Round 6, commit `519bf26`):** The `runcmd` now captures `rc=$?` before writing the sentinel.
Success writes `/var/run/opnsense-bootstrap-done`; failure writes `/var/run/opnsense-bootstrap-failed`
with the exit code. `exit $rc` causes cloud-init to mark the instance as failed.

**Diagnosis after fix:** Check both sentinel files:

```bash
# SSH into NVA (via Bastion or SSH NAT rule)
cat /var/run/opnsense-bootstrap-done    # present = true success
cat /var/run/opnsense-bootstrap-failed  # present = failure; contains rc value
tail -50 /var/log/opnsense-bootstrap.log
cloud-init status --long
```

---

### "GLB chain command fails with InvalidGlobalResourceReference" (Round 5)

**Full error:**
```
(InvalidGlobalResourceReference) Resource .../provider-nva-glb/frontendIPConfigurations/FW
referenced by .../consumer-elb was not found.
```

**Cause:** ARM propagation delay. The Bicep deployment returns success when ARM accepts the
deployment, but the GLB resource may not have fully propagated across all ARM endpoints by the time
`az network lb frontend-ip update --gateway-lb $glbfeid` is issued.

**Fix (Round 6, commit `519bf26`):** `deploy.azcli` now polls until the GLB frontend IP is
queryable before attempting the chain:

```bash
until az network lb frontend-ip show -g "$provider_rg" \
        --lb-name provider-nva-glb --name FW --query id -o tsv >/dev/null 2>&1; do
  # retries every 5 s, up to 120 s ceiling
done
```

**Manual workaround (if running an older deploy):** Wait 2–3 minutes after Bicep deployment
completes, then re-run:

```bash
glbfeid=$(az network lb frontend-ip show \
    -g "$provider_rg" --lb-name provider-nva-glb --name FW --query id -o tsv)
az network lb frontend-ip update \
    -g "$consumer_rg" --name frontendip1 --lb-name consumer-elb \
    --public-ip-address consumer-elb-pip --gateway-lb "$glbfeid" --output none
```

---

### "Consumer VM nginx returns 502/timeout" after GLB chain is active

**Symptom:** `curl http://<consumer-elb-pip>` succeeds before chaining but times out or returns
502 after GLB chain is established.

**Cause (most likely):** OPNsense bootstrap failed on one or both NVAs. VXLAN is not configured.
Traffic hits the GLB → NVA but is not forwarded correctly. The default OPNsense firewall blocks all
traffic.

**Diagnosis:**

```bash
# 1. Check bootstrap sentinels on each NVA (SSH via Bastion or SSH NAT rule on port 22)
ssh root@<nva-private-ip>
cat /var/run/opnsense-bootstrap-done
cat /var/run/opnsense-bootstrap-failed
tail -50 /var/log/opnsense-bootstrap.log

# 2. Check cloud-init status on NVAs
cloud-init status --long

# 3. Verify VXLAN interfaces exist on NVA
ifconfig | grep vxlan
# Expected: vxlan0, vxlan1

# 4. Bypass GLB chain to confirm consumer side is healthy:
az network lb frontend-ip update \
    -g "$consumer_rg" --name frontendip1 --lb-name consumer-elb \
    --public-ip-address consumer-elb-pip --gateway-lb "" --output none
curl http://<consumer-elb-pip>
# If this works, consumer side is fine — problem is NVA bootstrap.
```

---

## VXLAN Tunnel Debugging and Proof

The GLB uses VXLAN encapsulation between the GLB and the OPNsense NVAs. Two tunnels exist:

| VXLAN Interface | Direction | UDP Port | VNI |
|-----------------|-----------|----------|-----|
| `vxlan0` | External (Internet → NVA) | 10800 | 800 |
| `vxlan1` | Internal (NVA → Backend) | 10801 | 801 |

### Verify VXLAN ports are open

From the OPNsense VM (SSH or console), verify VXLAN endpoints are listening:
```bash
# On OPNsense (FreeBSD)
sockstat -l -P udp | grep -E '10800|10801'
```

From a Linux host on the same subnet as the NVA's untrusted NIC:
```bash
sudo nmap -sU -p 10800,10801 <nva-external-ip>
```

### Azure health probe MAC address

The Azure platform sends VXLAN health probes sourced from a well-known MAC: `12:34:56:78:9a:bc`. This corresponds to the Azure platform IP `168.63.129.16`.

**Why it matters:** OPNsense firewall rules must not block traffic from this MAC/IP. If the GLB health probe fails, the NVA is removed from the GLB backend pool and traffic stops flowing.

Verify probe traffic reaches the NVA:
```bash
# On OPNsense — capture on the internal NIC (hn1 or equivalent)
tcpdump -n -i hn1 host 168.63.129.16
# You should see periodic TCP/443 probe packets
```

### tcpdump on OPNsense to verify VXLAN traffic

```bash
# SSH into OPNsense (see OPNsense Access section for credentials)

# Watch all VXLAN encapsulated traffic (external interface — inbound from Internet)
tcpdump -n -i vxlan0

# Watch all VXLAN encapsulated traffic (internal interface — outbound to backend)
tcpdump -n -i vxlan1

# Verify Internet-bound outbound traffic passes through NVA (test: curl from consumer-vm)
tcpdump -n -i vxlan1 host 8.8.8.8

# Filter for a specific consumer IP
tcpdump -n -i vxlan0 host <consumer-elb-public-ip>
```

**Expected behavior:** When you `curl http://<consumer-elb-pip>` from outside, you should see matching packets appear on `vxlan0` (inbound) and then on `vxlan1` (return path).

### VXLAN proof: tcpdump on the physical NIC (UDP port level)

The definitive proof that VXLAN encapsulation is working is capturing UDP traffic on ports 10800
and 10801 at the physical NIC level. This is the evidence Daniel requires — not inferred from
nginx HTTP response alone.

**Procedure:**

1. SSH into the OPNsense NVA (see [OPNsense Access](#opnsense-access) section):

```bash
# Via Bastion (if deployed):
az network bastion ssh \
    --name provider-bastion \
    --resource-group "$provider_rg" \
    --target-resource-id "$(az vm show -g "$provider_rg" -n provider-nva-primary --query id -o tsv)" \
    --auth-type ssh-key \
    --username root \
    --ssh-key ~/.ssh/id_rsa

# Via SSH NAT rule (if port 22 NAT configured on provider-nva-elb):
provider_elb_pip=$(az network public-ip show -g "$provider_rg" --name provider-nva-elb-pip --query ipAddress -o tsv)
ssh root@$provider_elb_pip -p <22-nat-frontend-port>
```

2. Start traffic generation from outside (separate terminal):

```bash
# Generate traffic through the GLB chain:
curl http://<consumer-elb-pip>
# Or run continuously:
while true; do curl -s http://<consumer-elb-pip> > /dev/null; sleep 1; done
```

3. On the OPNsense NVA, capture VXLAN UDP traffic:

```bash
# Capture on any interface — proves the encapsulated traffic is arriving/leaving the NVA:
tcpdump -nn -i any "udp port 10800 or udp port 10801"

# Or capture on the specific physical NIC (typically hn0 or vtnet0 on Azure):
tcpdump -nn -i hn0 "udp port 10800 or udp port 10801"
```

**Expected output (PASS — VXLAN working):**

```
14:23:01.123456 IP 10.0.0.4.4789 > 10.0.0.36.10800: VXLAN, flags [I] (0x08), vni 800
IP 1.2.3.4.54321 > 10.0.0.100.80: Flags [S], seq 1234567890
14:23:01.123789 IP 10.0.0.36.10801 > 10.0.0.4.4789: VXLAN, flags [I] (0x08), vni 801
IP 10.0.0.100.80 > 1.2.3.4.54321: Flags [S.], seq 987654321
```

You will see the GLB IP (`10.0.0.4` or similar) sending VXLAN-encapsulated packets to the NVA's
trusted IP (`10.0.0.36`) on UDP 10800 (external/inbound tunnel) and the NVA sending responses
back via UDP 10801 (internal/outbound tunnel).

**FAIL condition:** No UDP 10800 or 10801 packets after 30 seconds while traffic is actively
flowing → GLB-to-NVA VXLAN is broken. Check: GLB chain established, NVA bootstrap completed,
firewall rules allow traffic.

---

## Standard LB Inbound NAT Rule Pitfall

**Symptom:** The `az network lb inbound-nat-rule create` command fails on newer Azure CLI versions with:
```
(InvalidRequestFormat) ... frontendIPConfiguration is required
```
or
```
Argument --frontend-ip-name is required for Standard SKU load balancers
```

**Root cause:** The Azure CLI (≥ 2.50) enforces explicit `--frontend-ip-name` for Standard SKU LBs. Earlier versions defaulted to the first frontend IP automatically.

**Fix:** Always pass `--frontend-ip-name` explicitly:
```bash
az network lb inbound-nat-rule create \
    -g "$consumer_rg" \
    --lb-name consumer-elb \
    --frontend-ip-name frontendip1 \   # ← explicit — required on newer CLI
    -n sshnat \
    --protocol Tcp \
    --frontend-port 50000 \
    --backend-port 22 \
    -o none
```

The current `deploy.azcli` already includes `--frontend-ip-name frontendip1` to avoid this issue.

---

## Cross-Subscription Deploy Gotchas

If you deploy the provider GLB in a different subscription than the consumer ELB, the GLB chaining step requires careful subscription context management.

### Correct order of operations

```bash
# 1. Ensure you are in the PROVIDER subscription context
az account set --subscription "$PROVIDER_SUBSCRIPTION_ID"

# 2. Capture the GLB frontend IP resource ID while in provider context
glbfeid=$(az network lb frontend-ip show \
    -g "$provider_rg" \
    --lb-name provider-nva-glb \
    --name FW \
    --query id \
    --output tsv)
echo "GLB Frontend ID: $glbfeid"   # verify it's populated

# 3. Switch to CONSUMER subscription
az account set --subscription "$CONSUMER_SUBSCRIPTION_ID"

# 4. Now chain the consumer ELB to the GLB
az network lb frontend-ip update \
    -g "$consumer_rg" \
    --name frontendip1 \
    --lb-name consumer-elb \
    --public-ip-address consumer-elb-pip \
    --gateway-lb "$glbfeid" \
    --output none
```

**Critical:** If you forget step 2 and switch subscriptions before capturing `$glbfeid`, the variable will be empty and the update will fail or silently unchain the LB.

**Verify `$glbfeid` is set:**
```bash
[[ -n "$glbfeid" ]] && echo "OK: $glbfeid" || echo "ERROR: glbfeid is empty — re-capture in provider sub"
```

---

## OPNsense Access

### Default credentials

| Credential | Value |
|------------|-------|
| Username | `root` |
| Password | `opnsense` |

> ⚠️ **Change these immediately after first login.** The default credentials are well-known and the management port is reachable via the provider ELB Public IP.

### Web UI access

The OPNsense web interface is reachable via HTTPS through the provider ELB inbound NAT rules:

```bash
# Get provider ELB public IP
az network public-ip show \
    -g glb-provider-rg \
    --name provider-nva-elb-pip \
    --query ipAddress -o tsv
```

| NVA | NAT Port | URL |
|-----|----------|-----|
| Primary | 50443 | `https://<provider-elb-pip>:50443` |
| Secondary | 50444 | `https://<provider-elb-pip>:50444` |

Your browser will show a certificate warning — accept and proceed (self-signed cert).

### SSH access after bootstrap

```bash
# SSH to OPNsense primary via ELB (port 22 on OPNsense, mapped from 50443 → not default)
# Use Bastion if deployed, or inbound NAT if configured

# If Bastion is deployed:
az network bastion ssh \
    --name provider-bastion \
    --resource-group glb-provider-rg \
    --target-resource-id "<provider-nva-primary-vm-resource-id>" \
    --auth-type password \
    --username root
```

### Bootstrap completion check (cloud-init, post-Round-3)

The OPNsense bootstrap runs via cloud-init (`customData`). Verify it completed:

```bash
# SSH into NVA (see OPNsense Access section)

# Check success sentinel (present = bootstrap truly succeeded):
cat /var/run/opnsense-bootstrap-done
# Expected: bootstrap-ok-20260509T182345Z (or similar ISO8601Z timestamp)

# Check failure sentinel (present = bootstrap failed — inspect log for cause):
cat /var/run/opnsense-bootstrap-failed
# Expected: NOT PRESENT on a healthy deploy. If present: bootstrap-failed-rc=<N>-<timestamp>

# Review full bootstrap log:
tail -50 /var/log/opnsense-bootstrap.log

# cloud-init native status:
cloud-init status --long
# Expected: status: done
```

> ⚠️ The bootstrap sentinels are only reliable on Round 6+ code. On earlier versions (before commit
> `519bf26`), the sentinel was written even when the script failed due to `tee` masking the exit code.
> If you suspect stale code, check the bootstrap log content rather than relying on the sentinel alone.

---

## Verifying GLB Chaining

To confirm the consumer ELB is chained to the provider GLB, check the `gatewayLoadBalancer.id` property on the consumer ELB frontend:

```bash
az network lb frontend-ip show \
    -g glb-consumer-rg \
    --lb-name consumer-elb \
    --name frontendip1 \
    --query gatewayLoadBalancer.id \
    -o tsv
```

- **Non-empty output** (a resource ID): GLB is chained. Traffic is flowing through OPNsense.
- **Empty output**: No chain. Traffic goes directly from ELB to consumer-vm without NVA inspection.

### Remove the chain (when troubleshooting)

To temporarily bypass the NVA and test direct connectivity:
```bash
az network lb frontend-ip update \
    -g glb-consumer-rg \
    --name frontendip1 \
    --lb-name consumer-elb \
    --public-ip-address consumer-elb-pip \
    --gateway-lb "" \
    --output none
```

Re-apply the chain when done testing (using the `glbfeid` capture pattern above).

---

## README Validation Discipline

**Principle:** Every code block in `README.md` and every `docs/` document must be runnable and
produce documented output. This is not optional — it is a maintenance gate.

### Checklist before merging a documentation change

1. **Env vars in README match `deploy.azcli`** — every variable named in the Prerequisites table
   must appear in `deploy.azcli` with the same name. Verify with:
   ```bash
   # For each var in the README table, confirm it appears in deploy.azcli:
   grep "SSH_PUBLIC_KEY\|OPN_BOOTSTRAP_URI\|SUBSCRIPTION_ID\|RG_CONSUMER\|RG_PROVIDER\|LOCATION\|ADMIN_USERNAME\|BASTION_DEPLOY" deploy.azcli
   ```

2. **Resource names match** — `PublicIPconsumer-elb` vs `consumer-elb-pip` etc. Grep for resource
   names used in README commands and verify they match Bicep/deploy outputs.

3. **Commands parse cleanly** — no obviously broken syntax: balanced quotes, no missing `$`, no
   unclosed subshells. For bash blocks: `bash -n <(cat readme-snippet.sh)`.

4. **Links resolve** — all `[text](./path)` links in docs/ point to files that exist.

5. **After live deploy, update expected outputs** — if `curl http://consumer-elb-pip` returns a
   specific string, that string must be documented verbatim.

### OPNsense SSH access details (for tcpdump validation)

OPNsense `configureopnsense.sh` (post-Round-1) enables SSH. Default credentials:

| Field | Value |
|-------|-------|
| Username | `root` |
| Password | `opnsense` |
| Auth type | Password (change immediately) |
| SSH port | 22 (standard) |

Access paths:
- **Via Bastion** (if `BASTION_DEPLOY=true`): `az network bastion ssh` (see [OPNsense Access](#opnsense-access))
- **Via provider-nva-elb NAT** (if SSH NAT rule is configured): `ssh root@<provider-elb-pip> -p <nat-port>`
- **Note:** Current Bicep only creates NAT rules for port 443 (50443 → primary, 50444 → secondary). No default port 22 NAT rule. Deploy with `BASTION_DEPLOY=true` for SSH access, or add an SSH NAT rule manually.

---

## Additional resources

- [Azure Gateway Load Balancer overview](https://learn.microsoft.com/azure/load-balancer/gateway-overview)
- [OPNsense in Azure — bootstrap repo](https://github.com/dmauser/opnazure)
- [Linux VXLAN tutorial](./linux-vxlan-tutorial.md)
- [FreeBSD on Azure constraints](./troubleshooting-freebsd-on-azure.md)
- [Trusted Launch ADR](./architecture/trusted-launch.md)
- [Cloud-Init Migration ADR](./architecture/cloud-init-migration.md)
