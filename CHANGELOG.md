# Changelog

## [Unreleased]

### Added
- Add a read-only V0.2 audit command that inventories repository branches and all reachable commits.
- Add an optional repository filter so users can validate one repository before starting a full-account audit.
- Show repository, branch, and API page progress while scanning.
- Classify GitHub commit verification states and export branch, commit, error, and summary reports.
- Deduplicate commit SHAs across branches within each repository.
- Stop the audit when GitHub API rate limiting is detected and mark partial results incomplete.

### Fixed
- Decode paginated API records one at a time to avoid large nested JSON parsing failures in Windows PowerShell 5.1.
- Replace unbounded `gh api --paginate` waits with individually paged requests that have a per-request timeout.
- Retry transient network and server failures only a bounded number of times; do not retry rate-limit responses.
- Handle Ctrl+C by stopping the active `gh.exe` process and saving completed repository/branch results as an incomplete report.

## [0.1.0] - 2026-11-09

### Added
- Read-only GitHub account repository discovery through GitHub CLI.
- Pagination across all accessible repositories.
- Repository ownership, fork, archived, visibility, and push-permission classification.
- JSON, CSV, and summary report export.
- Environment diagnostics for Git, GitHub CLI, OpenSSH, authentication, and signing configuration.

### Security
- No GitHub write operations.
- No commit rewriting or pushing.
- No private-key access or upload.
