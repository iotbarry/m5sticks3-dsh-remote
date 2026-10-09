# DeepSeek Harness 实体遥控器(M5StickC S3)

把一块 **M5StickC S3** 做成 DeepSeek Harness(DSH)的实体遥控器:

- **USB HID 键盘** —— 即插即用,免驱动
- **正面键单击 / 正面键双击 / 按住侧键** 三个动作,对应发送、拒绝、按住说话
- **审批框出现时自动切换屏幕界面** —— 平时只显示名字,需要你决策时才出现按钮
- **触发 DSH 自带语音输入** —— 转写文字直接进输入框,不受输入法影响
- **抗锯齿 OLED 界面** —— 明朝体大字 + 呼吸状态点 + 按键涟漪反馈

```
┌──────────────────────────────┐          ┌──────────────────────────────┐
│       M5StickC S3            │          │      DeepSeek Harness        │
│                              │          │      (Electron / Chromium)   │
│  ┌────────────────────────┐  │          │                              │
│  │      程序猿白瑞         │  │  USB HID │   ┌──────────────────────┐   │
│  │           ◉            │  │ ───────► │   │  输入框 / 会话         │   │
│  └────────────────────────┘  │ 键盘事件 │   └──────────────────────┘   │
│                              │          │                              │
│  正面键 单击 → Enter          │          │   ▲                          │
│  正面键 双击 → Esc            │          │   │ Chromium DevTools 协议   │
│  侧键 按住/松开 → Ctrl+Alt+R │  USB CDC │   │ (读取 DOM,判断审批框)    │
│                              │ ◄─────── │   │                          │
│                              │ ASK/IDLE │   │                          │
└──────────────────────────────┘          └──────────────────────────────┘
                    ▲                                    ▲
                    │ 串口 COMx                          │ 127.0.0.1:9222
                    │                                    │
              ┌─────┴────────────────────────────────────┴─────┐
              │        pc/dsh-cdp-bridge.ps1(PowerShell)      │
              │   轮询页面 DOM → 发现审批框 → 下发 ASK / IDLE   │
              │   转发遥控器组合键 → 点击 DSH 的按钮            │
              └───────────────────────────────────────────────┘
```

---

## 功能一览

### 硬件按键

| 操作 | 发送 | 用途 |
|---|---|---|
| 正面键 **单击** | `Enter` | 发送消息 / 允许 |
| 正面键 **双击** | `Esc` | 拒绝 / 取消 |
| 侧面键 **按住** | `Ctrl+Alt+R` | **开始** DSH 语音录音 |
| 侧面键 **松开** | `Ctrl+Alt+R` | **停止**录音并转写 |
| 侧面键 **长按** | (硬件行为) | 进入下载模式(烧录用)|
| 侧面键 **快速双击** | (硬件行为) | 关机 |

> 单击判定有 **280ms** 延迟(用于区分单击和双击),这是设计如此。

### 屏幕

**正常状态** —— 只有一行字和一个呼吸点,大量留白:

```
                                        
        程 序 猿 白 瑞                    ← 明朝体 32px,字间距 +6px
                                          ← 右下投影 + 1px 描边重绘(加粗)
                    ◉                     ← 呼吸点:绿=已就绪 / 红=未连接
```

**审批状态** —— DSH 弹出审批框时自动切换:

```
         ╭───────╮         ╭───────╮
         │  确认  │         │  拒绝  │      ← 抗锯齿圆角药丸 + 1px 细边
         ╰───────╯         ╰───────╯
```

**按键反馈** —— 药丸整块填充颜色 + 底部光环扩散(语音=红色)。

### 支持的两类 DSH 审批框

| 提示类型 | 按钮文案 |
|---|---|
| 权限提示 `session/request_permission` | **允许一次** / **拒绝** |
| 计划待审 | **同意执行** / **要求修改** |

---

## 硬件

| 项目 | 说明 |
|---|---|
| 设备 | M5StickC S3(ESP32-S3-PICO-1,8MB Flash)|
| 连接 | USB-C 数据线(必须支持数据,不能是纯充电线)|
| 右侧按键 | **GPIO 12** |
| 正面按键 | M5Unified `M5.BtnA` |

---

## 快速开始

### 一、硬件端(烧录固件)

