# --- 1. Path Configuration ---
# Where to find the list of servers and where to save the logs
$ServerListPath = "C:\Scripts\ServersList.txt"
$LogDirectory   = "C:\Scripts\Logs"

# Create the logs folder if it doesn't exist yet
if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

# Generate a timestamp for unique log file names (e.g., 20231025_1430)
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmm'
$SummaryCsvPath = "$LogDirectory\CleanupSummary_$Timestamp.csv"
$DetailedLogPath = "$LogDirectory\CleanupDetailed_$Timestamp.log"

# Read the server list and ignore any empty lines
$Servers = Get-Content -Path $ServerListPath | Where-Object { $_.Trim() -ne '' }
$SummaryReport = @() # This array will hold the data for final Excel/CSV report

Write-Host "Starting ultra-safe cleanup of $($Servers.Count) servers..." -ForegroundColor Cyan
Write-Host "Summary log (CSV): $SummaryCsvPath" -ForegroundColor Gray
Write-Host "Detailed log (TXT): $DetailedLogPath" -ForegroundColor Gray
Write-Host "--------------------------------------------------"

# --- 2. The Cleanup Logic (Runs LOCALLY on each remote server) ---
$CleanupScriptBlock = {
    $ServerName = $env:COMPUTERNAME
    $LogEntries = @() # Stores detailed steps for the text log
    
    # Helper function to add a timestamp to every log entry
    function Add-Log ($Message) {
        $LogEntries += "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    }

    try {
        Add-Log "Cleanup process started."

        # Check free disk space BEFORE cleanup
        $DiskBefore = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'"
        $SpaceBefore = "{0:P2}" -f ($DiskBefore.FreeSpace / $DiskBefore.Size)
        Add-Log "Free space BEFORE: $SpaceBefore"

        # Stop the Windows Update service safely
        Add-Log "Attempting to stop Windows Update service (wuauserv)..."
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue

        # List of safe paths to clean up
        $TempPaths = @(
            "C:\temp\*",
            "C:\Windows\Temp\*",
            "C:\Windows\Installer\$PatchCache\*",
            "C:\inetpub\logs\LogFiles\*",
            "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*",
            "C:\Users\*\AppData\Local\Microsoft\Windows\History\*",
            "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\*",
            "C:\Windows\SoftwareDistribution\*"
        )

        # Loop through each path and delete files (skips locked/in-use files silently)
        foreach ($Path in $TempPaths) {
            Add-Log "Cleaning path: $Path"
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | 
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Clean up BMC BladeLogic cache, but keep important database/log files
        Add-Log "Cleaning BMC BladeLogic cache..."
        $BMCPath = "C:\Program Files\BMC Software\BladeLogic\RSCD\Transactions\*"
        $BMCExcludes = @("*shavlik*", "*analysis_archive*", "*events*", "*Database*", "*locks*", "*log*")
        
        Get-ChildItem -Path $BMCPath -Exclude $BMCExcludes -ErrorAction SilentlyContinue | 
            Remove-Item -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue

        # Restart the Windows Update service
        Add-Log "Restarting Windows Update service (wuauserv)..."
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue

        # Check free disk space AFTER cleanup
        $DiskAfter = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'"
        $SpaceAfter = "{0:P2}" -f ($DiskAfter.FreeSpace / $DiskAfter.Size)
        Add-Log "Free space AFTER: $SpaceAfter"
        Add-Log "Completed successfully."

        # Send this structured data back to the stepping stone server
        [PSCustomObject]@{
            ServerName  = $ServerName
            Status      = "OK"
            SpaceBefore = $SpaceBefore
            SpaceAfter  = $SpaceAfter
            Details     = ($LogEntries -join "`r`n")
        }
    }
    catch {
        # Catch unexpected critical errors
        Add-Log "CRITICAL EXECUTION ERROR: $($_.Exception.Message)"
        [PSCustomObject]@{
            ServerName  = $ServerName
            Status      = "Script Error"
            SpaceBefore = "Unknown"
            SpaceAfter  = "Unknown"
            Details     = ($LogEntries -join "`r`n")
        }
    }
}

# --- 3. The Main Execution Loop ---
# Process each server from the text file one by one
foreach ($Server in $Servers) {
    Write-Host "Processing server: $Server" -ForegroundColor Yellow -NoNewline
    
    # Add a visual separator for this server in the detailed TXT log
    Add-Content -Path $DetailedLogPath -Value "========================================="
    Add-Content -Path $DetailedLogPath -Value "SERVER: $Server | START: $(Get-Date)"
    Add-Content -Path $DetailedLogPath -Value "========================================="

    # Check if the server is online (Ping) to avoid long network timeouts
    if (Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        
        # Server is online -> Run the cleanup script block
        $Result = Invoke-Command -ComputerName $Server -ScriptBlock $CleanupScriptBlock -ErrorAction SilentlyContinue
        
        if ($Result) {
            # Connection successful, save detailed steps to TXT
            Add-Content -Path $DetailedLogPath -Value $Result.Details
            Add-Content -Path $DetailedLogPath -Value "`n"

            # Add short info to the CSV summary array
            $SummaryReport += [PSCustomObject]@{
                ServerName  = $Result.ServerName
                Status      = $Result.Status
                SpaceBefore = $Result.SpaceBefore
                SpaceAfter  = $Result.SpaceAfter
            }
            Write-Host " -> OK. Space after: $($Result.SpaceAfter)" -ForegroundColor Green
        } else {
            # Ping worked, but PowerShell Remoting (WinRM) failed or access was denied
            $SummaryReport += [PSCustomObject]@{ ServerName = $Server; Status = "WinRM / Access Error"; SpaceBefore = "-"; SpaceAfter = "-" }
            Add-Content -Path $DetailedLogPath -Value "ERROR: Cannot access via WinRM (service disabled, blocked by firewall, or access denied).`n"
            Write-Host " -> Access denied / WinRM error." -ForegroundColor Red
        }

    } else {
        # Server is completely offline or blocking ICMP ping
        $SummaryReport += [PSCustomObject]@{ ServerName = $Server; Status = "Offline (Ping failed)"; SpaceBefore = "-"; SpaceAfter = "-" }
        Add-Content -Path $DetailedLogPath -Value "ERROR: Server did not respond to PING. Skipped.`n"
        Write-Host " -> Offline (skipped)." -ForegroundColor DarkGray
    }
}

# --- 4. Finalizing and Reporting ---
# Export the summary array to a clean Excel-friendly CSV file
$SummaryReport | Export-Csv -Path $SummaryCsvPath -NoTypeInformation -Encoding UTF8

Write-Host "--------------------------------------------------"
Write-Host "Done! Two logs have been saved in $LogDirectory" -ForegroundColor Cyan
