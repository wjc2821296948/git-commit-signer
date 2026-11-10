# Git Commit Signer (GCS)

**A Windows-first, read-only GitHub repository and commit-signature auditing tool.**

[简体中文](README.zh-CN.md)

> **Development status: V0.2.1 preview.** The latest stable release is still [v0.1.0](https://github.com/wjc2821296948/git-commit-signer/releases/tag/v0.1.0).
>
> V0.2 adds branch and commit-signature auditing. It reads GitHub's commit verification result and exports reports. It does **not** rewrite commits, change Git refs, update repository settings, or push anything.

## Features

- Discover repositories visible to the authenticated GitHub account, including owned, collaborator, and organization-member repositories.
- Inventory all ordinary branches in each accessible repository.
- Read every commit reachable from each branch, following GitHub API pagination.
- Deduplicate the same commit SHA across branches within each repository, while recording all branches containing it.
- Classify GitHub's commit verification result:
  - `Verified`: GitHub reports `verified=true`.
  - `Unsigned`: GitHub reports `reason=unsigned`.
  - `UnknownKey`: GitHub reports `reason=unknown_key`.
  - `Invalid`: GitHub reports `reason=invalid`.
  - `UnverifiedEmail`: GitHub reports `reason=unverified_email`.
  - `Unverified`: another non-verified reason.
  - `Unavailable`: the API response does not include verification data.
- Export branch, commit, error, and summary reports in CSV/JSON.
- Stop early when GitHub reports API rate limiting and mark the report incomplete.
- Restrict an audit to one repository with `-Repository owner/name`.
- Show progress for every repository, branch, and API page.
- Apply a per-request timeout and bounded retries for transient network/server failures.
- Handle Ctrl+C by stopping the active `gh.exe` request and saving completed results as an incomplete report.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7+
- Git for Windows
- GitHub CLI (`gh`)
- An authenticated GitHub CLI session with read access to the repositories you want to audit

No Python, Node.js, paid API, or additional service is required.

## Setup

1. Install Git for Windows and GitHub CLI if they are not already installed.
2. Authenticate GitHub CLI:

   ```powershell
   gh auth login
   gh auth status
   ```

3. Clone or download this repository.
4. If this PowerShell session blocks local scripts, allow scripts for this window only:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   ```

## Commands

### Repository inventory (V0.1)

Lists repositories visible to the authenticated account:

```powershell
.\GCS.ps1 scan -ExpectedLogin YOUR_GITHUB_LOGIN
```

### Commit-signature audit (V0.2.1 preview)

Audits all accessible repositories, their branches, and the commits reachable from those branches:

```powershell
.\GCS.ps1 audit -ExpectedLogin YOUR_GITHUB_LOGIN
```

The command makes read-only GitHub API requests. It does not clone repositories and does not use local Git history.

To audit only one repository:

```powershell
.\GCS.ps1 audit -ExpectedLogin YOUR_GITHUB_LOGIN -Repository YOUR_GITHUB_LOGIN/REPOSITORY
```

To choose a report directory or adjust request handling:

```powershell
.\GCS.ps1 audit -ExpectedLogin YOUR_GITHUB_LOGIN -OutputDirectory "$env:USERPROFILE\Documents\GCS-Reports" -RequestTimeoutSeconds 45 -MaxRetries 2
```

`-Repository` avoids scanning branch histories in the other repositories. The inventory request is still used to confirm that the selected repository is accessible.

### Environment check

```powershell
.\GCS.ps1 doctor
```

## Reports

By default, reports are written to:

```text
%LOCALAPPDATA%\GitCommitSigner\reports\
```

V0.1 inventory files:

- `repositories.json` — repository inventory.
- `scan-report.csv` — spreadsheet-friendly repository inventory.
- `summary.json` — V0.1 scan counts.

V0.2 audit files:

- `branch-audit.csv` — repository, branch, head SHA, protection flag, commit count, and branch scan status.
- `commit-signature-audit.csv` — one row per unique commit SHA per repository, including verification status/reason, author/committer metadata, branch names, and commit URL.
- `commit-signature-audit.json` — the same commit audit data in JSON.
- `audit-errors.csv` — repository/branch failures and incomplete-scan reasons.
- `audit-summary.json` — counts and a `Complete` flag.

A report is complete only when no repository or branch scan errors occurred and the scan was not interrupted. Each API page is requested separately, so progress is visible. Every `gh.exe` request has a configurable timeout (45 seconds by default) and up to two retries for transient failures; rate-limit and permission errors are not retried. When Ctrl+C is received, GCS stops the active request, writes results from completed repositories and branches, records the cancellation in `audit-errors.csv`, and sets `Cancelled=true` and `Complete=false` in `audit-summary.json`. Do not treat an incomplete report as a full-account result.

The audit deduplicates a commit only within the same repository. The same SHA appearing in a fork or another repository is reported separately because verification is evaluated in that repository context.

## Read-only and privacy guarantees

- Only GitHub read operations are used by `scan` and `audit`.
- No commits, tags, branches, refs, or repository settings are modified.
- No regular push or force-push is performed.
- The program does not read, copy, or upload SSH private keys.
- GitHub CLI manages authentication; tokens are not written to reports or printed by GCS.
- Reports contain repository and commit metadata. Review reports before sharing them, especially when auditing private repositories.

## Roadmap

- [x] V0.1 — authenticated account check, paginated repository discovery, ownership/visibility classification, JSON and CSV reports.
- [x] V0.2 preview — branch inventory, paginated commit history, GitHub verification classification, per-repository SHA deduplication, and audit reports.
- [x] V0.2.1 preview — single-repository filtering, page-level progress, per-request timeout, bounded transient retries, and cancellation-aware partial reports (runtime validation pending).
- [ ] V0.2 stable — Windows PowerShell 5.1/7 runtime validation across multi-page repositories and representative signature reasons.
- [ ] V0.3 — commit-graph analysis and rewrite planning, including downstream descendants.
- [ ] V0.4 — signed commit reconstruction with merge-parent order and topology preservation.
- [ ] V0.5 — local bundle backups, recovery metadata, and dry-run review.
- [ ] V0.6 — per-branch manual push confirmation with an exact expected remote SHA (lease).
- [ ] V0.7 — post-push GitHub API verification and machine-readable audit report.

## Known limitations

- V0.2 audits ordinary branch refs only. Tags, pull-request refs, and other Git refs are not scanned.
- It reads the commit history reachable from each branch. Shared commits are deduplicated within a repository, but each branch history is requested separately; large repositories with many branches may take time and consume GitHub API quota. Use `-Repository owner/name` to test or audit one repository first.
- A GitHub API permission error, repository removal, or rate limit can make the report incomplete. The error report must be checked.
- Verification is GitHub's reported status, not a local cryptographic re-verification using an SSH allowed-signers file.
- V0.2 is audit-only. It does not perform any signing or history rewriting.

## License

MIT. See [LICENSE](LICENSE).
