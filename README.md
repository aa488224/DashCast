# DashCast

把 iPhone 上的 CarPlay 画面，接到一台旧 iPhone / iPad 上当**第二屏**。

为 iOS 15 的老设备（iPhone 6s Plus、iPhone 7 等）写的原生接收端：不依赖浏览器，不需要 WebCodecs / MSE，用系统 `AVSampleBufferDisplayLayer` 做 H.264 硬解，A9 也能跑。

> 只负责“接收 + 解码 + 显示 + 回传触控”，不创建 CarPlay 会话，不修改任何系统设置。

## 依赖说明（重要）

这个 App **不能单独工作**。CarPlay 画面是 iPhone 的 iOS 渲染并编码出来的，只有“被 iOS 认作车机”的那一端才拿得到这路流。iOS 不允许 App 自己开 Wi-Fi 热点当 AP，所以手机端必须有一个 App 顶替车机角色。

目前的链路：

```
iPhone（运行 CarWithin，接住 CarPlay 并编码）
   ↓  ws://<主手机 IP>:9888/stream   局域网
DashCast（本 App：硬解 + 显示 + 触控回传）
```

- 主手机需要运行 [CarWithin](https://github.com/xmz28/CarWithin)（或实现同一输出协议的程序），并把「当前输出」设为「浏览器」、打开「局域网接收页」
- 本 App 面向 **iOS 15**：iOS 15 的 Safari / WebView 没有 WebCodecs、也没有 MSE，浏览器端必然黑屏；这里用 `AVSampleBufferDisplayLayer`（VideoToolbox）硬解，绕开浏览器能力限制
- **WebSocket 只是传输管道，和 WebCodecs 无关**。握手里的 `"decoder":"webcodecs"` 是一个开关，含义是“请发裸 H.264（AVCC），不要发 fMP4 分片”，因为原生解码器要的就是裸 NALU

## 同类开源项目

| 项目 | 端 | 手机端要装 App | 说明 |
| --- | --- | --- | --- |
| [CarWithin](https://github.com/xmz28/CarWithin) | iOS 16+ | 要 | 本项目的上游，一体 + 浏览器输出 |
| [PlayPort](https://github.com/fulin-peng-ydxs/playport) | macOS | **不要** | 协议栈跑在电脑上，蓝牙 + Wi-Fi 让 iPhone 主动连，浏览器当车机 |
| [DiPlay / xcertplay](https://github.com/shihabal3amr/diplay) | Android 车机 | 不要 | 车机端 App 当接收器，需要车机可装 APK |
| Showcase | 越狱 iOS | 不要 | 越狱设备当无线 CarPlay 接收端（BTstack + HCI） |

结论：**不越狱、纯 iOS App、且手机端零依赖** 的现成方案目前没有；能做到零依赖的都要一块能跑协议栈的硬件或越狱环境。

## 它能做什么

- 连接运行 CarWithin（或兼容输出端）的主手机，实时显示 CarPlay 画面
- 横屏全屏、保持比例 / 拉伸铺满（双击切换）
- 单指触控回传，可以直接在第二屏上操作 CarPlay
- 手填 `IP:9888`，或一键扫描同网段自动找主机
- 自动重连、心跳检测、断线提示
- **设置里带完整运行日志**：滚动查看、一键复制、导出文件，方便排查

## 协议

主手机在 9888 端口提供 WebSocket：

```
ws://<主手机 IP>:9888/stream
```

握手（文本帧）：

```json
{"type":"ready","decoder":"webcodecs","viewer":"<uuid>","audioClock":false}
{"type":"display","w":1280,"h":720,"sw":1280,"sh":720,"dpr":1,"hz":60,"h265":false,"fullscreen":true}
```

服务端先回一条 `format`（含 base64 的 avcC），之后是二进制帧：

| 字节 | 含义 |
| --- | --- |
| 1 | 包类型：0 = 差帧，1 = 关键帧 |
| 8 | 大端微秒时间戳 |
| 剩余 | AVCC 样本（4 字节长度前缀的 NALU 序列，参数集在 avcC 里） |

触控回传：

```json
{"type":"touches","points":[{"id":0,"x":0.5,"y":0.5}]}
```

## 使用

1. 主手机和这台设备连**同一个 Wi-Fi**（主手机必须连进 Wi-Fi，不能只开热点）
2. 主手机启动 CarPlay，把输出切到「浏览器」，打开局域网接收页
3. 打开 DashCast，填主手机地址（如 `192.168.1.23`），端口 `9888`
4. 点「连接主手机」，出画面后自动进入全屏横屏

找不到地址时点「查找局域网设备」，会扫同网段的 9888 端口。

## 日志

三个入口，内容一致：

- 主页「使用步骤」卡片 → 查看运行日志
- 导航栏右上角日志图标
- 设置 → 诊断 → 运行日志

日志同时写入 App 沙盒 `Documents/dashcast-receiver.log`，超过 1.5 MB 自动滚动。设置里「复制诊断信息」会把设备、地址、版本和全部日志一起复制，直接粘贴发出来即可。

## 构建

### GitHub Actions（推荐，无需 Mac）

Fork / 上传本仓库，Actions 里跑 `Build DashCast IPA`，下载 `DashCast-unsigned-ipa`，自行签名安装。

### 本地 Xcode

```bash
xcodebuild -project CWR15.xcodeproj -target DashCast -configuration Release \
  -sdk iphoneos ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

产物在 `build/Release-iphoneos/DashCast.app`，打包成 `Payload/` + zip 改名 `.ipa` 即可。

最低系统 **iOS 15.0**，arm64。免费 Apple ID 签名的 App 7 天过期。

## 已知限制

- 只支持 H.264（A9 没有 HEVC 硬解，主端需强制 H.264）
- 当前版本不播放声音（音频包已识别，播放留给后续版本）
- 触控为单指 / 多指基础映射，主端手势识别以 CarPlay 为准
- 主端分辨率建议 1280×720；改动后需重新连接

## 许可

GPL-3.0-or-later。CarPlay 无线协议与画面封装格式的参考实现来自
[CarWithin](https://github.com/xmz28/CarWithin)（GPL-3.0），本项目的接收端与其协议保持兼容。

仅供个人在自有设备上使用。
