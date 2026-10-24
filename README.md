# Yaosnap

macOS 原生截图工具（自用），对标 Snipaste 2 Pro。P1 完成截图核心：全局热键、冻结覆盖层、拖拽与窗口吸附选区、复制与保存。

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
- **⌘S**：保存为 PNG，默认桌面，文件名 `Yaosnap_yyyy-MM-dd_HH-mm-ss.png`
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
