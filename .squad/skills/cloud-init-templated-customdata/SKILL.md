# SKILL: Templated cloud-init via Bicep `loadTextContent + replace + base64`

**Skill ID:** cloud-init-templated-customdata
**Author:** Clu (IaC Engineer)
**Date:** 2026-05-09T13:42:28-05:00
**Extracted from:** azure-gateway-lb Path D-proper (OPNsense bootstrap)

---

## Problem

You need to inject a parameterised cloud-init `#cloud-config` YAML into a VM's
`osProfile.customData` at deploy time. The YAML contains deployment-specific values
(URIs, roles, IP addresses) that differ per VM instance and cannot be hard-coded.

Azure's `osProfile.customData` field requires a **base64-encoded** string.

---

## Pattern

### 1. Author the YAML template with placeholders

Store the template in `bicep/cloud-init/<purpose>.yaml`. Use `__UPPER_SNAKE__` placeholder
convention (double underscores, all-caps) for easy `sed`/`replace` targeting:

```yaml
#cloud-config
runcmd:
  - fetch -o /tmp/bootstrap.sh __URI__bootstrap.sh
  - sh /tmp/bootstrap.sh __URI__ __ROLE__ __LOCAL_CIDR__ __PEER_IP__
```

### 2. Load and substitute in the Bicep module

The module that owns the VM resource performs compile-time load and runtime substitution:

```bicep
// --- Parameters (all with defaults for backward compat) ---
param role         string = ''
param localIP      string = ''   // with CIDR, e.g. 10.0.1.4/24
param peerIP       string = ''   // without CIDR, e.g. 10.0.1.5
param bootstrapUri string = ''   // trailing slash
param customData   string = ''   // raw override; lower priority than bootstrapUri path

// --- Template substitution ---
// loadTextContent is compile-time (path relative to this .bicep file).
// replace() and base64() are runtime ARM functions — work with runtime param values.
var cloudInitTemplate = loadTextContent('../../cloud-init/<purpose>.yaml')
var customDataYaml = replace(replace(replace(replace(
    cloudInitTemplate,
    '__URI__',        bootstrapUri),
    '__ROLE__',       role),
    '__LOCAL_CIDR__', localIP),
    '__PEER_IP__',    peerIP)

// Three-tier resolution:
//   1. bootstrapUri non-empty → template substitution (canonical path)
//   2. bootstrapUri empty + customData non-empty → raw override (backward compat)
//   3. both empty → null (omit customData from ARM template)
var resolvedCustomData = empty(bootstrapUri)
    ? (empty(customData) ? null : customData)
    : base64(customDataYaml)

// --- VM resource ---
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: virtualMachineName
  location: resourceGroup().location
  properties: {
    osProfile: {
      computerName: virtualMachineName
      adminUsername: adminUsername
      customData: resolvedCustomData   // null is silently omitted by ARM
      // ... rest of osProfile
    }
    // ...
  }
}
```

### 3. Wire in the orchestrating Bicep template

The orchestrating template (parent of the VM module) owns parameter derivation and
passes resolved values down:

```bicep
// --- Top-level parameter ---
param bootstrapUri string = 'https://raw.githubusercontent.com/example/repo/main/scripts/'

// --- IP derivation from subnet address prefix (VTEP / tunnel endpoint pattern) ---
// Convention: primary VTEP = base+4, secondary VTEP = base+5
var trustedNetAddr = split(trustedSubnet.properties.addressPrefix, '/')[0]
var trustedOctets  = split(trustedNetAddr, '.')
var ipBase3        = '${trustedOctets[0]}.${trustedOctets[1]}.${trustedOctets[2]}'
var primaryLocalIP    = '${ipBase3}.${string(int(trustedOctets[3]) + 4)}/24'
var primaryPeerIP     = '${ipBase3}.${string(int(trustedOctets[3]) + 5)}'
var secondaryLocalIP  = '${ipBase3}.${string(int(trustedOctets[3]) + 5)}/24'
var secondaryPeerIP   = '${ipBase3}.${string(int(trustedOctets[3]) + 4)}'

// --- Module call ---
module primaryVm 'modules/VM/your-vm.bicep' = {
  name: 'primary-vm'
  params: {
    role:         'Primary'
    localIP:      primaryLocalIP
    peerIP:       primaryPeerIP
    bootstrapUri: bootstrapUri
    // ... other params
  }
}
```

### 4. Pass `bootstrapUri` from the deploy script

```bash
# Optional env var with sensible default
OPN_BOOTSTRAP_URI="${OPN_BOOTSTRAP_URI:-https://raw.githubusercontent.com/example/repo/main/scripts/}"

az deployment group create \
    --template-file bicep/main.bicep \
    --parameters \
        bootstrapUri="$OPN_BOOTSTRAP_URI" \
        # ... other params
```

---

## Rules and Gotchas

| Rule | Detail |
|---|---|
| `loadTextContent` path is relative to the `.bicep` file | From `bicep/modules/VM/`, use `../../cloud-init/file.yaml` |
| File must exist at compile time | Create a stub if the YAML is being authored in parallel |
| `null` customData omits the field from ARM | Safe — no empty string padding needed |
| Chained `replace()` — order matters if placeholders share substrings | `__URI__` before `__LOCAL_CIDR__` etc. — no overlap in this pattern |
| `base64()` is an ARM runtime function | Works correctly with runtime strings |
| YAML stub must have the exact placeholder strings | `__URI__`, `__ROLE__`, `__LOCAL_CIDR__`, `__PEER_IP__` (double-underscore delimited) |
| Do NOT use `cidrHost()` for runtime subnet-derived IPs | Use `split` + `int` arithmetic for Bicep version portability |
| Setting `osProfile.customData` to `null` → field omitted | Equivalent to not passing customData; backward compat preserved |

---

## Validation

```bash
# Build must complete with exit 0
az bicep build --file bicep/main.bicep

# Check placeholder contract in cloud-init YAML
grep "__URI__\|__ROLE__\|__LOCAL_CIDR__\|__PEER_IP__" bicep/cloud-init/<purpose>.yaml

# Verify no placeholders survive substitution (post-deploy, inside VM)
cat /var/log/cloud-init-output.log | grep "__"  # should be empty
```

---

## Real-world Usage

- **Project:** azure-gateway-lb
- **VM type:** OPNsense NVA on FreeBSD 14.4 (`thefreebsdfoundation/freebsd-14_4`)
- **Module:** `bicep/modules/VM/opnsense-vm-active-active.bicep`
- **Template:** `bicep/cloud-init/opnsense-bootstrap.yaml`
- **Orchestrator:** `bicep/glb-active-active.bicep`
- **Why:** All Azure VM extension mechanisms (CustomScriptForLinux, CustomScript, RunCommandLinux) fail on FreeBSD 14.4 due to Python 2 / Linux ELF incompatibility. `customData` + bsdcloudinit is the only supported bootstrap path.
