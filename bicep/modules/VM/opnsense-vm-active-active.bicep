param untrustedSubnetId string
param trustedSubnetId string
param virtualMachineName string
param TempUsername string
// To pass TempPassword from Key Vault, use a parameters file like:
// {
//   "TempPassword": {
//     "reference": {
//       "keyVault": { "id": "/subscriptions/.../vaults/<vault>" },
//       "secretName": "<secret>"
//     }
//   }
// }
@secure()
param TempPassword string
@sys.description('SSH public key for admin user. When provided, key is added to authorized_keys. Leave empty to use password-only authentication.')
param adminSshKey string = ''
param virtualMachineSize string
param nsgId string = ''
param ExternalLoadBalancerBackendAddressPoolId string
param InternalLoadBalancerBackendAddressPoolId string
param ExternalloadBalancerInboundNatRulesId string

@sys.description('NVA role passed to cloud-init for OPNsense HA config. "Primary" or "Secondary".')
param role string = ''

@sys.description('Local VTEP IP with /24 CIDR mask (e.g. 10.0.0.36/24). Passed to cloud-init.')
param localIP string = ''

@sys.description('Peer NVA VTEP IP without CIDR (e.g. 10.0.0.37). Passed to cloud-init.')
param peerIP string = ''

@sys.description('Base URI for OPNsense bootstrap scripts (trailing slash). Passed to cloud-init.')
param bootstrapUri string = ''

@sys.description('Pre-encoded customData override. When non-empty and bootstrapUri is empty, used directly. Prefer bootstrapUri path.')
param customData string = ''

// Cloud-init template is loaded at compile time; __PLACEHOLDER__ substitution is runtime.
var cloudInitTemplate = loadTextContent('../../cloud-init/opnsense-bootstrap.yaml')
var customDataYaml = replace(replace(replace(replace(cloudInitTemplate, '__URI__', bootstrapUri), '__ROLE__', role), '__LOCAL_CIDR__', localIP), '__PEER_IP__', peerIP)
// bootstrapUri path is canonical; fall back to raw customData param for backward compat; null = no customData.
var resolvedCustomData = empty(bootstrapUri) ? (empty(customData) ? null : customData) : base64(customDataYaml)

var untrustedNicName = '${virtualMachineName}-untrusted-nic'
var trustedNicName = '${virtualMachineName}-trusted-nic'

module untrustedNic '../vnet/publicniclb.bicep' = {
  name: untrustedNicName
  params:{
    nicName: untrustedNicName
    subnetId: untrustedSubnetId
    enableIPForwarding: true
    nsgId: nsgId
    loadBalancerBackendAddressPoolId: ExternalLoadBalancerBackendAddressPoolId
    loadBalancerInboundNatRules: ExternalloadBalancerInboundNatRulesId
    }
}

module trustedNic '../vnet/privateniclb.bicep' = {
  name: trustedNicName
  params:{
    nicName: trustedNicName
    subnetId: trustedSubnetId
    enableIPForwarding: true
    nsgId: nsgId
    loadBalancerBackendAddressPoolId: InternalLoadBalancerBackendAddressPoolId
  }
}

resource OPNsense 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: virtualMachineName
  location: resourceGroup().location
  plan: {
    name: '14_4-release-amd64-gen2-ufs'
    product: 'freebsd-14_4'
    publisher: 'thefreebsdfoundation'
  }
  properties: {
    osProfile: {
      computerName: virtualMachineName
      adminUsername: TempUsername
      adminPassword: TempPassword
      linuxConfiguration: empty(adminSshKey) ? null : {
        disablePasswordAuthentication: false
        ssh: {
          publicKeys: [
            {
              path: '/home/${TempUsername}/.ssh/authorized_keys'
              keyData: adminSshKey
            }
          ]
        }
      }
      // Baked-in cloud-init: bsdcloudinit executes runcmd at first boot.
      // Substituted at deploy time: __URI__, __ROLE__, __LOCAL_CIDR__, __PEER_IP__.
      customData: resolvedCustomData
    }
    hardwareProfile: {
      vmSize: virtualMachineSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
      }
      imageReference: {
        publisher: 'thefreebsdfoundation'
        offer: 'freebsd-14_4'
        sku: '14_4-release-amd64-gen2-ufs'
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: untrustedNic.outputs.nicId
          properties:{
            primary: true
          }
        }
        {
          id: trustedNic.outputs.nicId
          properties:{
            primary: false
          }
        }
      ]
    }
    // securityProfile intentionally omitted: FreeBSD 14.4 (thefreebsdfoundation/freebsd-14_4)
    // does NOT support securityType 'TrustedLaunch' — Azure rejects with
    // "Use of TrustedLaunch setting is not supported for the provided image."
    // Empirically confirmed 2026-05-09 on westus3 (Quorra live deploy).
    // OPNsense NVAs deploy as Standard Gen2 VMs with no securityProfile block.
  }
}

output untrustedNicIP string = untrustedNic.outputs.nicIP
output trustedNicIP string = trustedNic.outputs.nicIP
