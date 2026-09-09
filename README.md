# Windows-cleanup
Script for Marcin Przezdziek

## Diagnostics

Logs are saved in `C:\Scripts\Logs` by default:

- `CleanupSummary_<timestamp>.csv`: per-server status, disk measurements, `ErrorStage`, and `ErrorMessage`.
- `CleanupDetailed_<timestamp>.log`: timestamped steps, raw disk sizes, service wait warnings, and error messages with error IDs, targets, source positions, and stack traces where available. File operations report error counts and the first 10 errors per operation.

`Unknown` means the disk measurement was not obtained. Check `ErrorStage` and `ErrorMessage` in the CSV, then the matching server section in the detailed log. A failed final measurement preserves the initial measurement. The console displays the actual status instead of always displaying `OK`.

`Completed with warnings` means processing reached the end but some operations reported errors, such as inaccessible paths or locked files. It does not mean every file was deleted.

Remote step logs are buffered until the remote script returns; they are not live logs. An interrupted WinRM connection can lose those buffered entries, but the local log records the remoting error. Service wait warnings are captured, but no service-stop timeout is added.

## Safe Regression Tests

Run from the repository root:

```powershell
& .\tests\cleanup.Logging.Tests.ps1
```

The tests extract the cleanup block and main loop without executing the full script. Disk queries, service commands, deletion, connections, and log writes are mocked. No server is contacted and no cleanup is performed.
