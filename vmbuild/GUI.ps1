
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Used when calling from New-Lab")]
    [Switch] $InternalUseOnly
)

$return = [PSCustomObject]@{
    ConfigFileName = $null
    DeployNow      = $false
}

# Set Debug & Verbose
$enableVerbose = if ($PSBoundParameters.Verbose -eq $true) { $true } else { $false };
$enableDebug = if ($PSBoundParameters.Debug -eq $true) { $true } else { $false };
$DebugPreference = "SilentlyContinue"
if (-not $InternalUseOnly.IsPresent) {
    if ($Common.Initialized) {
        $Common.Initialized = $false
    }

    # Dot source common
    . $PSScriptRoot\Common.ps1 -VerboseEnabled:$enableVerbose

    Write-Host2 -ForegroundColor Cyan ""
}

$configDir = Join-Path $PSScriptRoot "config"


# Load Windows Forms assembly
Add-Type -AssemblyName System.Windows.Forms

# Create the form
$form = New-Object system.Windows.Forms.Form
$form.Text = "New-Lab Configuration Generator"
$form.Size = New-Object System.Drawing.Size(600, 600)
$form.StartPosition = "CenterScreen"

# Create a label for the title
$titleLabel = New-Object system.Windows.Forms.Label
$titleLabel.Text = "New-Lab Configuration Generator"
$titleLabel.AutoSize = $true
$titleLabel.Font = New-Object System.Drawing.Font("Arial", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(100, 20)
$form.Controls.Add($titleLabel)

# Create the buttons for each option
$buttonSize = New-Object System.Drawing.Size(500, 40)
$buttonFont = New-Object System.Drawing.Font("Arial", 12)

# Create New Domain
$btnCreateNewDomain = New-Object system.Windows.Forms.Button
$btnCreateNewDomain.Text = "Create New Domain"
$btnCreateNewDomain.Size = $buttonSize
$btnCreateNewDomain.Font = $buttonFont
$btnCreateNewDomain.Location = New-Object System.Drawing.Point(50, 80)
$btnCreateNewDomain.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("Create New Domain selected.")
    # Add code to handle "Create New Domain" action
    
})
$form.Controls.Add($btnCreateNewDomain)

# Expand Existing Domain
$btnExpandExistingDomain = New-Object system.Windows.Forms.Button
$btnExpandExistingDomain.Text = "Expand Existing Domain [3 existing domain(s)]"
$btnExpandExistingDomain.Size = $buttonSize
$btnExpandExistingDomain.Font = $buttonFont
$btnExpandExistingDomain.Location = New-Object System.Drawing.Point(50, 130)
$btnExpandExistingDomain.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("Expand Existing Domain selected.")
    # Add code to handle "Expand Existing Domain" action
})
$form.Controls.Add($btnExpandExistingDomain)

# Load Config
$btnLoadConfig = New-Object system.Windows.Forms.Button
$btnLoadConfig.Text = "Load saved config from File"
$btnLoadConfig.Size = $buttonSize
$btnLoadConfig.Font = $buttonFont
$btnLoadConfig.Location = New-Object System.Drawing.Point(50, 180)
$btnLoadConfig.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("Load Config selected.")
    # Add code to handle "Load Config" action
})
$form.Controls.Add($btnLoadConfig)

# Manage Lab
$btnManageLab = New-Object system.Windows.Forms.Button
$btnManageLab.Text = "Manage Lab [Mem Free: 67GB/128GB] [E: Free 1032GB/3048GB] [VMs Running: 10/31]"
$btnManageLab.Size = $buttonSize
$btnManageLab.Font = $buttonFont
$btnManageLab.Location = New-Object System.Drawing.Point(50, 230)
$btnManageLab.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("Manage Lab selected.")
    # Add code to handle "Manage Lab" action
})
$form.Controls.Add($btnManageLab)

# Regenerate Rdcman file
$btnRegenerateRdcman = New-Object system.Windows.Forms.Button
$btnRegenerateRdcman.Text = "Regenerate Rdcman file (memlabs.rdg) from Hyper-V config"
$btnRegenerateRdcman.Size = $buttonSize
$btnRegenerateRdcman.Font = $buttonFont
$btnRegenerateRdcman.Location = New-Object System.Drawing.Point(50, 280)
$btnRegenerateRdcman.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("Regenerate Rdcman file selected.")
    # Add code to handle "Regenerate Rdcman file" action
})
$form.Controls.Add($btnRegenerateRdcman)

# Update or Copy Optional Tools with a dropdown (ComboBox)
$lblToolSelect = New-Object system.Windows.Forms.Label
$lblToolSelect.Text = "Select a Tool to Install:"
$lblToolSelect.Size = New-Object System.Drawing.Size(200, 20)
$lblToolSelect.Font = New-Object System.Drawing.Font("Arial", 10)
$lblToolSelect.Location = New-Object System.Drawing.Point(50, 380)
$form.Controls.Add($lblToolSelect)

$cbTools = New-Object system.Windows.Forms.ComboBox
$cbTools.Size = $buttonSize
$cbTools.Font = $buttonFont
$cbTools.Location = New-Object System.Drawing.Point(50, 410)
$toolList = Get-ToolList
$cbTools.Items.AddRange($toolList)
$form.Controls.Add($cbTools)

$btnUpdateTools = New-Object system.Windows.Forms.Button
$btnUpdateTools.Text = "Install Selected Tool"
$btnUpdateTools.Size = $buttonSize
$btnUpdateTools.Font = $buttonFont
$btnUpdateTools.Location = New-Object System.Drawing.Point(50, 460)
$btnUpdateTools.Add_Click({
    $selectedTool = $cbTools.SelectedItem
    if ($selectedTool) {
        [System.Windows.Forms.MessageBox]::Show("Installing $selectedTool...")
        # Add code to handle installation of the selected tool
    } else {
        [System.Windows.Forms.MessageBox]::Show("Please select a tool to install.")
    }
})
$form.Controls.Add($btnUpdateTools)

# Manage Domains
$btnManageDomains = New-Object system.Windows.Forms.Button
$btnManageDomains.Text = "Manage Domains [Start/Stop/Snapshot/Delete]"
$btnManageDomains.Size = $buttonSize
$btnManageDomains.Font = $buttonFont
$btnManageDomains.Location = New-Object System.Drawing.Point(50, 380)
$btnManageDomains.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("Manage Domains selected.")
    # Add code to handle "Manage Domains" action

})
$form.Controls.Add($btnManageDomains)

# Show the form
$form.ShowDialog()
