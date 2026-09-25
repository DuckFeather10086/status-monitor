#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/checks
# Works with Command Line Tools alone, without XCTest from full Xcode.
swiftc Sources/StatusMonitor/Battery.swift Tests/StatusMonitorTests/BatteryTests.swift -o .build/checks/battery-tests
.build/checks/battery-tests
