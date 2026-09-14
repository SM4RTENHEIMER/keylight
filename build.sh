#!/bin/sh
# Compile keylight with the Swift that ships with Xcode's command line tools.
cd "$(dirname "$0")" && xcrun swiftc -swift-version 5 -O -framework AppKit -o keylight camelot.swift main.swift && echo "built ./keylight"
