& {
    $ParseErrors = $null
    $Tokens = $null
    $ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'cleanup.ps1'
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$ParseErrors)
    if ($ParseErrors.Count) { throw ($ParseErrors | Out-String) }
    $Assignment = $Ast.Find({
        param($Node)
        $Node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $Node.Left.Extent.Text -eq '$CleanupScriptBlock'
    }, $true)
    $Expression = $Assignment.Right.Find({
        param($Node)
        $Node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true)
    $Cleanup = $Expression.ScriptBlock.GetScriptBlock()

    function Assert-Condition ($Condition, $Message) {
        if (-not $Condition) { throw $Message }
    }

    function Get-WmiObject {
        [CmdletBinding()] param($Class, $Filter)
        $State.DiskCalls++
        if ($State.Scenario -eq 'AfterFailure' -and $State.DiskCalls -eq 2) { throw 'Simulated WMI access denied' }
        if ($State.Scenario -eq 'InvalidBefore') { return $null }
        [pscustomobject]@{ FreeSpace = 25; Size = 100 }
    }
    function Stop-Service {
        [CmdletBinding()] param($Name, [switch]$Force)
        Write-Warning 'Simulated service wait'
    }
    function Start-Service { [CmdletBinding()] param($Name) }
    function Get-ChildItem {
        [CmdletBinding()] param($Path, [switch]$Recurse, [switch]$Force, $Exclude)
        $State.SeenPaths.Add($Path)
        if ($State.Scenario -eq 'DeleteFailure') { 'C:\mock\locked.tmp' }
    }
    function Remove-Item {
        [CmdletBinding(SupportsShouldProcess)]
        param([Parameter(ValueFromPipeline)]$Path, [switch]$Recurse, [switch]$Force)
        process { Write-Error -Message 'Simulated locked file' -TargetObject $Path }
    }

    foreach ($ScenarioName in @('Success', 'AfterFailure', 'InvalidBefore', 'DeleteFailure')) {
        $State = @{
            Scenario = $ScenarioName
            DiskCalls = 0
            SeenPaths = New-Object 'System.Collections.Generic.List[string]'
        }
        $Results = @(& $Cleanup 3>$null)
        Assert-Condition ($Results.Count -eq 1) 'Unexpected output count'
        $Result = $Results[0]
        Assert-Condition ($Result.Details -match 'Cleanup process started') 'Log scope regression'
        switch ($ScenarioName) {
            'Success' {
                Assert-Condition ($Result.Status -eq 'OK' -and $Result.Details -match 'Simulated service wait') 'Success/warning log regression'
            }
            'AfterFailure' {
                Assert-Condition ($Result.Status -eq 'Script Error' -and $Result.SpaceBefore -ne 'Unknown' -and $Result.SpaceAfter -eq 'Unknown') 'Disk result regression'
                Assert-Condition ($Result.ErrorStage -eq 'Measure free space AFTER' -and $Result.Details -match 'Simulated WMI access denied') 'Failure detail regression'
                $FailedResult = $Result
            }
            'InvalidBefore' {
                Assert-Condition ($Result.Status -eq 'Script Error' -and $Result.ErrorStage -eq 'Measure free space BEFORE') 'Invalid disk regression'
            }
            'DeleteFailure' {
                Assert-Condition ($Result.Status -eq 'Completed with warnings' -and $Result.Details -match 'Simulated locked file') 'Deletion diagnostic regression'
            }
        }
        if ($ScenarioName -ne 'InvalidBefore') {
            Assert-Condition ($State.SeenPaths.Contains('C:\Windows\Installer\$PatchCache\*')) 'PatchCache path regression'
        }
        Write-Output "PASS: $ScenarioName"
    }

    $LoopAst = $Ast.Find({
        param($Node)
        $Node -is [System.Management.Automation.Language.ForEachStatementAst] -and $Node.Variable.Extent.Text -eq '$Server'
    }, $true)
    $MainLoop = [scriptblock]::Create($LoopAst.Extent.Text)
    function Test-Connection { [CmdletBinding()] param($ComputerName, $Count, [switch]$Quiet) $State.Online }
    function Invoke-Command {
        [CmdletBinding()] param($ComputerName, $ScriptBlock)
        if ($State.RemoteFailure) { throw 'Simulated WinRM access denied' }
        $FailedResult
    }
    function Add-Content { param($Path, $Value) $State.Logs.Add([string]$Value) }
    function Write-Host { param($Object, $ForegroundColor, [switch]$NoNewline) $State.Console.Add([string]$Object) }

    foreach ($ScenarioName in @('ScriptErrorDisplay', 'WinRMFailure', 'Offline')) {
        $State = @{
            Online = $ScenarioName -ne 'Offline'
            RemoteFailure = $ScenarioName -eq 'WinRMFailure'
            Logs = New-Object 'System.Collections.Generic.List[string]'
            Console = New-Object 'System.Collections.Generic.List[string]'
        }
        $Servers = @('mock-server')
        $SummaryReport = @()
        $DetailedLogPath = 'mock-log'
        $CleanupScriptBlock = $Cleanup
        . $MainLoop
        Assert-Condition ($SummaryReport.Count -eq 1) 'Summary result count regression'
        switch ($ScenarioName) {
            'ScriptErrorDisplay' {
                Assert-Condition ($SummaryReport[0].Status -eq 'Script Error') 'Script status regression'
                Assert-Condition (($State.Console -join '') -notmatch ' -> OK\.') 'False OK display regression'
            }
            'WinRMFailure' {
                Assert-Condition ($SummaryReport[0].ErrorMessage -match 'Simulated WinRM access denied') 'Remoting summary regression'
                Assert-Condition (($State.Logs -join '') -match 'Simulated WinRM access denied') 'Remoting detail regression'
            }
            'Offline' {
                Assert-Condition ($SummaryReport[0].ErrorStage -eq 'Ping') 'Ping stage regression'
            }
        }
        Write-Output "PASS: $ScenarioName"
    }
}