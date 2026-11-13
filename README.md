# 网络修复 Mac · Network Repair for macOS

一个中文原生 macOS 小工具，用来处理 VPN 或代理软件使用后常见的 DNS、hosts 和系统代理配置问题。点击一次「修复网络」，完成配置处理、DNS 缓存刷新和连接复查。

**Mac 专用：Apple 芯片 Mac，macOS 14 或更高版本；不支持 Windows。** 当前发布的应用包仅包含 arm64 版本。

> 修复会移除自定义 hosts 映射，并关闭当前网络位置中普通网络服务的系统代理。请先断开 VPN、退出代理或加速软件，确认这些改动符合你的需要后再点击修复。

## 下载与使用

在仓库的 [Releases 页面](https://github.com/hotcheese419/network-repair/releases/latest) 下载 `network-repair-macos-arm64-v1.0.0.zip`。GitHub 自动生成的 **Source code** 压缩包是源码，不是可直接运行的应用。

1. 解压应用包，将「网络修复.app」放到「应用程序」、桌面或其他方便的位置。
2. 打开应用，等待配置与网络连接检查完成。
3. 点击「修复网络」，在 macOS 授权窗口验证管理员身份。
4. 查看窗口上方的结果；展开「诊断详情与日志」可查看处理步骤和连接测试结果。

预编译应用使用本地 ad hoc 签名，**未经过 Apple Developer ID 签名或公证**。下载后 macOS 可能阻止首次打开；可根据系统「隐私与安全性」中的提示处理，或从源码自行构建。请从本仓库的正式 Release 获取应用，并使用随附的 SHA-256 文件核对下载内容。

## 修复范围

| 项目 | 点击修复后的行为 |
| --- | --- |
| DNS 与搜索域 | 清除当前网络位置中普通网络服务的手动 DNS、搜索域及其他手动 DNS 配置，恢复由网络提供解析设置。 |
| 系统代理 | 关闭同一范围内的 HTTP、HTTPS、SOCKS 等手动代理，以及 PAC 和代理自动发现；保留服务器地址、端口、PAC URL 和绕过列表。 |
| hosts | 将系统 hosts 恢复为 macOS 默认的三条本地主机映射，自定义映射会移除。 |
| DNS 缓存 | 刷新目录服务 DNS 缓存，通知 mDNSResponder 重新加载。 |
| 连接复查 | 检查域名解析和固定公开网站的 HTTPS 连接，区分解析失败、连接失败、超时与可能的网络认证页。 |

工具只处理**当前网络位置的普通网络服务**，跳过识别为 VPN 的服务。它不会删除 VPN、改动固定 IP 或路由、清空 `/etc/resolver`，也不会删除企业管理描述文件。

配置修复成功不代表所有网站都能访问。Wi-Fi 未连接、路由器或宽带故障、网络需要网页认证，以及仍在运行的 VPN 隧道或网络扩展，都可能使连接检查继续失败。

## 权限与隐私

- 使用 macOS 自带的管理员授权窗口，不保存管理员密码，不安装常驻提权服务。
- 打开时和点击「重新检查」时只进行检查；系统配置修改由「修复网络」触发。
- 不常驻后台，不提供「恢复上次备份」功能，也不保存历史备份。
- 修复期间仅在内存保留当前操作的回滚快照。中途失败会尝试回滚已修改的配置；若回滚也失败，会在日志中说明。
- 连通性检查直接访问 Apple 与百度的固定公开 HTTPS 页面，不上传本机配置；检查绕过系统 HTTP 代理，VPN 隧道仍可能影响结果。
- 窗口内的诊断日志可用于排查问题。提交 Issue 前，请自行检查并移除其中不想公开的网络配置。

## 从源码构建

需要 Apple Command Line Tools，以及支持项目中 Swift / SwiftUI API 的 Swift 编译器。项目只依赖系统框架，无需下载第三方依赖。

在仓库目录运行：

```sh
chmod +x build.sh run-tests.sh
./build.sh ./dist
```

构建产物位于 `dist/网络修复.app`。构建脚本当前生成 **macOS 14+ / arm64** 应用，并进行本地 ad hoc 签名。

运行测试：

```sh
./run-tests.sh
```

测试脚本会构建应用、运行隔离自检，并执行只读的公开网站连接检查；后者需要网络连接。

| 文件 | 用途 |
| --- | --- |
| `main.swift` | 原生窗口、状态展示与系统授权入口。 |
| `ResetCore.swift` | 配置检查、修复事务、失败回滚与隔离自检。 |
| `NetworkDiagnostics.swift` | 有超时限制的只读连接检查。 |
| `MakeIcon.swift` | 生成应用图标。 |
| `build.sh` | 编译与应用打包。 |
| `run-tests.sh` | 构建和测试入口。 |
| `tests/Diagnostics/main.swift` | 连接诊断场景测试。 |

## 已完成的验证

首版已完成编译、应用签名校验、GUI 启动与只读检查。隔离测试覆盖 hosts 解析、普通网络与 VPN 范围区分、DNS 和代理快照、代理参数保留、文件链接拒绝，以及修复事务各阶段失败和回滚失败的报告。

诊断测试覆盖成功、认证页、重定向、DNS / 连接 / TLS 失败、超时、单站可用和无默认接口等场景。

**发布前没有在真实系统上执行带管理员权限的完整修复。** 这些编译、隔离测试和只读验证，不等同于真实提权修复已经通过；欢迎在理解修复范围的前提下报告可复现的问题。

软件底部的轮椅小标识可打开作者账号面板，支持一键复制账号。

## 作者与社交账号

- 抖音：电动轮椅 · @aigclunyi
- 小红书：电动轮椅 · @aigclunyi
- X：AIGC电动轮椅 · @cheese069696

## 开源许可证

本项目采用 [MIT License](LICENSE)。

## English

Network Repair is a small native macOS utility for common DNS, hosts and system proxy configuration problems after using a VPN or proxy. One click clears manual DNS settings, disables proxy switches for ordinary services in the current network location, restores the default hosts file, flushes DNS caches and checks connectivity.

The prebuilt app requires an Apple Silicon Mac running macOS 14 or later. It uses the macOS administrator authorization dialog, stores no administrator password and installs no persistent privileged service. Custom hosts entries are removed during repair. There is no backup history or restore feature; failed operations attempt an in-memory transactional rollback.

The current binary is ad hoc signed and is not Apple notarized. The initial release has build, UI, isolated transaction and read-only connectivity verification; a full privileged repair on a real system has not yet been exercised. MIT licensed.
