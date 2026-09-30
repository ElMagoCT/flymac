#!/bin/sh
# Runs `swift test` on a Mac that has only Command Line Tools (no Xcode).
# XCTest is not shipped with CLT, but Swift Testing is, in a non-default location.
set -e
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [ -d "$F" ]; then
  exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
else
  exec swift test "$@"   # full Xcode toolchain
fi
