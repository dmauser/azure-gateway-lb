param untrustedSubnetId string
param trustedSubnetId string
param publicIPId string = ''
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


var untrustedNicName = '${virtualMachineName}-Untrusted-NIC'
var trustedNicName = '${virtualMachineName}-Trusted-NIC'

module untrustedNic '../vnet/publicnic.bicep' = {
  name: untrustedNicName
  params:{
    nicName: untrustedNicName
    subnetId: untrustedSubnetId
    publicIPId: publicIPId
    enableIPForwarding: true
    nsgId: nsgId
  }
}

module trustedNic '../vnet/privatenic.bicep' = {
  name: trustedNicName
  params:{
    nicName: trustedNicName
    subnetId: trustedSubnetId
    enableIPForwarding: true
    nsgId: nsgId
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
    // Trusted Launch: vTPM only — Secure Boot disabled.
    // FreeBSD/OPNsense does not have a Microsoft-signed UEFI shim; enabling Secure Boot
    // would prevent the VM from booting. vTPM provides attestation without the signing requirement.
    // The freebsd-14_4 Gen2 SKU supports Trusted Launch in vTPM-only mode.
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: false
        vTpmEnabled: true
      }
    }
  }
}

output untrustedNicIP string = untrustedNic.outputs.nicIP
output trustedNicIP string = trustedNic.outputs.nicIP
