# Lilywhite

A clean integrated status bar capsule tweak for iOS 17.1.2 RootHide.

## Current build

- Version: 0.1.4
- Target: SpringBoard
- Package scheme: RootHide
- Architecture: arm64e
- Minimum iOS: 15.0

This build keeps the previously stable status-bar implementation and adds targeted fixes for the right-side notification icon tray, including restoration after opening and dismissing Notification Center. It also reduces unnecessary timer/debug overhead and reconciles notification state after removals.

## Install with Sileo

Add this repository:

https://ice21415.github.io/Lilywhite/

GitHub Actions automatically builds the RootHide package after changes to the tweak/build files and refreshes the repository metadata.

## Build locally

```sh
THEOS=/path/to/roothide-theos make package THEOS_PACKAGE_SCHEME=roothide
```

The generated package is written to `build-packages/`.
