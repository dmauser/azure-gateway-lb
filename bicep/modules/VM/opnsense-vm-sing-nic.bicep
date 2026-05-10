param subnetId string
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
param OPNScriptURI string
param ShellScriptName string
param ShellScriptParameters string
param nsgId string = ''

var untrustedNicName = '${virtualMachineName}-NIC'

module untrustedNic '../vnet/publicnic.bicep' = {
  name: untrustedNicName
  params:{
    nicName: untrustedNicName
    subnetId: subnetId
    publicIPId: publicIPId
    enableIPForwarding: true
    nsgId: nsgId
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
      ]
    }
    // securityProfile intentionally omitted: FreeBSD 14.1 (thefreebsdfoundation/freebsd-14_1)
    // does NOT support securityType 'TrustedLaunch'. OPNsense NVAs deploy as Standard Gen2 VMs.
  }
}

resource vmext 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  name: '${OPNsense.name}/CustomScript'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.OSTCExtensions'
    type: 'CustomScriptForLinux'
    typeHandlerVersion: '1.5'
    autoUpgradeMinorVersion: false
    settings:{
      fileUris: [
        '${OPNScriptURI}${ShellScriptName}'
      ]
      commandToExecute: 'sh ${ShellScriptName} ${ShellScriptParameters}'
    }
  }
}

output untrustedNicIP string = untrustedNic.outputs.nicIP
