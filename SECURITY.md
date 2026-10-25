# Security policy – Update Center

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Use GitHub's
**“Report a vulnerability”** button (Security tab → Advisories) to report privately.
You will get an answer as soon as possible; fixes are shipped as a new release, which
installed copies pick up automatically through the built-in self-update.

## How Update Center protects itself

| Area | Measure |
|---|---|
| Code that runs as administrator | Installed to `C:\Program Files\Update Center` (only administrators can change it) |
| Settings / selection files | `C:\ProgramData\UpdateCenter` with an ACL that only lets administrators write |
| Module hijacking | Elevated processes only load PowerShell modules from protected system folders |
| Tools it starts | `winget` from its protected package folder, Chocolatey via the machine-wide path only |
| Driver downloads | HTTPS from `download.nvidia.com` only and a valid NVIDIA Authenticode signature |
| Self-update | HTTPS from `github.com` only, SHA-256 checked, version must match the release tag |
| Dependencies | None besides Windows itself (PowerShell 5.1, .NET Framework, WPF) |
| Repository | Weekly security workflow (static analysis with security rules, secret scan, smoke test), Dependabot for GitHub Actions |

## Known limitation

The SHA-256 checksum is published in the same GitHub release as the package. It proves the
download is intact, but someone who takes over the GitHub account could replace both. Protect
the account with two-factor authentication. Code signing of the scripts is planned.
