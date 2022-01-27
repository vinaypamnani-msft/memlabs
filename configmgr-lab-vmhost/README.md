# Create a Hyper-V Host Virtual Machine in Azure to host lab virtual machines

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json)
[![Deploy To Azure US Gov](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazuregov.svg?sanitize=true)](https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg?sanitize=true)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json)

<!-- Template URL for develop branch: https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fdevelop%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json -->

This template allows you to create a Windows Virtual Machine from a specified image during the template deployment. This template also deploys a Virtual Network, Public IP addresses, a Network Interface and a Network Security Group.

Following extensions are also installed:

- AADLoginForWindows
- ConfigurationforWindows
- AdminCenter
- DSC Extension to install Hyper-V
- DSC Extension which runs a script to:
  - Initialize data disks and create a Storage Pool
  - Configure Hyper-V switch.
  - Install and configure NAT on Routing and Remote Access
  - Download files required for building VM's.
