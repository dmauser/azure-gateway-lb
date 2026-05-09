// Parameters
@sys.description('VM size, please choose a size which allow 2 NICs.')
param virtualMachineSize string = 'Standard_B2s'

@sys.description('OPN NVA Machine Name')
param virtualMachineName string

@sys.description('Default Temporary Admin username (Used for JumpBox and temporarily deploy FreeBSD VM).')
param TempUsername string

@sys.description('Default Temporary Admin password (Used for JumpBox and temporarily deploy FreeBSD VM).')
@secure()
param TempPassword string

@sys.description('Existing Virtual Network Name')
param existingVirtualNetworkName string

@sys.description('Untrusted-Subnet Address Space')
param existingUntrustedSubnet string

@sys.description('Trusted-Subnet Address Space')
param existingTrustedSubnet string

@sys.description('Specify Public IP SKU either Basic (lowest cost) or Standard (Required for HA LB)')
@allowed([
  'Basic'
  'Standard'
])
param PublicIPAddressSku string = 'Standard'

@sys.description('Deploy Windows VM Trusted Subnet')
param DeployWindows bool = false

@sys.description('SSH public key for OPNsense admin user. When provided, key is added to authorized_keys. Leave empty to use password-only authentication.')
param adminSshKey string = ''

// Variables
var VMOPNsensePrimaryName = '${virtualMachineName}-primary'
var VMOPNsenseSecondaryName = '${virtualMachineName}-secondary'
var publicIPAddressName = '${externalLoadBalanceName}-pip'
var networkSecurityGroupName = '${virtualMachineName}-NSG'
var externalLoadBalanceName = 'provider-nva-elb'
var externalLoadBalanceFIPConfName = 'FW'
var externalLoadBalanceBAPName = 'OPNsense'
var externalLoadBalanceProbeName = 'HTTPs'
var externalLoadBalanceOutRuleName = 'OutBound-OPNSense'
var externalLoadBalanceNatRuleName1 = 'primary-nva-mgmt'
var externalLoadBalanceNatRuleName2 = 'scondary-nva-mgmt'
var internalLoadBalanceName = 'provider-nva-glb'
var internalLoadBalanceFIPConfName = 'FW'
var internalLoadBalanceBAPName = 'OPNSense'
var internalLoadBalanceProbeName = 'HTTPs'
var internalLoadBalancingRuleName = 'GWLB-HA-Port-Rule'

var winvmName = 'provider-win11'
var winvmnetworkSecurityGroupName = '${winvmName}-NSG'
var winvmpublicipName = '${winvmName}-PublicIP'

