param untrustedSubnetId string
param trustedSubnetId string
param virtualMachineName string
param TempUsername string
param TempPassword string
param virtualMachineSize string
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

output untrustedNicIP string = untrustedNic.outputs.nicIP
output trustedNicIP string = trustedNic.outputs.nicIP
