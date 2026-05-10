#!/bin/bash
export PATH=".az-shim:$PATH"
export SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA7G9wsRLr8EiA1dzpJhOvPQ1tt9aU6RGqibqEZ5K23g azure-gateway-lb-20260509'
export LOCATION='westus3'
export RG_CONSUMER='rg-glb-consumer-quorra'
export RG_PROVIDER='rg-glb-provider-quorra'
export ADMIN_USERNAME='azureuser'
export BASTION_DEPLOY='false'
export SUBSCRIPTION_ID='36ead89c-e817-4abc-ae66-5d29d23995bb'
bash ./deploy.azcli 2>&1 | /usr/bin/tee deploy-round6.log