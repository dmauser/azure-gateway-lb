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

@sys.description('NVA role for OPNsense HA config. "Primary" or "Secondary". Passed as $2 to configureopnsense.sh.')
param role string = ''

@sys.description('Local VTEP IP with /24 CIDR mask (e.g. 10.0.0.37/24). Passed as $3 to configureopnsense.sh.')
param localIP string = ''

@sys.description('Peer NVA VTEP IP without CIDR (e.g. 10.0.0.38). Passed as $4 to configureopnsense.sh.')
param peerIP string = ''

@sys.description('Base URI for OPNsense bootstrap scripts (trailing slash). Used as CSE fileUris base and $1 to configureopnsense.sh.')
param bootstrapUri string = ''

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
    name: '14_1-release-amd64-gen2-zfs'
    product: 'freebsd-14_1'
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
      // customData intentionally omitted: freebsd-14_1 marketplace image does not ship cloud-init.
      // Bootstrap is delivered via Microsoft.OSTCExtensions.CustomScriptForLinux v1.5 (see vmext below).
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
        offer: 'freebsd-14_1'
        sku: '14_1-release-amd64-gen2-zfs'
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
    // securityProfile intentionally omitted: FreeBSD 14.1 (thefreebsdfoundation/freebsd-14_1)
    // does NOT support securityType 'TrustedLaunch'. OPNsense NVAs deploy as Standard Gen2 VMs.
  }
}

output untrustedNicIP string = untrustedNic.outputs.nicIP
output trustedNicIP string = trustedNic.outputs.nicIP

// Bootstrap via CustomScriptForLinux v1.5.
// opnazure reference (dmauser/opnazure) uses this exact publisher/type/version on FreeBSD 14.1 and it works.
// Rounds 2-6 failures were: v1.4 Python 2 syntax error, Linux ELF run-command, cloud-init absent on image.
// v1.5 is Python 3 compatible; shim.sh fix resolves FreeBSD PATH issue seen in v1.4.
// fileUris downloads configureopnsense.sh; commandToExecute runs it with FreeBSD POSIX sh.
// Ref: https://github.com/dmauser/opnazure/blob/main/bicep/modules/VM/opnsense.bicep
resource vmext 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = if (!empty(bootstrapUri)) {
  parent: OPNsense
  name: 'CustomScript'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.OSTCExtensions'
    type: 'CustomScriptForLinux'
    typeHandlerVersion: '1.5'
    autoUpgradeMinorVersion: false
    settings: {
      fileUris: [
        '${bootstrapUri}configureopnsense.sh'
      ]
      commandToExecute: 'sh configureopnsense.sh ${bootstrapUri} ${role} ${localIP} ${peerIP}'
    }
  }
}
