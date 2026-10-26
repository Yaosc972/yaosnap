# Yaosnap

Yaosnap 是 macOS 原生截图工具，自用，面向一个人日常的截图与对照工作流。用 Swift 和 AppKit 写成，零第三方依赖，最低支持 macOS 12。

## 项目定位

Yaosnap 以 Snipaste 2 Pro 为参考重新实现，目标是把自己的高频截图流程做顺手，不追求功能对标。

Yaosnap 不是 Snipaste 的衍生版，没有复用它的代码或二进制。功能范围按自己的使用频率裁剪，交互习惯尽量贴近 Snipaste。P1 完成截图核心链路，标注、贴图、OCR 与扫码在 P2 及以后。

## 功能概览（P1 已实现）

- 菜单栏常驻应用，没有 Dock 图标
- 全局热键 ⌃⇧A 唤出截图，其他应用在前台时同样生效
- 多屏冻结帧覆盖，每块屏幕一个覆盖窗口
- 拖拽选区，正向与反向都支持，实时显示尺寸
- 窗口悬停高亮，单击吸附整个窗口，拖动则改为自由选区
- Enter 或双击复制选区到剪贴板
- ⌘S 或保存按钮保存 PNG（默认桌面）；⇧+保存按钮或 ⌘⇧S 直接写快捷保存目录
- 中键或工具条「贴到屏幕」按钮把选区贴成置顶窗口
- Esc 取消，光标与窗口状态恢复
- 多屏输出按屏幕身份匹配，复制与保存不会串到另一块屏幕

F1 也注册为备用热键。Apple 键盘默认媒体键模式下，物理 F1 不产生键盘事件，说明见[使用](#使用p1)。

P1 的自动化验收覆盖捕获、覆盖层、剪贴板、保存面板与逐像素比对，共 16 项。单元测试 21 项。里程碑 tag 为 `p1-core`，验收记录见 [P1 验收记录](docs/superpowers/plans/2026-10-24-yaosnap-p1-verification.md)。

## 与 Snipaste 2 Pro 的差异

P1 只覆盖截图核心，以下 Snipaste 能力尚未实现：

- 标注系统，包括 12 种形状与二次编辑
- 贴图窗口，包括置顶、缩放、分组与多屏
- OCR 文字识别与二维码识别
- 命令行接口与自定义快捷键
- 屏幕触发角、白板模式、截图历史

待办与优先级记录在[设计规格第 12 节](docs/superpowers/specs/2026-10-24-yaosnap-design.md)。其中三项来自 P1 验收时的体验反馈：截图期间的十字光标、选区旁的操作工具条、遮罩亮度与窗口提亮。

## 明确不做

- 不做跨平台，只支持 macOS。
- 不做授权与试用，没有 Pro 门控。
- 不做自动更新。
- 不做云端 OCR 与多引擎切换。
- 不做多语言界面。
- 不做分发与公证，用 ad-hoc 签名，本机自用。

## 构建

    ./build.sh

产物在 `Build/Yaosnap.app`。构建脚本会自动探测本机的 `.env-tools/swiftc-manifest` 兼容层（存在时使用），并使用 ad-hoc 签名，适用于本机自用。

## 运行

    open Build/Yaosnap.app

应用以菜单栏常驻方式运行（`LSUIElement`，没有 Dock 图标）。菜单栏图标提供「截图」与「退出 Yaosnap」。

## 权限

首次使用需要 **屏幕录制** 权限：

1. 按 ⌃⇧A（Control+Shift+A）或点击菜单栏「截图」，应用会提示需要权限。
2. 打开 系统设置 → 隐私与安全性 → 屏幕录制，勾选 Yaosnap。
3. 完全退出并重启 Yaosnap，权限才完全生效（TCC 行为）。

不需要辅助功能或输入监控权限。热键基于 Carbon `RegisterEventHotKey`。

## 使用（P1）

- **⌃⇧A**（Control+Shift+A）：开始截图，其他应用在前台时同样生效
- **F1**：备用热键。Apple 键盘默认处于媒体键模式时物理 F1 产生的是亮度事件而非 `kVK_F1`，热键不会触发（本机 fn+F1 实测亦无效）；如需使用请到 系统设置 → 键盘 → 勾选“将 F1、F2 等键用作标准功能键”。日常请用 ⌃⇧A。
- **拖拽**：自由选区，正向、反向拖拽都可以，选区旁实时显示尺寸
- **悬停窗口**：蓝框高亮，单击吸附整个窗口，按下后拖拽则改为自由选区
- **Enter 或双击**：复制选区到剪贴板
- **⌘S 或保存按钮**：保存为 PNG，默认桌面，文件名 `Yaosnap_yyyy-MM-dd_HH-mm-ss.png`；⇧ 点击保存或 ⌘⇧S 直接写快捷保存目录（默认 `~/Pictures/Yaosnap`），不弹面板
- **Esc**：取消，覆盖层全部消失

## 开发

    ./build.sh
    ./.env-tools/run-tests.sh

本机 CommandLineTools 自带的 PackageDescription 较旧，直接运行 `swift build` 或 `swift test` 会因 `swiftLanguageMode` 报错。`build.sh` 会自动探测 `.env-tools/swiftc-manifest` 兼容层，`run-tests.sh` 另外补上 swift-testing 插件参数。`.env-tools/` 是本机私有目录，已 gitignore。

P1 验收（性能基准 + E2E，含截图证据）：

    ./Tools/verify/run-p1-e2e.sh

验收记录见 [2026-10-24-yaosnap-p1-verification.md](docs/superpowers/plans/2026-10-24-yaosnap-p1-verification.md)。

## 结构

- `Sources/YaosnapCore/`：坐标换算、屏幕捕获、窗口检测、裁剪与 PNG、剪贴板、热键管理器，可单测
- `Sources/Yaosnap/`：AppKit 壳，包含菜单栏、覆盖窗口与截图控制器
- `Tests/YaosnapCoreTests/`：单元测试
- `Tools/verify/`：P1 验收 harness
- `Resources/Info.plist`：app 打包配置

零第三方依赖，最低支持 macOS 12。
