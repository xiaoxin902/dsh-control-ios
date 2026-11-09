# DSH Control

控制这台设备上已经装好的 [DeepSeek Harness][dsh]（下文简称 **dsh**）的 iOS 小工具：
开机自启开关、运行状态、一键启动/停止、全屏打开它的 Web 界面，以及把会话导出成 Markdown 后走系统分享面板。

不是 dsh 的分支，也不是它的官方客户端；它不联网，只跟本机 `127.0.0.1` 上的 dsh 打交道。
（注：App 里嵌的 WebView 打开的仍是 dsh 自己的页面，那部分行为属于 dsh。）

## 功能

- **开机自启开关**：创建/删除 `/var/mobile/Documents/dsh/autostart.off`
- **服务状态**：探测 `127.0.0.1:3080`，显示运行中/未运行与 PID
- **打开**：从 `/tmp/dsh-web.log` 取最新 `?token=` 链接，全屏 WKWebView 打开
  （dsh 只在收到第一次 HTTP 请求后才把 token 写进日志，所以 App 会先探一下）
- **启动 / 停止**：不跳转界面；停止按命令行识别真正的 harness 进程，不轻信 pid 文件
- **导出**：把最新会话转成 Markdown（用户消息、回复、折叠的思考过程、工具调用摘要），
  然后弹 iOS 系统分享面板

## 两个发行版

| | 越狱版 | 巨魔（TrollStore）版 |
|---|---|---|
| 产物 | `bc.8848.dshcontrol_x.y.z_iphoneos-arm64.deb` | `DSHControl.tipa` |
| 安装位置 | `/var/jb/Applications`（rootless / roothide） | 普通 App 容器 |
| 控制方式 | 包内 launchd 守护进程（mobile）+ 一个 root 守护进程（插件安装） | App 直接 `posix_spawn` / `kill`，无守护进程 |
| node 来源 | bootstrap 里的 `node22` | 打进 App 包内，或 `~/Documents/dsh-ts/config.json` 指定 |
| 开机自启 | 依赖 dsh 自己的 LaunchDaemon | **未实现**（见限制） |
| 状态 | 本机日常使用中 | **未在真机验证过** |

## 依赖

- 一台**越狱**设备（Dopamine rootless / roothide），或一台能用 TrollStore 的设备
- 已经装好的 dsh：默认在 `/var/mobile/Documents/dsh`，含 `node22` 运行时与 `node_modules`

## 安装

**越狱版**：用包管理器安装 deb，或本地装：

```
dpkg -i bc.8848.dshcontrol_1.3.2_iphoneos-arm64.deb   # roothide 用户装 roothide 构建
```

**巨魔版**：TrollStore → 右上角 `+` → 选 `.tipa`。安装前先看 [trollstore/README.md](trollstore/README.md)。

## 构建

越狱版由 Apelin 的构建描述驱动（`apelin-project.json`），需要 clang 工具链与 iPhoneOS SDK：

```
apelin_project_build          # 在 Apelin IDE 里
```

巨魔版是独立脚本：

```sh
SDKROOT=/path/to/iPhoneOS.sdk ./trollstore/build-tipa.sh build
# 想把 node22 一起打进包内：
SDKROOT=/path/to/iPhoneOS.sdk NODE_BINARY=/path/to/node22 ./trollstore/build-tipa.sh build
```

iPhoneOS SDK 不能随仓库分发，请自备。

## 配置（巨魔版）

`/var/mobile/Documents/dsh-ts/config.json`，缺字段用默认值：

```json
{
  "dshDir":   "/var/mobile/Documents/dsh",
  "nodePath": "/var/mobile/Documents/dsh-ts/bin/node22",
  "path":     "/var/jb/usr/bin:/usr/bin:/bin",
  "tmpDir":   "/var/mobile/Documents/dsh/tmp"
}
```

越狱版不需要这个文件，路径与原来一致。

## 目录

```
Sources/                App 与守护进程共用的 Objective-C 源码
  DSHService.{h,m}      探测端口、取 token、启动与停止、导出
  DSHConfig.{h,m}       node 路径 / PATH / TMPDIR 的配置与回退
  RootViewController.m  主界面
  DSHWebViewController.m 全屏 WebView 与注入的垫片脚本
Packaging/              deb 布局、entitlements、launchd plist、安装脚本
tools/                  dsh-session-export.js（会话 → Markdown）、tweak 构建脚本
trollstore/             TrollStore 版：构建脚本、Info.plist、entitlements、说明
```

## 诊断

- `/tmp/dsh-control.log`：App 做了什么（启动、状态、导出、页面报错）
- `/tmp/dsh-daemon.log`：控制守护进程的流水
- 导出产物：`/var/mobile/Documents/dsh-backup/exports/`（`latest.md` 为最新一份）

## 安全模型

- 控制守护进程以 **mobile** 身份运行，不构成提权：任何 mobile 进程都能写它的请求文件，
  最坏结果是启动/停止 dsh。
- root 守护进程只做一件事：从 `/var/mobile/Documents/dsh/inbox` 安装**受限**的插件包
  （拒绝 preinst/postinst 等维护者脚本、拒绝 setuid、只允许写入插件目录）。
- App 不联网，除 dsh 的本地端口和它的 WebView 外没有外部连接。

## 已知限制

- **巨魔版没有在真机上跑过**：只验证了编译、双架构、签名与 `.tipa` 结构。
  最大的不确定点是 AMFI——包内嵌套的 `node22` 能否被 TrollStore 一起签名并通过运行检查。
- 巨魔版没有开机自启；也**不带**插件安装守护进程（那需要 root）。
- 越狱版停止 dsh 时先 `kill(SIGTERM)`，失败才用 task port，两者都只在越狱环境成立。

## 许可

MIT，见 [LICENSE](LICENSE)。与 DeepSeek 官方无关，dsh 本身按其自身条款分发。

[dsh]: https://github.com/deepseek-ai
