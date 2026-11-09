# DSH 更新日志

## 1.3.2（2026-11-09）

- 运行环境改成可配置（`Sources/DSHConfig.m`，覆盖文件
  `/var/mobile/Documents/dsh-ts/config.json`）：node 路径、PATH、TMPDIR 不再是写死的
  `/var/jb/...`。越狱版不写这个文件，行为与之前完全一致。
- 新增**巨魔（TrollStore）发行版**：`trollstore/` 目录里是独立的一套构建
  （`-DTROLLSTORE=1` + 自己的 Info.plist / entitlements + `.tipa` 打包脚本），
  不带守护进程，导出由 App 自己跑 node。
  支持把 node22 打进包内（`NODE_BINARY=…`，97 MB → tipa 压缩后 32 MB），
  绕开"用户目录里的临时签名二进制能否 exec"的不确定。
  详见 `trollstore/README.md`；**未在 TrollStore 真机上验证**。

## 1.3.1（2026-11-09）

- 新增「导出」按钮：把**最新** dsh 会话转成 Markdown，并弹出 iOS 系统分享面板。
- 导出由包内的控制守护进程执行（App 的沙箱看不到 `~/.dsh`，守护进程不受限），
  脚本随包安装到 `/usr/libexec/dsh-session-export.js`，产物在
  `/var/mobile/Documents/dsh-backup/exports/`（`latest.md` 为最新一份）。
- 导出内容包括用户消息、助手回复、折叠的思考过程、工具调用摘要。
- 顺带修掉本机 dsh 插件面板的两处故障：补上 `npm` 入口
  （`~/.local/bin/npm`，原来只有 `npm22`，插件安装器找不到 npm；
  注意 `awesome-dsh-plugin.com` 在本机 DNS 被解析成 198.18.x 假地址，用不了）。

## 1.3.0（2026-11-09）

- 内部版本：先做「App 内直接跑 node 导出」，因沙箱读不到 `~/.dsh` 改为 1.3.1 的方案。

## 1.2.4（2026-11-08）

- 应用内注入的弹层样式整段删除：弹层实色改由 dsh 自己的主题文件
  （`dsh-client-ui-theme/lib/client.js`）负责，Safari 和 app 内一起生效。
  注入脚本只剩垫片、键盘、日志。
- 该主题文件已打补丁（备份 `client.js.bak-20261108-224511`）：
  `--dsw-menu-surface-fill` 改为 `#fcfdfe` / `#303136`（原为 70%/64% 半透明），
  `--dsw-menu-backdrop-filter` 改为 `none`，并给菜单/对话框/滚动容器加
  `overscroll-behavior: contain`（修「滑模式选择器时页面跟着滚」）。
- 重启 dsh 后生效；页面需要重新加载一次。

## 1.2.3（2026-11-08）

- 新增 `bc.8848.dshcontrol.installer` 守护进程（以 root 运行，`WatchPaths` 盯
  `/var/mobile/Documents/dsh/inbox/`，另有 5 秒轮询兜底）：把投进去的插件包装上，
  写 `/var/mobile/Documents/dsh/installer/result.json`，包移到 `done/` 或 `rejected/`。
  只做这一件事，三道限制：
  1. 只处理 inbox 里的 `*.deb`；
  2. 带 `preinst/postinst/prerm/postrm` 的包直接拒绝（不允许以 root 执行脚本）；
  3. 文件必须落在 `Library/MobileSubstrate/DynamicLibraries/`（含 rootless 的
     `var/jb/` 前缀），出现别的路径或 setuid 文件一律拒绝。
- 实测：探针插件包投进 inbox 后自动装好；带 `postinst` 的包被拒且脚本没执行；
  往 `/usr/bin` 写文件的包被拒。
- 启动脚本补 `PATH`（launchd 给的是空 PATH，否则 `mv`/`basename` 都找不到）；
  `ios-tweak-build.sh` 生成的 deb 改为 rootless 的 `var/jb/` 布局，Irisin 才收。
- postinst 创建 `inbox/`、`installer/` 及其子目录并交给 mobile（逐层
  `mkdir -m 0755` + `chown -h 501:501`），同时加载两个守护进程；prerm 一并卸载。

## 1.2.0（2026-11-08）

- 安装守护进程的第一版（`bc.8848.dshcontrol.installer`），见 1.2.3 的说明。

## 1.1.2（2026-11-08）

- 页面里的弹层（右上「更多」、输入框旁的「+」、模型与推理强度菜单）改成**实色背景**：
  dsh 原本用 `--dsw-menu-surface-fill: #303136a3`（深色仅 64% 不透明）+ `backdrop-filter`
  模糊，在 WebView 里和底下的内容糊在一起，看不清。现在浅色 `#fcfdfe`、深色 `#303136`，
  关掉模糊，并补一圈 0.5px 描边。实测运行时取到的变量值已是 `#fcfdfe` / `none`。
- 修好注入脚本里一直没生效的 `send()`：shim 里根本没有这个函数，导致
  `quiet.arm`（点停止后压住键盘）等上报全部抛异常，现在日志里能看到
  `page: quiet.arm`、`page: focus.blocked`。

## 1.1.1（2026-11-08）

- 修复：停止 → 启动 → 点「打开」报「没有找到访问地址」。
  原因是 dsh 只有在**收到过一次 HTTP 请求之后**才会把带 token 的地址写进
  `/tmp/dsh-web.log`，而应用只看端口通不通，所以刚启动时日志里根本没有地址。
  现在守护进程在启动完成后会自己请求一次首页（实测启动后日志里已有 token），
  应用在「打开」时若仍读不到地址也会补一次请求再读。