// Resources
// Create NSG
module nsgopnsense 'modules/vnet/nsg.bicep' = {
  name: networkSecurityGroupName
  params: {
    nsgName: networkSecurityGroupName
    securityRules: [
      {
        name: 'In-Any'
        properties: {
          priority: 4096
          sourceAddressPrefix: '*'
          protocol: '*'
          destinationPortRange: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Out-Any'
        properties: {
          priority: 4096
          sourceAddressPrefix: '*'
          protocol: '*'
          destinationPortRange: '*'
          access: 'Allow'
          direction: 'Outbound'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Create OPNsense Public IP
module publicip 'modules/vnet/publicip.bicep' = {
  name: publicIPAddressName
  params: {
    publicipName: publicIPAddressName
    publicipproperties: {
      publicIPAllocationMethod: 'Static'
    }
    publicipsku: {
      name: PublicIPAddressSku
      tier: 'Regional'
    }
  }
}

// Build reference of existing subnets
resource untrustedSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  name: '${existingVirtualNetworkName}/${existingUntrustedSubnet}'
}

resource trustedSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  name: '${existingVirtualNetworkName}/${existingTrustedSubnet}'
}

// External Load Balancer
module elb 'modules/vnet/lb.bicep' = {
  name: externalLoadBalanceName
  params: {
    lbName: externalLoadBalanceName
    frontendIPConfigurations: [
      {
        name: externalLoadBalanceFIPConfName
        properties: {
          publicIPAddress: {
            id: publicip.outputs.publicipId
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: externalLoadBalanceBAPName
      }
    ]
    probe: [
      {
        name: externalLoadBalanceProbeName
        properties: {
          port: 443
          protocol: 'Tcp'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    inboundNatRules: [
      {
        name: externalLoadBalanceNatRuleName1
        properties: {
          frontendPort: 50443
          backendPort: 443
          protocol: 'Tcp'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', externalLoadBalanceName, externalLoadBalanceFIPConfName)
          }
        }
      }
      {
        name: externalLoadBalanceNatRuleName2
        properties: {
          frontendPort: 50444
          backendPort: 443
          protocol: 'Tcp'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', externalLoadBalanceName, externalLoadBalanceFIPConfName)
          }
        }
      }
    ]
    outboundRules: [
      {
        name: externalLoadBalanceOutRuleName
        properties: {
          allocatedOutboundPorts: 0
          idleTimeoutInMinutes: 4
          enableTcpReset: true
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', externalLoadBalanceName, externalLoadBalanceBAPName)
          }
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', externalLoadBalanceName, externalLoadBalanceFIPConfName)
            }
          ]
          protocol: 'All'
        }
      }
    ]
  }
}

// Gateway Load Balancer
module ilb 'modules/vnet/lb.bicep' = {
  name: internalLoadBalanceName
  params: {
    lbName: internalLoadBalanceName
    skuname: 'Gateway'
    frontendIPConfigurations: [
      {
        name: internalLoadBalanceFIPConfName
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: trustedSubnet.id
          }
          privateIPAddressVersion: 'IPv4'
        }
      }
    ]
    backendAddressPools: [
      {
        name: internalLoadBalanceBAPName
        properties: {
          tunnelInterfaces: [
            {
              port: 10800
              identifier: 800
              protocol: 'VXLAN'
              type: 'Internal'
            }
            {
              port: 10801
              identifier: 801
              protocol: 'VXLAN'
              type: 'External'
            }
          ]
        }
      }
    ]
    loadBalancingRules: [
      {
        name: internalLoadBalancingRuleName
        properties: {
          frontendPort: 0
          backendPort: 0
          protocol: 'All'
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', internalLoadBalanceName, internalLoadBalanceFIPConfName)
          }
          disableOutboundSnat: true
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', internalLoadBalanceName, internalLoadBalanceBAPName)
          }
          backendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', internalLoadBalanceName, internalLoadBalanceBAPName)
            }
          ]
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', internalLoadBalanceName, internalLoadBalanceProbeName)
          }
        }
      }
    ]
    probe: [
      {
        name: internalLoadBalanceProbeName
        properties: {
          port: 443
          protocol: 'Tcp'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
}

// Create OPNsense
module opnSenseSecondary 'modules/VM/opnsense-vm-active-active.bicep' = {
  name: VMOPNsenseSecondaryName
  params: {
    TempPassword: TempPassword
    TempUsername: TempUsername
    adminSshKey: adminSshKey
    trustedSubnetId: trustedSubnet.id
    untrustedSubnetId: untrustedSubnet.id
    virtualMachineName: VMOPNsenseSecondaryName
    virtualMachineSize: virtualMachineSize
    nsgId: nsgopnsense.outputs.nsgID
    ExternalLoadBalancerBackendAddressPoolId: elb.outputs.backendAddressPools[0].id
    InternalLoadBalancerBackendAddressPoolId: ilb.outputs.backendAddressPools[0].id
    ExternalloadBalancerInboundNatRulesId: elb.outputs.inboundNatRules[1].id
  }
}

module opnSensePrimary 'modules/VM/opnsense-vm-active-active.bicep' = {
  name: VMOPNsensePrimaryName
  params: {
    TempPassword: TempPassword
    TempUsername: TempUsername
    adminSshKey: adminSshKey
    trustedSubnetId: trustedSubnet.id
    untrustedSubnetId: untrustedSubnet.id
    virtualMachineName: VMOPNsensePrimaryName
    virtualMachineSize: virtualMachineSize
    nsgId: nsgopnsense.outputs.nsgID
    ExternalLoadBalancerBackendAddressPoolId: elb.outputs.backendAddressPools[0].id
    InternalLoadBalancerBackendAddressPoolId: ilb.outputs.backendAddressPools[0].id
    ExternalloadBalancerInboundNatRulesId: elb.outputs.inboundNatRules[0].id
  }
}

// OPNsense bootstrap is performed post-deployment via 'az vm run-command invoke' in deploy.azcli.
// Microsoft.OSTCExtensions/CustomScriptForLinux and Microsoft.Azure.Extensions/CustomScript
// both require Python 2 / Linux-native extension handlers that are incompatible with FreeBSD 14.4.
// WAAgent's built-in RunShellScript action (used by az vm run-command invoke) works on FreeBSD
// without any extension installation and is the supported bootstrap path for this image.

// Windows11 Client Resources
module nsgwinvm 'modules/vnet/nsg.bicep' = if (DeployWindows) {
  name: winvmnetworkSecurityGroupName
  params: {
    nsgName: winvmnetworkSecurityGroupName
    securityRules: [
      {
        name: 'RDP'
        properties: {
          priority: 4096
          sourceAddressPrefix: '*'
          protocol: 'Tcp'
          destinationPortRange: '3389'
          access: 'Allow'
          direction: 'Inbound'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Out-Any'
        properties: {
          priority: 4096
          sourceAddressPrefix: '*'
          protocol: '*'
          destinationPortRange: '*'
          access: 'Allow'
          direction: 'Outbound'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

module winvmpublicip 'modules/vnet/publicip.bicep' = if (DeployWindows) {
  name: winvmpublicipName
  params: {
    publicipName: winvmpublicipName
    publicipproperties: {
      publicIPAllocationMethod: 'Static'
    }
    publicipsku: {
      name: PublicIPAddressSku
      tier: 'Regional'
    }
  }
}

resource nsgwinvmexist 'Microsoft.Network/networkSecurityGroups@2023-09-01' existing = {
  name: winvmnetworkSecurityGroupName
}

resource winvmpublicipexist 'Microsoft.Network/publicIPAddresses@2023-09-01' existing = {
  name: winvmpublicipName
}
module winvm 'modules/VM/windows11-vm.bicep' = if (DeployWindows) {
  name: winvmName
  params: {
    nsgId: nsgwinvmexist.id
    publicIPId: winvmpublicipexist.id
    TempPassword: TempPassword
    TempUsername: TempUsername
    trustedSubnetId: trustedSubnet.id
    virtualMachineName: winvmName
    virtualMachineSize: 'Standard_B4ms'
  }
  dependsOn: [
    nsgwinvm
    winvmpublicip
  ]
}

// Outputs — consumed by deploy.azcli to pass correct IPs to az vm run-command (OPNsense bootstrap)
output primaryTrustedIP string = opnSensePrimary.outputs.trustedNicIP
output secondaryTrustedIP string = opnSenseSecondary.outputs.trustedNicIP
output trustedSubnetPrefix string = trustedSubnet.properties.addressPrefix
