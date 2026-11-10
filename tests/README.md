# Test plan

V0.2.1 is a read-only reliability update. Test with Windows PowerShell 5.1 and PowerShell 7+ where available.

## V0.1 regression checks

1. Run `GCS.ps1 doctor`; confirm the expected GitHub CLI account is shown.
2. Run `GCS.ps1 scan -ExpectedLogin <login>`; confirm the inventory and V0.1 report files still work.
3. Run `GCS.ps1 scan -ExpectedLogin <different-login>`; it must abort before inventory collection.
4. Confirm repository pagination works when the account has more than 100 visible repositories.

## V0.2 audit checks

1. Run `GCS.ps1 audit -ExpectedLogin <login>` on an account with multiple repositories and branches.
2. Confirm all branch pages are returned when a repository has more than 100 branches (where practical).
3. Confirm commits are paginated when a branch history exceeds 100 commits.
4. Confirm the same SHA reachable from multiple branches appears once per repository and lists all matching branches.
5. Confirm the audit includes a known Verified commit and a known unsigned commit; inspect the raw GitHub API response for expected `verified` and `reason` values.
6. Confirm `unknown_key`, `invalid`, `unverified_email`, other reasons, and missing verification data map to distinct report categories using representative fixtures or repositories where available.
7. Confirm branch and commit CSVs, commit JSON, errors CSV, and audit summary are written.
8. Simulate or encounter an API permission failure; the error must be recorded and `Complete` must be false.
9. Simulate or encounter GitHub API rate limiting; the scan must stop promptly, save partial reports, and set `Complete=false`.
10. Confirm no GitHub branches, commits, tags, repository settings, or refs are changed.
11. Confirm no token or private key appears in console output or reports.
12. Run the audit with `-Repository owner/name`; only that repository's branches and commits should be included in the reports.
13. Provide a repository name that is not accessible; the command must stop with a clear message before branch or commit scanning.
14. Confirm progress is printed before each API request and after each returned page, including multi-page commit histories.
15. Simulate a slow or hung `gh.exe` request; it must be terminated at `-RequestTimeoutSeconds`, with only the configured number of transient retries.
16. Confirm API rate-limit and permission failures are not retried indefinitely and are recorded as errors.
17. Press Ctrl+C during branch listing and during commit pagination; the native Windows console-control handler must signal the PowerShell loop, GCS should stop the active `gh.exe`, write reports for completed work, record `Cancelled=true`, and set `Complete=false`.
18. Confirm a cancelled/incomplete report is never described as a complete full-account audit.

## Release gate

Do not mark V0.2 stable until the audit has been run on Windows PowerShell 5.1 and PowerShell 7+ where available, including a filtered single-repository run, multiple branches, histories spanning more than one API page, timeout/retry behavior, and Ctrl+C cancellation. Review the error report and verify counts against GitHub for a small sample.
