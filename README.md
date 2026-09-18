# Lilywhite

Public binary and Sileo repository for Lilywhite.

- Target: iOS 17.1.2 RootHide
- Architecture: arm64e
- Package: `com.user.lilywhite`
- Sileo source: https://ice21415.github.io/Lilywhite/

This repository intentionally contains release packages and APT metadata only.
The source code and build configuration are kept in a separate private repository.

## Files

- `*.deb` — installable RootHide packages
- `Packages` / `Packages.bz2` — Sileo/APT package index
- `Release` — repository metadata

New release packages are built from the private source repository. Automatic
publishing is enabled there when its `PUBLIC_REPO_TOKEN` Actions secret is configured.
