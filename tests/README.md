# Test plan

V0.2 is a read-only integration feature. Test with Windows PowerShell 5.1 and PowerShell 7+ where available.

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

## Release gate

Do not mark V0.2 stable until the audit has been run on Windows PowerShell 5.1 and PowerShell 7+ where available, including repositories with multiple branches and histories spanning more than one API page. Review the error report and verify counts against GitHub for a small sample.
