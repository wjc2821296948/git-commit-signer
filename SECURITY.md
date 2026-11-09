# Security Policy

## Reporting a vulnerability

Please do not disclose security vulnerabilities in public issues. Use GitHub's private vulnerability reporting feature if it is enabled for this repository. Otherwise, contact the repository owner through the contact method listed on their GitHub profile.

## Scope

The current V0.1 release is read-only. It uses the locally authenticated GitHub CLI to list repositories and writes inventory reports to the local machine. It does not modify remote repositories, rewrite Git history, push refs, or read private SSH key material.

Please include the affected version, Windows and PowerShell versions, reproduction steps, and relevant redacted logs. Never include GitHub tokens, private keys, or other credentials in a report.