需要 [PlatformIO](https://platformio.org/)。

```bash
# 在仓库根目录下执行
pio run

# 烧录(先按住侧面键进下载模式,直到绿灯闪烁)
pio run -t upload --upload-port COMx
```

烧录后 **双击侧面键关机 → 单击开机**,设备会被识别为:

```
HID Keyboard Device      ← 键盘
USB 串行设备 (COMx)       ← 串口(供桥接脚本使用)
```

### 二、电脑端(桥接脚本)

**1. 用调试端口启动 DSH**

双击 `pc/launch-dsh-a11y.cmd`(它会先关掉再重启 DSH)。

> 为什么必须这样启动:DSH 是 Electron 应用,它的网页内容**对 Windows UI 自动化完全不可见**,
> 只能通过 Chromium 调试协议读取。这个启动器只多加了一个参数:
> `--remote-debugging-port=9222`。

**2. 运行桥接**

```powershell
powershell -ExecutionPolicy Bypass -File "pc\dsh-cdp-bridge.ps1"
```

> ⚠️ **`-ExecutionPolicy Bypass` 不是可选项,是必须的。** 脚本没有数字签名,
> 而 Windows 默认策略是 `RemoteSigned`,直接 `& .\dsh-cdp-bridge.ps1` 会报
> 「未对文件进行数字签名。无法在当前系统上运行该脚本」。
> 详见下面的[第 9 个坑](#9-windows-执行策略会拦截未签名的-ps1)。

看到这样的输出就说明连接成功:

```
remote serial port : COM13
DSH debug port     : 9222

00:34:17  -> IDLE
```

**3. 日常使用**

```
按住侧面键  →  DSH 开始录音(屏幕亮起红色光环)
说话        →  松开侧面键  →  停止录音并转写
            →  文字进输入框  →  单击正面键发送
```

### 桥接脚本参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Port` | 自动检测 | 遥控器串口(优先选 `MI_01`,避开 ROM 的 `MI_00/MI_02`)|
| `-CdpPort` | `9222` | DSH 调试端口 |
| `-ConfirmJs` | `允许\|同意\|批准\|确认\|allow\|approve\|…` | 确认按钮匹配规则 |
| `-RejectJs` | `拒绝\|要求修改\|取消\|驳回\|deny\|reject\|…` | 拒绝按钮匹配规则 |
| `-PollMs` | `400` | 轮询间隔 |
| `-Discover` | — | 只列出页面上的按钮,不改状态(排查用)|

示例 —— 自定义快捷键:

```powershell
powershell -ExecutionPolicy Bypass -File "pc\dsh-cdp-bridge.ps1" `
    -ConfirmJs "允许|同意" -RejectJs "拒绝|取消"
```

---

## 踩过的坑

这个项目踩了一串很深的坑,记录下来省得别人重走:

### 1. Arduino ESP32 核心:`press()` 发不出修饰键(最深的坑)

```c
// libraries/USB/src/USBHIDKeyboard.cpp
size_t USBHIDKeyboard::press(uint8_t k) {
    } else if (k >= 0x80) {          // 修饰键
        _keyReport.modifiers |= (1 << (k - 0x80));
        k = 0;                        // ← 把自己置 0
    }
    return pressRaw(k);               // → pressRaw(0)
}

size_t USBHIDKeyboard::pressRaw(uint8_t k) {
    ...
    } else {
        return 0;                     // ← 0 落到这里,报告根本不发
    }
    sendReport(&_keyReport);
}
```

**后果**:`Ctrl` / `Alt` / `Win` / `Shift` **从未被发送**。
回车、字母这类普通键走另一条分支,所以看起来"键盘是好的"。

**修复**:绕过 `press()`,直接传 HID usage:

```c
Keyboard.pressRaw(0xE0);   // 左 Ctrl
delay(12);
Keyboard.pressRaw(0xE2);   // 左 Alt
delay(12);
Keyboard.press('r');       // 普通键,这条路是好的
delay(28);
Keyboard.releaseAll();
```

### 2. USB-OTG 模式下核心不创建 CDC 实例

```c
// cores/esp32/USBCDC.h
#if ARDUINO_USB_CDC_ON_BOOT && !ARDUINO_USB_MODE   // ← 必须 USB_MODE=0
extern USBCDC Serial;
#endif
```

做 HID 必须 `ARDUINO_USB_MODE=1`,于是 **`Serial` 变成了硬件串口 UART0,CDC 根本不存在**。

**修复**:自己声明一个实例 —— `USBCDC` 的**构造函数**里就会调用 `tinyusb_enable_interface` 注册接口:

```c
#include "USBCDC.h"
static USBCDC UsbSerial(0);   // 构造即注册,无需其他操作
```

### 3. M5StickC S3 的右侧按键不在 M5Unified 的按键表里

M5Unified 对该板子的按键是通过 **PMIC(M5PM1,I2C 0x6E)** 读的,`M5.BtnB` 拿不到右侧按键。

**修复**:直接读 **GPIO 12**(开机时自校准空闲电平,不假设高/低有效):

```c
static const int PIN_SIDE = 12;
pinMode(PIN_SIDE, INPUT_PULLUP);
for (int i = 0; i < 20 && digitalRead(PIN_SIDE) == LOW; i++) delay(50);
sideIdleLevel = digitalRead(PIN_SIDE);
```

### 4. Electron 的网页内容对 UI 自动化不可见

DSH 窗口对 `UIAutomation` 只暴露 2 个节点(`Chrome Legacy Window` 占位),
`--force-renderer-accessibility` 也无效(Electron 需要应用自己调 API)。

**修复**:改用 **Chromium DevTools 协议**,用 `--remote-debugging-port=9222` 启动,
直接 `Runtime.evaluate` 读 DOM。

### 5. 波形一样的按键事件,时序却不同

遥控器发 `Ctrl+Alt+R` 三个事件间隔 **约 0ms**,真实键盘是人的 **~150ms**。
如果防抖只在**分支匹配前**判断,修饰键会占据防抖名额,把真正触发条件的 `r` 吃掉。

**修复**:防抖只在**条件匹配之后**生效。

### 6. PowerShell 脚本必须带 UTF-8 BOM(或纯 ASCII)

Windows PowerShell 5.1 把**无 BOM** 的 `.ps1` 按 **ANSI** 解析,中文全部乱码 → 语法错误。

**修复**:脚本写成**纯 ASCII**,中文用 `\uXXXX` 转义写进正则:

```powershell
# \u5141\u8bb8 = 允许
[string] $ConfirmJs = "\u5141\u8bb8|\u540c\u610f|allow|approve"
```

### 7. USB-Serial-JTAG 复位必定进下载模式

ESP32-S3 的 `rst:0x15 (USB_UART_CHIP_RESET)` 会让芯片进入下载模式 ——
应用没运行时,esptool 的任何复位都只是把它再送回下载模式,**应用永远起不来**。

**修复**:烧录完必须**真正断电重上电**(双击侧键关机 → 单击开机)。

### 8. 烧录前要先关掉桥接脚本

桥接会一直占着串口,esptool 打不开端口 → `OSError 22 / PermissionError`。

### 9. Windows 执行策略会拦截未签名的 PS1

直接运行桥接脚本时:

```
& : 无法加载文件 E:\...\pc\dsh-cdp-bridge.ps1。未对文件进行数字签名。
无法在当前系统上运行该脚本。
    + FullyQualifiedErrorId : UnauthorizedAccess
