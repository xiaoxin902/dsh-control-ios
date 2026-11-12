# DSH Control

控制这台设备上已经装好的 [DeepSeek Harness][dsh]（下文简称 **dsh**）的 iOS 小工具：
开机自启开关、运行状态、一键启动/停止，以及全屏打开它的 Web 界面。

不是 dsh 的分支，也不是它的官方客户端；它不联网，只跟本机 `127.0.0.1` 上的 dsh 打交道。
（注：App 里嵌的 WebView 打开的仍是 dsh 自己的页面，那部分行为属于 dsh。）

## 功能

- **开机自启开关**：创建/删除 `/var/mobile/Documents/dsh/autostart.off`
- **服务状态**：探测 `127.0.0.1:3080`，显示运行中/未运行与 PID
- **打开**：从 `/tmp/dsh-web.log` 取最新 `?token=` 链接，全屏 WKWebView 打开
  （dsh 只在收到第一次 HTTP 请求后才把 token 写进日志，所以 App 会先探一下）
- **启动 / 停止**：不跳转界面；停止按命令行识别真正的 harness 进程，不轻信 pid 文件

## 依赖

- 一台**越狱**设备（Dopamine rootless / roothide）
- 已经装好的 dsh：默认在 `/var/mobile/Documents/dsh`，含 `node22` 运行时与 `node_modules`

### 运行时：Node.js 22

dsh 的后端跑在 **Node.js 22** 上，本项目的启动与停止都直接调用它的二进制
`/var/jb/usr/local/bin/node22`。iOS 本身不带 Node，需要从越狱源安装：

1. 在 Sileo / Zebra / Cydia 里添加源：**https://huayuarc.github.io**
2. 在该源里搜索 **nodejs22**
3. 安装 `nodejs22-ios-rootless`（rootless 引导）或对应的 roothide 包
   - 本机实测：`nodejs22-ios-rootless 22.12.0-27`（`iphoneos-arm64`，Name 显示为 `Nodejs22-ios`）
4. 装完确认路径：`/var/jb/usr/local/bin/node22` 存在且可执行

iOS 没有 JIT，Node 必须以 `--jitless` 运行——App 与守护进程都是这样调用它的；
找不到 `node22` 要么启动不了 dsh，要么会在加载 WebAssembly 时报错。

## 安装

用包管理器安装 deb，或本地装：

```
dpkg -i bc.8848.dshcontrol_1.3.2_iphoneos-arm64.deb
```

roothide 用户装 roothide 构建，rootless 用户装 rootless 构建，两者路径前缀不同，不能混装。

## 结构

App 里没做的事情交给两个 launchd 守护进程，它们都以最小身份运行：

- `bc.8848.dshcontrol.control`（**mobile** 身份）：由 App 写请求文件唤醒，负责启动/停止 dsh
- `bc.8848.dshcontrol.installer`（**root** 身份）：只从 `inbox/` 安装受限的插件包

## 构建

本项目在设备上构建，用 **Apelin** 这个 iOS IDE，构建描述是仓库根目录的 `apelin-project.json`。

Apelin 的安装：在 Sileo / Zebra / Cydia 里添加越狱源 **https://apt.owngoal.dev**，
搜索 **Apelin** 安装。装上之后在它的工具链设置里准备 clang 工具链与 iPhoneOS SDK，
打开本项目，`构建` 即可产出 deb。

```
apelin：构建 → bc.8848.dshcontrol_x.y.z_iphoneos-arm64.deb
```

iPhoneOS SDK 不能随仓库分发，请自备。

## 目录

```
Sources/                App 与守护进程共用的 Objective-C 源码
  DSHService.{h,m}      探测端口、取 token、启动与停止
  DSHConfig.{h,m}       node 路径 / PATH / TMPDIR 的配置与回退
  RootViewController.m  主界面
  DSHWebViewController.m 全屏 WebView 与注入的垫片脚本
Packaging/              deb 布局、entitlements、launchd plist、安装脚本
tools/                  tweak 构建脚本等辅助文件
docs/                   发布相关说明
```

## 诊断

- `/tmp/dsh-control.log`：App 做了什么（启动、状态、页面报错）
- `/tmp/dsh-daemon.log`：控制守护进程的流水

## 安全模型

- 控制守护进程以 **mobile** 身份运行，不构成提权：任何 mobile 进程都能写它的请求文件，
  最坏结果是启动/停止 dsh。
- root 守护进程只做一件事：从 `/var/mobile/Documents/dsh/inbox` 安装**受限**的插件包
  （拒绝 preinst/postinst 等维护者脚本、拒绝 setuid、只允许写入插件目录）。
- App 不联网，除 dsh 的本地端口和它的 WebView 外没有外部连接。

## 许可

MIT，见 [LICENSE](LICENSE)。与 DeepSeek 官方无关，dsh 本身按其自身条款分发。

[dsh]: https://github.com/deepseek-ai
