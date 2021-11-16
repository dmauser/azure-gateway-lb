param untrustedSubnetId string
param trustedSubnetId string
param virtualMachineName string
param TempUsername string
param TempPassword string
param virtualMachineSize string
param OPNScriptURI string
param ShellScriptName string
param ShellScriptParameters string
param nsgId string = ''
param ExternalLoadBalancerBackendAddressPoolId string
param InternalLoadBalancerBackendAddressPoolId string

var untrustedNicName = '${virtualMachineName}-Untrusted-NIC'
var trustedNicName = '${virtualMachineName}-Trusted-NIC'

module untrustedNic '../vnet/privateniclb.bicep' = {
  name: untrustedNicName
  params:{
    nicName: untrustedNicName
    subnetId: untrustedSubnetId
    enableIPForwarding: true
    nsgId: nsgId
    loadBalancerBackendAddressPoolId: ExternalLoadBalancerBackendAddressPoolId
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

resource OPNsense 'Microsoft.Compute/virtualMachines@2021-03-01' = {
  name: virtualMachineName
  location: resourceGroup().location
  properties: {
    osProfile: {
      computerName: virtualMachineName
      adminUsername: TempUsername
      adminPassword: TempPassword
    }
    hardwareProfile: {
      vmSize: virtualMachineSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
      }
      imageReference: {
        publisher: 'MicrosoftOSTC'
        offer: 'FreeBSD'
        sku: '12.0'
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
  }
}

resource vmext 'Microsoft.Compute/virtualMachines/extensions@2015-06-15' = {
  name: '${OPNsense.name}/CustomScript'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.OSTCExtensions'
    type: 'CustomScriptForLinux'
    typeHandlerVersion: '1.4'
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
output trustedNicIP string = trustedNic.outputs.nicIP
