# Lilywhite

A clean integrated status bar capsule tweak for iOS 17.1.2 RootHide.

## Current build

- Target: SpringBoard
- Package scheme: RootHide
- Architecture: arm64e
- Minimum iOS: 15.0

## Install with Sileo

Add this repository:

https://ice21415.github.io/Lilywhite/

This is an early device-test build. Exact Wi-Fi and cellular signal bars still need to be mapped against the iOS 17.1.2 SpringBoard status-bar classes.

## Build

THEOS=/home/theos/roothide-theos make package THEOS_PACKAGE_SCHEME=roothide
