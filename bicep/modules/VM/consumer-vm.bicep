@sys.description('Consumer VM name.')
param virtualMachineName string = 'consumer-vm'

@sys.description('VM size. Standard_B1s is sufficient for the nginx test workload.')
param virtualMachineSize string = 'Standard_B1s'

@sys.description('Subnet resource ID for the consumer VM NIC.')
param subnetId string

@sys.description('Admin username for the VM.')
param adminUsername string

@sys.description('SSH public key for the admin user.')
param sshPublicKey string

@sys.description('Optional NSG resource ID to attach to the NIC. Leave empty to rely on subnet-level NSG.')
param nsgId string = ''

// Cloud-init YAML is read at compile time and base64-encoded into osProfile.customData.
// This replaces the Custom Script Extension (CSE) nginx installation — cloud-init runs
// synchronously during first boot so nginx is ready before the VM reports healthy to the LB.
var cloudInitData = base64(loadTextContent('../../cloud-init/consumer-vm.yaml'))

var nicName = '${virtualMachineName}-nic'

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: resourceGroup().location
  properties: {
    networkSecurityGroup: empty(nsgId) ? null : {
      id: nsgId
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource consumerVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: virtualMachineName
  location: resourceGroup().location
  properties: {
    osProfile: {
      computerName: virtualMachineName
      adminUsername: adminUsername
      // Password authentication disabled — SSH key only
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      // Cloud-init replaces the Custom Script Extension for nginx installation.
      // Injected at first boot — VM is fully provisioned before reporting healthy to the LB.
      customData: cloudInitData
    }
    hardwareProfile: {
      vmSize: virtualMachineSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      // Ubuntu 22.04 LTS Gen2 — required for Trusted Launch (Gen2 only).
      // Canonical's Gen2 SKU ships a Microsoft-signed UEFI shim, enabling full Secure Boot.
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
    // Full Trusted Launch: Secure Boot + vTPM.
    // Ubuntu 22.04 Gen2 ships shim-signed (Microsoft UEFI CA enrolled), so Secure Boot is safe.
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

output nicId string = nic.id
output privateIP string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output vmId string = consumerVm.id
