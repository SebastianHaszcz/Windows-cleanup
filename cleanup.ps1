param(
    # Text file with one server name per line
    [string]$ServerListPath = "C:\Scripts\ServersList.txt"
)

# --- 1. Path Configuration ---
# Where to save the logs
$LogDirectory   = "C:\Scripts\Logs"

if (-not (Test-Path -Path $ServerListPath -PathType Leaf)) {
    Write-Host "Server list not found: $ServerListPath" -ForegroundColor Red
    exit 1
}

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
    $LogEntries = New-Object 'System.Collections.Generic.List[string]'
    $Issues = New-Object 'System.Collections.Generic.List[string]'
    $SpaceBefore = "Unknown"
    $SpaceAfter = "Unknown"
    $Stage = "Initialization"
    
    # Helper function to add a timestamp to every log entry
    function Add-Log ($Message) {
        $LogEntries.Add("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message")
    }

    function Get-ErrorDetail ($Record) {
        "Message=$($Record.Exception.Message); Type=$($Record.Exception.GetType().FullName); ErrorId=$($Record.FullyQualifiedErrorId); Category=$($Record.CategoryInfo); Target=$($Record.TargetObject); Position=$($Record.InvocationInfo.PositionMessage); Stack=$($Record.ScriptStackTrace)"
    }

    function Add-OperationErrors ($Operation, $Records) {
        if (@($Records).Count -gt 0) {
            $Message = "${Operation}: $(@($Records).Count) error(s)."
            $Issues.Add($Message)
            Add-Log "WARNING: $Message First 10 errors follow."
            foreach ($Record in ($Records | Select-Object -First 10)) {
                Add-Log (Get-ErrorDetail $Record)
            }
        }
    }

    try {
        Add-Log "Cleanup process started."

        # Check free disk space BEFORE cleanup
        $Stage = "Measure free space BEFORE"
        $DiskBefore = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($null -eq $DiskBefore -or $null -eq $DiskBefore.FreeSpace -or $DiskBefore.Size -le 0) {
            throw "Invalid disk data for C: (Size='$($DiskBefore.Size)', FreeSpace='$($DiskBefore.FreeSpace)')."
        }
        $SpaceBefore = "{0:P2}" -f ($DiskBefore.FreeSpace / $DiskBefore.Size)
        Add-Log "Free space BEFORE: $SpaceBefore (FreeBytes=$($DiskBefore.FreeSpace); SizeBytes=$($DiskBefore.Size))"

        # Stop the Windows Update service safely
        $Stage = "Stop Windows Update service"
        Add-Log "Attempting to stop Windows Update service (wuauserv)..."
        $ServiceErrors = @()
        $ServiceWarnings = @()
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue -ErrorVariable ServiceErrors -WarningVariable ServiceWarnings
        Add-OperationErrors $Stage $ServiceErrors
        foreach ($WarningRecord in $ServiceWarnings) { Add-Log "WARNING: $WarningRecord" }
        Add-Log "Windows Update stop command finished."

        # List of safe paths to clean up
        $TempPaths = @(
            "C:\temp\*",
            "C:\Windows\Temp\*",
            'C:\Windows\Installer\$PatchCache\*',
            "C:\inetpub\logs\LogFiles\*",
            "C:\Users\*\AppData\Local\Microsoft\Windows\Temporary Internet Files\*",
            "C:\Users\*\AppData\Local\Microsoft\Windows\History\*",
            "C:\Users\*\AppData\Local\Microsoft\Windows\INetCookies\*",
            "C:\Windows\SoftwareDistribution\*"
        )

        # Loop through each path and delete files
        foreach ($Path in $TempPaths) {
            $Stage = "Clean path: $Path"
            Add-Log "Cleaning path: $Path"
            $ReadErrors = @()
            $DeleteErrors = @()
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable ReadErrors |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable DeleteErrors
            Add-OperationErrors "List $Path" $ReadErrors
            Add-OperationErrors "Delete $Path" $DeleteErrors
            Add-Log "Finished path: $Path"
        }

        # Clean up BMC BladeLogic cache, but keep important database/log files
        $Stage = "Clean BMC BladeLogic cache"
        Add-Log "Cleaning BMC BladeLogic cache..."
        $BMCPath = "C:\Program Files\BMC Software\BladeLogic\RSCD\Transactions\*"
        $BMCExcludes = @("*shavlik*", "*analysis_archive*", "*events*", "*Database*", "*locks*", "*log*")
        
        $ReadErrors = @()
        $DeleteErrors = @()
        Get-ChildItem -Path $BMCPath -Exclude $BMCExcludes -ErrorAction SilentlyContinue -ErrorVariable ReadErrors |
            Remove-Item -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable DeleteErrors
        Add-OperationErrors "List $BMCPath" $ReadErrors
        Add-OperationErrors "Delete $BMCPath" $DeleteErrors

        # Restart the Windows Update service
        $Stage = "Start Windows Update service"
        Add-Log "Restarting Windows Update service (wuauserv)..."
        $ServiceErrors = @()
        $ServiceWarnings = @()
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue -ErrorVariable ServiceErrors -WarningVariable ServiceWarnings
        Add-OperationErrors $Stage $ServiceErrors
        foreach ($WarningRecord in $ServiceWarnings) { Add-Log "WARNING: $WarningRecord" }
        Add-Log "Windows Update start command finished."

        # Check free disk space AFTER cleanup
        $Stage = "Measure free space AFTER"
        $DiskAfter = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        if ($null -eq $DiskAfter -or $null -eq $DiskAfter.FreeSpace -or $DiskAfter.Size -le 0) {
            throw "Invalid disk data for C: (Size='$($DiskAfter.Size)', FreeSpace='$($DiskAfter.FreeSpace)')."
        }
        $SpaceAfter = "{0:P2}" -f ($DiskAfter.FreeSpace / $DiskAfter.Size)
        Add-Log "Free space AFTER: $SpaceAfter (FreeBytes=$($DiskAfter.FreeSpace); SizeBytes=$($DiskAfter.Size))"
        $Status = if ($Issues.Count -gt 0) { "Completed with warnings" } else { "OK" }
        Add-Log "Completed. Status: $Status"

        # Send this structured data back to the stepping stone server
        [PSCustomObject]@{
            ServerName  = $ServerName
            Status      = $Status
            SpaceBefore = $SpaceBefore
            SpaceAfter  = $SpaceAfter
            ErrorStage  = ""
            ErrorMessage = ($Issues -join " | ")
            Details     = ($LogEntries -join "`r`n")
        }
    }
    catch {
        # Catch unexpected critical errors
        $Failure = $_
        Add-Log "CRITICAL EXECUTION ERROR at stage '$Stage': $(Get-ErrorDetail $Failure)"
        [PSCustomObject]@{
            ServerName  = $ServerName
            Status      = "Script Error"
            SpaceBefore = $SpaceBefore
            SpaceAfter  = $SpaceAfter
            ErrorStage  = $Stage
            ErrorMessage = $Failure.Exception.Message
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
        $Result = $null
        $RemoteError = "No cleanup result returned."
        try {
            $Result = Invoke-Command -ComputerName $Server -ScriptBlock $CleanupScriptBlock -ErrorAction Stop
        }
        catch {
            $RemoteError = $_.Exception.Message
            Add-Content -Path $DetailedLogPath -Value "REMOTING ERROR: $($_ | Format-List * -Force | Out-String)"
        }
        
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
                ErrorStage  = $Result.ErrorStage
                ErrorMessage = $Result.ErrorMessage
            }
            $StatusColor = if ($Result.Status -eq "OK") { "Green" } elseif ($Result.Status -eq "Script Error") { "Red" } else { "Yellow" }
            Write-Host " -> $($Result.Status). Space after: $($Result.SpaceAfter)" -ForegroundColor $StatusColor
            if ($Result.ErrorMessage) {
                Write-Host "    Stage: $($Result.ErrorStage); Details: $($Result.ErrorMessage)" -ForegroundColor $StatusColor
            }
        } else {
            # Ping worked, but PowerShell Remoting (WinRM) failed or access was denied
            $SummaryReport += [PSCustomObject]@{ ServerName = $Server; Status = "WinRM / Access Error"; SpaceBefore = "-"; SpaceAfter = "-"; ErrorStage = "Remoting"; ErrorMessage = $RemoteError }
            Add-Content -Path $DetailedLogPath -Value "ERROR: $RemoteError`n"
            Write-Host " -> Access denied / WinRM error." -ForegroundColor Red
        }

    } else {
        # Server is completely offline or blocking ICMP ping
        $SummaryReport += [PSCustomObject]@{ ServerName = $Server; Status = "Offline (Ping failed)"; SpaceBefore = "-"; SpaceAfter = "-"; ErrorStage = "Ping"; ErrorMessage = "No ICMP response; server may be offline or blocking ping." }
        Add-Content -Path $DetailedLogPath -Value "ERROR: Server did not respond to PING. Skipped.`n"
        Write-Host " -> Offline (skipped)." -ForegroundColor DarkGray
    }
}

# --- 4. Finalizing and Reporting ---
# Export the summary array to a clean Excel-friendly CSV file
$SummaryReport | Export-Csv -Path $SummaryCsvPath -NoTypeInformation -Encoding UTF8

Write-Host "--------------------------------------------------"
Write-Host "Done! Two logs have been saved in $LogDirectory" -ForegroundColor Cyan
