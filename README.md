# Mac 脉搏 · MacPulse

**保留常用软件，找出电脑正在忙什么。**

MacPulse is a local-first performance monitor for Apple Silicon Macs. A small desktop orb shows CPU, memory, temperature and disk activity; expand it for process explanations, gentle optimization steps and microphone/camera usage observations.

[下载应用 / Download](https://github.com/CyberWilliam2000/MacPulse/releases/latest) · [反馈问题](https://github.com/CyberWilliam2000/MacPulse/issues) · [MIT License](LICENSE)

## 下载与安装

- 支持 Apple Silicon（M 系列）Mac，macOS 14 或更高版本；部分麦克风状态接口需较新系统支持。
- 从 Releases 下载 `MacPulse-0.8.0-AppleSilicon.zip`，解压后把 `MacPulse.app` 拖到「应用程序」，双击启动。
- 默认显示桌面小球；点击小球展开，拖动移动。菜单栏也有展开、设备查询和退出入口。
- 本版本使用本地临时签名，**尚无 Developer ID 签名与 Apple 公证**。首次下载运行可能被 macOS 拦截。请核对下载来源和 SHA-256；公司受管设备请遵循 IT 政策。了解提示含义与处理方式，请阅读 [Apple 官方说明](https://support.apple.com/102445)。
- 应用没有自动更新；更新时退出旧版，再替换应用包。本地记录独立保存在用户目录。

## 能做什么

- **桌面小球**：上 CPU、下内存、左温度、右磁盘。正常为自然草绿色；检测到压力信号时变橙色。内存状态升高显示「很努力」。
- **细化优化建议**：默认保留 GPT、微信等常用应用。按实际占用建议处理闲置预览、额外窗口、后台页面、文件传输或并行本地任务。主按钮打开应用，整应用退出收在「其他」中。
- **比较效果**：调整前点「比较效果」，再只做一项小调整。约 30 秒后对比内存、CPU、交换速率及热压力；这是观测对比，不是因果证明。
- **任务解释**：按用途解释主程序、页面/界面、图形、音频、视频采集、存储等模块。点进程看最近约 24 秒的变化、处理建议和识别依据。
- **摄像头与麦克风**：每两秒被动读取设备状态。麦克风显示可识别的应用、进程、PID 与输入设备；在同一启动身份匹配时关联进程。iPhone 作为麦克风使用时会提示检查应用输入设置。
- **卡顿记录**：点「刚刚卡了」保存前面最多五分钟的采样和资源占用较高的进程。
- **本机问诊**：根据本机采样与规则回答「谁占内存」「为什么发热」「先调整什么」，不调用远端模型。

## 数据与权限

应用自身不发起网络请求，无账号、无遥测，无音视频录制。不自动更改输入设备、隐私权限或应用设置。打开应用与正常退出仅在用户点击时发起，不强杀辅助进程。

- 连续性能样本留在内存；手动记录保存到 `~/Library/Application Support/MacPulse/incidents.json`。
- 设备使用记录保存到 `~/Library/Application Support/MacPulse/privacy-history.json`，保留最近 30 天、最多 500 条。
- 记录可能含应用名、进程名、PID、设备名及时间；分享反馈前请检查和脱敏。音视频内容、完整命令行、环境变量和聊天正文不写入记录。
- 不需要管理员权限。受限终端、沙盒或硬件差异可能导致部分状态不可读；界面会标出未知或不完整。

## 读数的边界

- 高占用不直接等于卡顿原因。内存结合压力和正在发生的交换判断；磁盘吞吐高不直接等于磁盘等待。
- CPU 100% 约为占满一个逻辑核心；当前没有 GPU 使用率。
- 温度是可读取的最高 PMU tdie 内部探头值，并非机壳温度、核心热点或官方降频阈值。没有读数时显示 macOS 热压力。
- 进程类型只能解释模块用途；无法可靠对应具体文档、聊天或浏览器标签页。未知类型会标明未知或名称推测。
- 音视频服务存在不代表正在采集。摄像头目前只能显示设备状态，无法可靠识别调用应用；请结合 Mac 菜单栏隐私指示点核对。
- 设备历史从应用运行后开始，只记录首次/最后观测，不还原过去完整历史；短于两秒的使用可能遗漏。睡眠、退出或读取中断不会推断精确停止时间。

## 从源码构建

需要 Apple Silicon Mac 和 Xcode Command Line Tools：

```sh
bash test.sh
bash build.sh
open MacPulse.app
```

没有第三方运行时依赖；使用 Swift、SwiftUI、AppKit、C 和 macOS 系统框架。温度探头依赖可选的动态解析系统符号，系统更新后可能不可用，此时保留热压力读数。

```sh
./MacPulse.app/Contents/MacOS/MacPulse --probe
./MacPulse.app/Contents/MacOS/MacPulse --privacy-probe
./MacPulse.app/Contents/MacOS/MacPulse --tasks-probe Lark
./MacPulse.app/Contents/MacOS/MacPulse --dashboard
./MacPulse.app/Contents/MacOS/MacPulse --privacy
bash package.sh
```

打包结果写入 `dist/`。目前只在开发机验证过，尚未覆盖不同型号与所有系统版本；欢迎提交兼容性反馈。

## 参与和许可

欢迎提交 Issue 或 PR，见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题见 [SECURITY.md](SECURITY.md)。

以 [MIT 协议](LICENSE) 开源，允许个人和公司修改、商用及再分发，并保留版权和许可声明。