- 修复：停止时改用 `ps` 扫描真实运行的 dsh 进程，不再依赖可能过期的
  `dsh-web.pid`（旧逻辑会「停止失败」或杀掉无关进程）；启动前也先检查
  是否已有实例，避免同一端口起两个 dsh。
- 修复：启动后守护进程会等到 dsh 进程真的出现才回报 `started`，
  不再出现「提示已启动但进程立刻消失」。

## 1.1.0（2026-11-08）

- 启动 / 停止不再跳转界面：新增一个极小的 launchd 守护进程
  （`bc.8848.dshcontrol.control`，以 mobile 运行、无沙盒、`WatchPaths` 触发）。
  应用只写一个请求文件 `/var/mobile/Documents/dsh/.dshcontrol-request`，守护进程执行完把结果
  写到 `.dshcontrol-result` 后退出；实测 `stop` → `{"ok":true,"message":"stopped"}`、
  `start` → `started`，dsh 进程来去正常，全程没有窗口跳转。
  主应用仍先尝试自己执行，被沙盒拒绝（EPERM）才走守护进程；守护进程缺失时回退到辅助 app。
- 键盘：点停止后 3 秒、点任何按钮（`+`、`···`、回退、停止）后 1.2 秒内，页面自己发起的
  聚焦一律吞掉（`HTMLElement.prototype.focus` 打补丁 + `focusin` 兜底 + 原生
  `endEditing`），你自己点输入框仍然立刻弹键盘。
- 「打开」在刚启动时最多等 5 秒等 token 写进日志，不再第一次点就弹「没有找到访问地址」。

## 1.0.3（2026-11-08）

- 停止后不再自动弹键盘：页面在“忙 → 不忙”时会把焦点塞回输入框（dsh 自己的逻辑），
  现在注入的脚本在 `api/session/cancel` 返回后的 2.5 秒内，把没有用户手势的自动聚焦
  立刻 blur 掉；你自己点输入框（有触摸/按键手势）仍然照常弹键盘，可以立刻接着打字。
- 页面桥继续记录 console 错误、未捕获异常、每次 fetch 与 API 响应体、WebSocket 状态，
  写到 `/tmp/dsh-control.log`。

## 1.0.2（2026-11-08）

- 「打开」的网页视图改成独立顶栏（左侧显示地址栏主机名、右侧「关闭」），不再用浮在
  页面右上角的圆形按钮——原来那个按钮正好盖住 dsh 页面自己的“停止/关闭”控件，
  导致对话停不下来。
- 后端侧修复（不在本包内，记录在此）：给 dsh 的 harness 加 `--experimental-sqlite`，
  Node 22 默认不提供 `node:sqlite`，社区插件（如 dsh-purge）服务端会整块导入失败、
  页面报 404。

## 1.0.1（2026-11-08）

- 「打开」改回全屏 WKWebView（无地址栏），并在页面脚本运行前注入 JS 垫片：
  `AbortSignal.any`、`AbortSignal.timeout`、`Promise.withResolvers`、`Object.groupBy`。
  这些 API 在 iOS 17.4 之前不存在，dsh 前端调用它们会抛
  `AbortSignal.any is not a function`（例如「选择工作区目录」），垫片让 iOS 16、
  17.0–17.3 也能正常用。
- 启动 / 停止移到包内的隐藏辅助 app `DSH 助手`（bundle id
  `bc.8848.dshcontrol.helper`）：主应用因 WebKit 需要数据容器而被沙盒约束，无法
  `exec` / `kill`；辅助 app 以免沙盒签名，由 `dshhelper://start|stop` 唤起，
  完成后把结果写到 `/tmp/dsh-helper.json` 并回到主应用。
- 主应用改为「有数据容器」的沙盒 app，用 entitlements 的文件例外访问
  `/var/mobile/Documents/dsh/` 与 `/private/var/tmp/`。

### 已知限制

- 点「启动 / 停止」时屏幕会短暂切到辅助 app 再切回（约 0.5–1 秒）。
- 辅助 app 用 `SBAppTags=hidden` 声明为隐藏应用，是否真的不出现在桌面未在本机确认。

## 1.0.0（2026-11-08）

首个版本：本机 DeepSeek Harness（dsh）控制面板。

- 开机自启开关：切换时创建或删除 `/var/mobile/Documents/dsh/autostart.off`，
  与 daemon 读取的是同一个文件。
- 服务状态：对 127.0.0.1:3080 做一次 TCP 探测，显示「运行中 / 未运行」和 PID，
  前台时每 2 秒自动刷新。
- 打开 DeepSeek Harness：从 `/tmp/dsh-web.log` 取最新的 token 链接并全屏打开；
  日志里没有链接时提示先启动。
- 启动 / 停止：启动执行 `/var/mobile/Documents/dsh/dsh`（经 bootstrap 的
  `/bin/sh` 执行，因为 iOS 自身没有 shebang 指向的 `/bin/sh`）；停止读取
  `dsh-web.pid`、发送 SIGTERM，卡住时升级为 SIGKILL，并在确认端口关闭后清理
  过期 pid 文件。
- 诊断日志：`/tmp/dsh-control.log`，同时以 os_log 输出（subsystem
  `bc.8848.dshcontrol`）。
