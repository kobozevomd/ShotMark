#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 -framework AppKit -framework Vision \
  Sources/LinkUploader.swift Sources/TextRecognizer.swift tools/FeatureTests.swift \
  -o build/FeatureTests
build/FeatureTests
