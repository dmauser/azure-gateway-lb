param lbName string
param frontendIPConfigurations array
param backendAddressPools array
param loadBalancingRules array
param inboundNatRules array = []
param outboundRules array = []
param probe array
param skuname string = 'Standard'

resource lb 'Microsoft.Network/loadBalancers@2021-03-01' = {
  name: lbName
  location: resourceGroup().location
  sku: {
    name: skuname
    tier: 'Regional'
  }
  properties:{
    frontendIPConfigurations: frontendIPConfigurations
    backendAddressPools: backendAddressPools
    loadBalancingRules: loadBalancingRules
    probes: probe
    inboundNatRules: inboundNatRules
    outboundRules: outboundRules
  }
}

output backendAddressPools array = lb.properties.backendAddressPools
output frontendIPConfigurations array = lb.properties.frontendIPConfigurations
output inboundNatRules array = lb.properties.inboundNatRules
