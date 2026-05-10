param virtualMachineName string
param OPNScriptURI string
param ShellScriptName string
param ShellScriptParameters string


resource vmext 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  name: '${virtualMachineName}/CustomScript'
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
