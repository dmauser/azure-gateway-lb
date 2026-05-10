param nsgName string
param securityRules array = []
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: nsgName
  location: resourceGroup().location
  properties: {
    securityRules: securityRules
  }
}
output nsgID string = nsg.id
