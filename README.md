# Windows-cleanup

Cleans temporary files on a list of remote Windows servers through PowerShell Remoting (WinRM) and records free space on `C:` before and after cleanup.

## What it does on each server

1. Measures free space on `C:`.
2. Stops the `wuauserv` service (Windows Update).
3. Deletes the contents of:
   - `C:\temp`, `C:\Windows\Temp`, `C:\Windows\Installer\$PatchCache`
   - `C:\inetpub\logs\LogFiles`
   - `C:\Windows\SoftwareDistribution` (this also clears the local Windows Update history)
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

```text
C:\Scripts\
├── cleanup.ps1
├── ServersList.txt   (default server list)
└── Logs\             (created automatically if missing)
```

## Server list format

Plain text file with one server name per line: hostname, FQDN, or IP address. Empty lines are ignored.

```text
SRV-APP01
SRV-DB02.domain.local
10.20.30.40
```

Do not add comments, headers, separators, or leading/trailing spaces. Every non-empty line is treated as a server name.

## How to run

PowerShell, using the default list `C:\Scripts\ServersList.txt`:

```powershell
cd C:\Scripts
.\cleanup.ps1
```

PowerShell, using another server list:

```powershell
.\cleanup.ps1 -ServerListPath "C:\Scripts\Batch2.txt"
```

From `cmd.exe`:

```bat
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\cleanup.ps1"
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\cleanup.ps1" -ServerListPath "C:\Scripts\Batch2.txt"
```

`-ExecutionPolicy Bypass` applies only to that single process. If the server list file does not exist, the script stops with exit code `1` and does not contact any server.

## Logs and statuses

Each run creates two files in `C:\Scripts\Logs`:

- `CleanupSummary_<timestamp>.csv`: one row per server with status, free space before/after, `ErrorStage`, and `ErrorMessage`.
- `CleanupDetailed_<timestamp>.log`: timestamped steps and full error details for each server.

| Status | Meaning |
| --- | --- |
| `OK` | Cleanup finished without errors. |
| `Completed with warnings` | Cleanup finished, but some paths could not be read or deleted (for example, locked files). See the detailed log. |
| `Script Error` | Cleanup stopped at the stage shown in `ErrorStage`. |
| `WinRM / Access Error` | The server answers ping, but the remote connection failed (WinRM disabled or no admin rights). |
| `Offline (Ping failed)` | No ping response; the server was skipped. |

`Unknown` in the space columns means the measurement was not obtained. Remote steps appear in the detailed log only after that server finishes.

## Tests (for script maintainers)

```powershell
& .\tests\cleanup.Logging.Tests.ps1
```

All commands are mocked, so the tests contact no servers and delete nothing.
