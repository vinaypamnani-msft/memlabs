#Cleanup-SQL.ps1

# Get the installed SQL Server instances
$instances = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"

# Loop through each instance and get the installation path
foreach ($instance in $instances.PSObject.Properties) {
    if ($instance.Name -ne "PSPath" -and $instance.Name -ne "PSParentPath" -and $instance.Name -ne "PSChildName" -and $instance.Name -ne "PSDrive" -and $instance.Name -ne "PSProvider") {
        $instanceName = $instance.Value
        $instanceKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceName\Setup"
        
        if (Test-Path $instanceKey) {
            $installPath = (Get-ItemProperty -Path $instanceKey).SQLPath
            $TargetDir = $installPath + "\Log"
            Write-Output "Instance: $instanceName, Path: $installPath, $TargetDir"
            if (Test-Path $TargetDir) {
                # Get the current date
                $CutoffDate = (Get-Date).AddDays(-7)
 
                # Get all files in the directory
                $AllFiles = Get-ChildItem -Path $TargetDir -File
 
                # Filter files with specific extensions and older than 7 days
                $OldFiles = $AllFiles | Where-Object {
                    $_.LastWriteTime -lt $CutoffDate -and $_.Extension -in ".txt", ".mdmp", ".xel"
                }
 
                # Delete the old files
                foreach ($File in $OldFiles) {
                    try {
                        Remove-Item -Path $File.FullName -Force
                        Write-Output "Deleted: $($File.FullName)"
                    }
                    catch {
                        Write-Warning "Failed to delete $($File.FullName): $_"
                    }
                }
            }
            else {
                Write-Warning "Target directory does not exist: $TargetDir"
            }

        }         
    }
}