```

原因:执行策略是 **`RemoteSigned`**(用 `Get-ExecutionPolicy -List` 查看),
它要求**从网络下载的**脚本必须有数字签名。注意:即使文件**没有** `Zone.Identifier`
标记(用 `Get-Item <file> -Stream Zone.Identifier` 可查),在非系统盘、
同步盘或某些企业策略下,PowerShell 仍可能把它判定为"来自远程"。

**三种放行方式**,按推荐顺序:

```powershell
# 方式一(推荐):只为这一次调用放行,完全不动系统设置
powershell -ExecutionPolicy Bypass -File "pc\dsh-cdp-bridge.ps1"

# 方式二:给单个文件解锁(之后可直接 & 运行)
Unblock-File .\pc\dsh-cdp-bridge.ps1

# 方式三:只在当前会话进程内放行(想在已有 pwsh 里 & 运行脚本时用)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

> ❌ **不要**用 `Set-ExecutionPolicy LocalMachine Unrestricted` —— 那会全局降低
> 系统安全性,得不偿失。

---

## 工程结构

```
m5sticks3_usbkbd/
├── platformio.ini           PlatformIO 配置
├── partitions.csv           分区表(nvs + 3MB app)
├── src/
│   └── main.cpp             固件全部逻辑(约 320 行)
└── pc/
    ├── launch-dsh-a11y.cmd  带调试端口启动 DSH
    └── dsh-cdp-bridge.ps1   桥接脚本
```

### 固件关键参数

| 常量 | 值 | 说明 |
|---|---|---|
| `PIN_SIDE` | `12` | 右侧按键 GPIO |
| `TITLE_PX` / `TITLE_TRACK` | `32` / `6` | 名字字号 / 字间距 |
| `PILLS[]` | 84×38 @ (30,46) (126,46) | 两个药丸的位置尺寸 |
| 正面键单击判定窗口 | `280 ms` | 区分单击/双击 |
| 侧键录音触发阈值 | `250 ms` | 按住超过才开录,防误触 |

---

## 已知限制

- **语音走 DSH 自带录音**(`sensevoice` 本地模型),不依赖 Windows 听写 —— 因为
  DSH 用 Lexical 富文本编辑器,外部注入的文字不会同步到它的状态。
- **单击有 280ms 延迟**,这是区分单击/双击的代价。
- **侧键要按住 250ms 才开始录音**,松手即结束并转写 —— 说话开头别太急。
- **桥接脚本必须运行**才能自动切换界面和转发组合键;不跑也能用,
  只是屏幕停在名字界面。
- DSH 重启后需要**重新运行桥接脚本**(它会自动重装页面内的按键映射)。
- 键盘事件有时会重复 2~3 次(USB 层特性),桥接已用 **150ms 防抖**处理。

---

## 许可

未指定。使用前请自行确认与 DeepSeek Harness 的服务条款不冲突。
