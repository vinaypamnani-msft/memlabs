# Create a Hyper-V Host Virtual Machine in Azure to host lab virtual machines

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2FcreateUiDefinition.json)
[![Deploy To Azure US Gov](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazuregov.svg?sanitize=true)](https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg?sanitize=true)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json)

The Deploy buttons use [createUiDefinition.json](createUiDefinition.json), which filters the VM size list to sizes actually offered in the region you pick. To deploy without the custom form (raw parameter list), use the [plain template URL](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fmain%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json).

Preview form changes without deploying in the [CreateUiDefinition sandbox](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/SandboxBlade).

<!-- Template URL for develop branch: https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fvinaypamnani-msft%2Fmemlabs%2Fdevelop%2Fconfigmgr-lab-vmhost%2Fazuredeploy.json -->

This template allows you to create a Windows Virtual Machine from a specified image during the template deployment. This template also deploys a Virtual Network, Public IP addresses, a Network Interface and a Network Security Group.

Following extensions are also installed:

- ConfigurationforWindows (Azure Policy guest configuration)
- CustomScript extension, which:
  - Installs the Hyper-V and DHCP roles
  - Optionally moves the guest RDP listener to a custom port
  - Registers a startup task that runs `configureHost.ps1` after the reboot, to:
    - Initialize data disks and create a Storage Pool
    - Format the E: VM-storage volume as NTFS or ReFS
    - Install chocolatey, git, sysinternals and curl
    - Clone the memlabs repository to E:

## Parameters worth noting

| Parameter | Notes |
| --- | --- |
| `vmSize` | Curated list, all 16 vCPU (E = 128 GB RAM, D = 64 GB). `a` = AMD, `d` = local temp disk, `s` = Premium SSD capable. The no-temp-disk sizes cost less and provisioning never uses the temp disk, but Windows then places the pagefile on the 128 GB OS disk. Every entry supports nested virtualization, Gen2, and at least the 24 data disks the template attaches; 8-vCPU sizes cap at 16 data disks and are excluded because they cannot deploy. AMD v6/v7 sizes require an NVMe-capable OS image. A `SkuNotAvailable` error means the size isn't offered in that region; pick another. |
| `rdpPort` | Changes the RDP listener **inside the guest** only. The NSG `AllowCorpnet` rule already permits every port from CorpNetPublic, so no NSG rule is added. Applied before the provisioning reboot; check `%windir%\temp\configureHost.log` if RDP does not answer on the new port. |
| `hostVolumeFileSystem` | ReFS block-clones base-image copies on Server 2025, making VM creation near-instant at no extra space cost. Do **not** enable Data Deduplication on a ReFS volume. |

Outputs include `publicIpAddress` and `rdpConnection` (`<ip>:<port>`).
