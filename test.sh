#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/checks
# Works with Command Line Tools alone, without XCTest from full Xcode.
swiftc Sources/StatusMonitor/Battery.swift Tests/StatusMonitorTests/BatteryTests.swift -o .build/checks/battery-tests
.build/checks/battery-tests
clang -c Sources/CSMC/CSMC.c -I Sources/CSMC/include -o .build/checks/smc.o
swiftc -I Sources/CSMC/include Sources/StatusMonitor/Sensors.swift Tests/SensorTests.swift .build/checks/smc.o -framework IOKit -o .build/checks/sensor-tests
.build/checks/sensor-tests "$@"
swiftc -I Sources/CSMC/include Sources/StatusMonitor/Battery.swift Sources/StatusMonitor/Sensors.swift Sources/StatusMonitor/Network.swift Sources/StatusMonitor/NetworkMenuImage.swift Sources/StatusMonitor/Preferences.swift Sources/StatusMonitor/SystemSampler.swift Tests/MonitorTests.swift .build/checks/smc.o -framework IOKit -o .build/checks/monitor-tests
.build/checks/monitor-tests "$@"
