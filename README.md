# Status Monitor

SwiftUI macOS 菜单栏监视器：CPU、GPU、温度、网络上传/下载、S.M.A.R.T. 状态，以及 MacBook 内置电池。

## 在另一台 Mac 上启动

需要 macOS 13+ 和 Swift 5.9+（Xcode Command Line Tools 即可）。没有开发工具时先运行 `xcode-select --install`。私有仓库需要有访问权限的 GitHub 账号和 SSH 密钥：

```sh
git clone git@github.com:DuckFeather10086/status-monitor.git
cd status-monitor
./build-app.sh
open StatusMonitor.app
```

构建自动匹配当前 Mac 的架构，Apple Silicon 和 Intel Mac 均可从源码构建。可将生成的应用拖入「应用程序」。本地构建使用 ad-hoc 签名，没有 Developer ID 签名或公证。

更新：在仓库里运行 `git pull --ff-only`，退出旧应用后重新构建并打开。

## 电池

通过 IOKit Power Sources 接口显示内置电池电量、充电中、已充满、接电未充电及电池供电状态。系统提供有效估计时，显示剩余使用时间或充满时间。Mac mini 等无内置电池的机器自动隐藏电池区域，外接 UPS 不会被识别为 MacBook 电池。

电池放在展开面板，避免增加菜单栏宽度。面板底部有背景颜色设置和退出按钮。

## 验证

```sh
zsh test.sh
./build-app.sh
```

包含充放电、暂停充电、满电、无电池/UPS、无效容量和未知时间的测试。Mac mini 上无法验证实际 MacBook 电池，需要在笔记本上实测。

## 当前限制

- 菜单栏文本和展开面板每 2 秒刷新。
- GPU 利用率读取 `IOAccelerator` 的公开 IORegistry 属性；不同 Apple 芯片/系统版本可能显示 `N/A`。
- 温度读取 `IOHWSensor`；不同机型暴露的传感器集合不同。
- S.M.A.R.T. 每约 16 秒读取一次并保留最近结果；APFS 逻辑盘可能无法返回物理盘状态。
- 网速汇总非回环接口，VPN/桥接环境可能重复计数。
- 菜单栏仍受 macOS 可用空间和刘海区域限制；目前没有独立悬浮窗，不能保证输入法菜单增多时读数始终可见。
- 自定义背景针对展开面板，不是整个 macOS 菜单栏。
