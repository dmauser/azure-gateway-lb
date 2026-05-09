// bicep/consumer-vm.bicep — Top-level consumer VM deployment template.
//
// Deploys: NIC + Ubuntu 22.04 LTS Gen2 VM with cloud-init (nginx) and full Trusted Launch.
//
// Prerequisites (created by deploy.azcli steps 1-4 before this template is called):
//   - Resource group must exist
//   - existingVNetName / existingSubnetName must exist in this resource group
//
// Usage (deploy.azcli step 5):
//   az deployment group create \
//     --resource-group <consumer-rg> \
//     --template-file bicep/consumer-vm.bicep \
//     --parameters adminUsername=<user> sshPublicKey="<ssh-pub-key-string>"
//
// After deployment, step 6 (LB attachment) uses NIC name '<virtualMachineName>-nic'
// which is deterministic and exposed as the 'nicName' output.

@sys.description('Admin username for the VM.')
param adminUsername string

@sys.description('SSH public key for the admin user. Full OpenSSH public key string.')
param sshPublicKey string

@sys.description('Consumer VM name.')
param virtualMachineName string = 'consumer-vm'

@sys.description('VM size. Standard_B1s is sufficient for the nginx lab workload.')
param virtualMachineSize string = 'Standard_B1s'

@sys.description('Existing VNet name in this resource group (created by deploy.azcli step 1).')
param existingVNetName string = 'consumer-vnet'

@sys.description('Existing subnet name within the VNet (created by deploy.azcli step 1).')
param existingSubnetName string = 'vmsubnet'

// Resolve the existing subnet created by deploy.azcli step 1.
// NSG is applied at the subnet level (deploy.azcli step 2) — not on the NIC.
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  name: '${existingVNetName}/${existingSubnetName}'
}

module consumerVm 'modules/VM/consumer-vm.bicep' = {
  name: virtualMachineName
  params: {
    virtualMachineName: virtualMachineName
    virtualMachineSize: virtualMachineSize
    subnetId: subnet.id
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    // nsgId omitted: NSG is applied at subnet level, not NIC level.
  }
}

// NIC name is deterministic: '<virtualMachineName>-nic'.
// Exposed so deploy.azcli step 6 can attach it to the LB backend pool and NAT rule
// without needing a separate az network nic show call.
output nicName string = consumerVm.outputs.nicName
output nicId string = consumerVm.outputs.nicId
output privateIP string = consumerVm.outputs.privateIP
output vmId string = consumerVm.outputs.vmId
