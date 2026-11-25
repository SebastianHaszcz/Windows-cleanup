# Windows-cleanup
Script for Marcin Przezdziek

Cleans temporary files on a list of remote Windows servers through PowerShell Remoting (WinRM) and records free space on `C:` before and after cleanup.

## What it does on each server

1. Measures free space on `C:`.
2. Stops the `wuauserv` service (Windows Update).
3. Deletes the contents of:
   - `C:\temp`, `C:\Windows\Temp`, `C:\Windows\Installer\$PatchCache`
   - `C:\inetpub\logs\LogFiles`
   - `C:\Windows\SoftwareDistribution`
   - every user profile's `Temporary Internet Files`, `History`, and `INetCookies`
   - `C:\Program Files\BMC Software\BladeLogic\RSCD\Transactions`, except items matching `*shavlik*`, `*analysis_archive*`, `*events*`, `*Database*`, `*locks*`, and `*log*`
4. Starts `wuauserv` again.
5. Measures free space on `C:` again.

Servers are processed sequentially. A server that does not answer ping is skipped.

## Requirements

- Run the script from a stepping stone (jump) server with Windows PowerShell 5.1.
- The account running the script must have local administrator rights on every target server.
- WinRM / PowerShell Remoting must be enabled on the target servers, and ICMP ping must be allowed.
- This folder structure must exist on the stepping stone server:

C:\Scripts\
├── cleanup.ps1
├── ServersList.txt   (default server list)
└── Logs\             (created automatically if missing)

## Server list format

Plain text file with one server name per line: hostname, FQDN, or IP address. Empty lines are ignored.

SRV-APP01
SRV-DB02.domain.local
10.20.30.40

Do not add comments, headers, separators, or leading/trailing spaces. Every non-empty line is treated as a server name.

## How to run

PowerShell, using the default list `C:\Scripts\ServersList.txt`:

cd C:\Scripts

.\cleanup.ps1

PowerShell, using another server list:

.\cleanup.ps1 -ServerListPath "C:\Scripts\Batch2.txt"

From `cmd.exe`:

powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\cleanup.ps1"

powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\cleanup.ps1" -ServerListPath "C:\Scripts\Batch2.txt"

`-ExecutionPolicy Bypass` applies only to that single process. If the server list file does not exist, the script stops with exit code `1` and does not contact any server.

Console shows the status of each server. When script finishes, check the CSV summary in `C:\Scripts\Logs`.

## Diagnostics

Logs are saved in `C:\Scripts\Logs` by default:

- `CleanupSummary_<timestamp>.csv`: per-server status, disk measurements, `ErrorStage`, and `ErrorMessage`.
- `CleanupDetailed_<timestamp>.log`: timestamped steps, raw disk sizes, service wait warnings, and error messages with error IDs, targets, source positions, and stack traces where available. File operations report error counts and the first 10 errors per operation.

`Unknown` means the disk measurement was not obtained. Check `ErrorStage` and `ErrorMessage` in the CSV, then the matching server section in the detailed log. A failed final measurement preserves the initial measurement. The console displays the actual status instead of always displaying `OK`.

`Completed with warnings` means processing reached the end but some operations reported errors, such as inaccessible paths or locked files. It does not mean every file was deleted.

Remote step logs are buffered until the remote script returns; they are not live logs. An interrupted WinRM connection can lose those buffered entries, but the local log records the remoting error. Service wait warnings are captured, but no service-stop timeout is added.

## Safe Regression Tests

Run from the repository root:

& .\tests\cleanup.Logging.Tests.ps1

The tests extract the cleanup block and main loop without executing the full script. Disk queries, service commands, deletion, connections, and log writes are mocked. No server is contacted and no cleanup is performed.
