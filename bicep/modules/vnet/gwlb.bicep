param lbName string
param frontendIPConfigurations array
param backendAddressPools array
param loadBalancingRules array
param outboundRules array = []
param probe array

resource lb 'Microsoft.Network/loadBalancers@2021-03-01' = {
  name: lbName
  location: resourceGroup().location
  sku: {
    name: 'Gateway'
    tier: 'Regional'
  }
  properties:{
    frontendIPConfigurations: frontendIPConfigurations
    backendAddressPools: backendAddressPools
    loadBalancingRules: loadBalancingRules
    probes: probe
    outboundRules: outboundRules
  }
}

output backendAddressPools array = lb.properties.backendAddressPools
output frontendIPConfigurations array = lb.properties
