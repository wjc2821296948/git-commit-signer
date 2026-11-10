# Changelog

## [Unreleased]

### Added
- Add a read-only V0.2 audit command that inventories repository branches and all reachable commits.
- Classify GitHub commit verification states and export branch, commit, error, and summary reports.
- Deduplicate commit SHAs across branches within each repository.
- Stop the audit when GitHub API rate limiting is detected and mark partial results incomplete.

### Fixed
- Decode paginated API records one at a time to avoid large nested JSON parsing failures in Windows PowerShell 5.1.

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
