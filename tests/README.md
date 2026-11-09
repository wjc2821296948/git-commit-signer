# Test plan

V0.1 is intentionally small and read-only. Before each release, verify on Windows 10/11 with Windows PowerShell 5.1 and PowerShell 7+ where available.

## Manual checks

1. Run `gh auth status` while logged out; `GCS.ps1 scan` must stop without creating a misleading report.
2. Log in with `gh auth login`; `GCS.ps1 doctor` must identify the account.
3. Run `GCS.ps1 scan -ExpectedLogin <different-login>`; it must abort before inventory collection.
4. Run `GCS.ps1 scan`; confirm pagination returns more than one page when the account has more than 100 repositories.
5. Confirm public, private, internal, fork, archived, owned, and collaborator repositories are classified correctly when present.
6. Confirm JSON, CSV, and summary files are written beneath the selected output directory.
7. Confirm no GitHub branches, commits, tags, repository settings, or refs are changed.
8. Confirm no token or private key appears in console output or reports.

## Release gate

Do not mark a release complete until the manual checks above have been run on a Windows machine with an authenticated GitHub CLI session.
