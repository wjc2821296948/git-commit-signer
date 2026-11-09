# Git Commit Signer (GCS)

**A Windows-first tool for auditing GitHub repositories and, in later versions, safely re-signing unsigned Git commits.**

[简体中文](README.zh-CN.md)

> **Current status: V0.1 — read-only repository discovery.**
>
> This release discovers repositories visible to the authenticated GitHub account and exports JSON/CSV inventory reports. It does **not** inspect commit-signature status yet, rewrite commits, change Git refs, or push anything to GitHub.

## Goals

- Scan repositories visible to the authenticated GitHub account, not just repositories already cloned on the current computer.
- Distinguish owned repositories, forks, collaborator/organization repositories, and archived repositories.
- Keep already-verified commits untouched in future rewrite workflows.
- Re-sign only unsigned commits where identity and repository permissions are suitable.
- Preserve merge topology when rewriting is enabled in a later release.
- Create local recovery backups and require explicit confirmation before every remote branch update.
- Use the user's existing SSH signing key; never upload or transmit a private key.

## V0.1 prerequisites

- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7+
- Git for Windows
- GitHub CLI (`gh`)
- An authenticated GitHub CLI session with permission to list the repositories you want to inventory

No Python, Node.js, paid API, or additional service is required.

## Setup

1. Install Git for Windows and GitHub CLI if they are not already installed.
2. Authenticate GitHub CLI:

   ```powershell
   gh auth login
   gh auth status
   ```

3. Download or clone this repository.
4. Run the environment check:

   ```powershell
   .\GCS.ps1 doctor
   ```

## Publish this project to your GitHub account

On the Windows machine where SSH commit signing is already configured:

1. Extract this archive into a new folder.
2. Open the folder and double-click `PUBLISH.cmd`.
3. Confirm the GitHub account shown is `wjc2821296948`, then type `Y`.

The script verifies the GitHub CLI account, `gpg.format=ssh`, `commit.gpgsign=true`, and the configured public signing-key file. It then creates a signed initial commit and uses `gh repo create` to create `wjc2821296948/git-commit-signer` as a **public** repository and push `main`. It aborts if the folder already has a `.git` directory or the checks fail. It never reads or uploads the private SSH key.

The repository creation command uses the official GitHub CLI `gh repo create` workflow. If publication fails after the local commit, the signed commit remains in this folder and can be pushed later after the cause is resolved.

## Scan all accessible repositories

Run in PowerShell from the project directory:

```powershell
.\GCS.ps1 scan
```

To require a specific GitHub account:

```powershell
.\GCS.ps1 scan -ExpectedLogin wjc2821296948
```

To choose a report directory:

```powershell
.\GCS.ps1 scan -OutputDirectory "$env:USERPROFILE\Documents\GCS-Reports"
```

The script uses GitHub's authenticated `/user/repos` endpoint with pagination and requests the `owner`, `collaborator`, and `organization_member` affiliations. It does not print or save the authentication token.

## Reports

By default, reports are written to:

```text
%LOCALAPPDATA%\GitCommitSigner\reports\
```

Files:

- `repositories.json` — complete repository inventory.
- `scan-report.csv` — spreadsheet-friendly inventory.
- `summary.json` — counts and scan metadata.

The report marks a repository as eligible for a *future* rewrite only when it is owned by the authenticated account, is not archived, and the API reports push permission. This is metadata only; V0.1 performs no rewrite.

## Commands

| Command | Purpose |
|---|---|
| `scan` | Read-only repository discovery and report export |
| `doctor` | Check PowerShell, Git, GitHub CLI, OpenSSH, authentication, and Git signing configuration |
| `help` | Show command help |

## Safety guarantees in V0.1

- Read-only against GitHub: only GET-style API requests are used.
- No commits, tags, branches, or refs are changed.
- No force-push or regular push is performed.
- No private key is read, copied, or uploaded.
- Reports contain repository metadata, not GitHub credentials.

## Roadmap

- [x] V0.1 — account authentication check, paginated repository discovery, ownership/visibility classification, JSON and CSV reports.
- [ ] V0.2 — branch inventory and GitHub commit-signature status classification (`verified`, `unsigned`, `unknown_key`, `invalid`, and other reasons).
- [ ] V0.3 — commit-graph analysis and rewrite planning, including downstream descendants.
- [ ] V0.4 — signed commit reconstruction with merge-parent order and topology preservation.
- [ ] V0.5 — local bundle backups, recovery metadata, and dry-run review.
- [ ] V0.6 — per-branch manual push confirmation with an exact expected remote SHA (lease).
- [ ] V0.7 — post-push GitHub API verification and machine-readable audit report.

## Important limitations planned for later versions

Rewriting a commit changes its SHA. Descendants whose parent SHA changes must also be recreated and re-signed, even if they were previously verified. Merge commits require preserving their complete ordered parent list and tree. Commits authored by other people must not be silently recreated as the current user. Protected branches, open pull requests, annotated tags, special commit headers, and remote updates require additional safeguards. These are not handled by V0.1.

## License

MIT. See [LICENSE](LICENSE).
