# Loom 工程交接

> 状态：**当前有效**
> 更新日期：**2026-10-29**
> 仓库：https://github.com/ReachGa0/YinYou-Loom · 分支 `main`
> 最新提交：查看 `git log -1`
> **作品提交截止：2026-11-04 18:00**

## 0. 新对话 30 秒启动

新对话按 `AGENTS.md` 第六节执行：

1. 完整读本文件；
2. 核对 `README.md`「当前进度快照」、`docs/04`、`docs/06`、`docs/16`；
3. 向用户复述：**当前阶段 / 角色 / 已完成 / 下一步 / 禁止事项**；
4. **等用户确认后**再动手；写代码前先讲思路，用户说“可以”才写。

新对话最短上下文：

> P5 交互层已完成 8 键 PCB、MODE 四档、TONE 四档、FX 四档
> `DRY/CHORUS/DELAY/REVERB`、X 弯音和
> Y 力度/持续表情；P5D 输入语义已闭环。R3 测试模式已接顶层并通过综合，
> 实机启停和多路发声符合预期；精确谱峰计数与 ≤10ms 延迟因无仪器暂缓。
> E1 32 复音和 32 路测试音已实机确认。完整演示采用李萨如显示，
> Flash 写入并校验成功，上电自动加载尚待明确确认；REVERB 实机持续噪声未解决。

## 1. 项目一句话

**吟游 Loom**：运行在 Sipeed Tang Nano 20K（GW2AR-LV18）上的 FPGA 实时多音色合成器。
音频生成链路全部由 HDL 逐声部、逐样本完成，不使用 MCU 参与功能，不使用预录 PCM。

## 2. 一页看懂当前状态

| 项目 | 当前值 |
|---|---|
| 阶段 | **P6 验证 / E1 32 复音已完成**（载板 v0 并行推进） |
| 角色 | **角色 D · 性能架构师 + 角色 F · 验证工程师** |
| 完整演示位流 | `lissajous_demo`，**User Code = 0x0000EEBA**；外部 Flash 写入与校验成功，上电加载待明确确认 |
| 硬件 | 自制 8 键 PCB + 2.4″ TFT + HW-504 摇杆（外接 RC） |
| 已验证（实机/仿真/综合） | 7 音名 + MODE、4 音色、DRY / CHORUS / DELAY、Pitch Bend、持续表情、拨弦、R3、32 声部；REVERB 有实机噪声 |
| 当前测量缺口 | ≤10ms 延迟无仪器暂缓；32 峰实机精确计数不能可靠确认 |
| E1 状态 | ✅ 32 声部、32 路测试音、当前位流实机确认 |
| FX 状态 | 当前 REVERB 发音后出现撕裂及持续噪声；其他三档用户反馈正常，根因未确定 |
| 进阶缺口 | E2 第 3 维 + 滑音/扫弦 / E3 ≤5ms+完整视觉 / E4 |
| 显示 | 独立 `lissajous_demo` 左侧音频相位轨迹、右侧菜单；分块刷新后用户反馈改善 |

## 3. 已完成（不要重做）

| 项 | 证据 |
|---|---|
| P0–P4、四声部上板 | `docs/04`、P4 位流与实测记录 |
| P5A 按键 + 消抖 + 多声部归一化 | 实机四键、混音不破音 |
| 2.4″ TFT（PIN71–76） | `docs/22`，屏参 12MHz / MADCTL 0xA0 / 反显关 |
| 8 键 PCB | 用户 2026-10-23 实机确认全部正常 |
| MODE 四档 | ONE / TRI / PLUCK ONE / PLUCK TRI，含一次性拨弦包络 |
| TONE 四档 | SINE / SQUARE / SAW / TRIANGLE |
| FX 四档 | DRY / CHORUS / DELAY / REVERB |
| 摇杆 RC 链路 | `rc_adc.v` + `pitch_bend_map.v`；X 弯音、Y 表情均实测有效 |
| 摇杆去尖峰 | `joy_filter.v` 3 点中值 + 一阶低通；`tb_joy_filter` PASS |
| 力度 / 表情语义 | `expression_map.v`：note-on 力度与持续 expression 分离；`tb_expression_map` PASS |
| R3 集成 | `test_mode_router.v` + `test_mode.v` 接 `p6_test_demo`；PIN25 切换 |
| E1 32 复音 | 32 声部分配、顺序混音、32 个质数频率、共享弯音乘法；32 峰频谱仿真通过 |
| FX 扩展 | `fx_engine.v` 在单块 16384×16 BSRAM 上复用 CHORUS / DELAY / REVERB；模式切换先清空并渐变 |
| 回归 | 2026-10-29 全量 **51/51 PASS**，含 REVERB 诊断测试。仿真通过不代表 REVERB 实机正常 |
| 综合 | 完整演示 `lissajous_demo`：Logic 12620/20736、Register 7048/15750、BSRAM 33/46、DSP 21/24；setup/hold 0/0 |

## 4. 当前缺口

### 4.1 基础要求

| 项 | 状态 |
|---|---|
| 选音 / 触发 / 拨弦 / 力度 | ✅ |
| ≥2 独立维度 | ✅ Pitch Bend + 持续表情 |
| 纯 HDL 逐样本合成 | ✅ |
| ≥4 复音、ADSR、混音、无 PCM | ✅ |
| **≤10ms 延迟** | ❌ **未实测**；按键消抖 10ms 是主要风险 |

### 4.2 进阶要求（详见 `docs/03` 第三节）

| 编号 | 要求 | 当前 | 建议 |
|---|---|---|---|
| **E1** | ≥32 复音 / ≥32 加法分量 / 多条物理建模（三选一） | ✅ 32 复音；32 路仿真谱峰，32 声部实机已确认 | 补仪器级谱峰证据 |
| E2.1 | ≥3 维表情 | 2 维 | 用变阻器加第 3 维（颤音深度/滑音时间） |
| E2.6/7/8 | 混响 / 延迟 / 合唱 | 已实现；当前 REVERB 实机有持续噪声 | 诊断或重做，未经用户确认暂不开始 |
| **E3** | ≤5ms、无抖动、可视化 | 李萨如相位轨迹独立工程已上板；延迟、LED、频谱仍缺 | 补证据与低成本视觉 |
| E4 | 脱机 LED 曲目指引；蓝牙/App 可选 | 无 | LED 指引可做；蓝牙放弃 |
| **R3** | 测试模式多频输出 + 独立谱峰 | 32 路仿真、实机启停和多路发声通过 | 精确计数待仪器 |

## 5. 新对话建议从这里开始

> **总方向已确认**：后续按
> [`docs/24_未完成需求清单.md`](docs/24_未完成需求清单.md) §3 的四批顺序执行：
> 第一批 1–15 → 第二批 16–21 → 第三批 22–26 → 第四批 27–31。
> 第一批 1–13 已完成，14 因无仪器暂缓，12/15 缺仪器级证据；
> 第二批 16–20 已完成；21 项仍待当前 32 声部位流的仪器级谱峰与吞吐量证据。

**当前状态：完整演示已写入 Flash；REVERB 实机噪声尚未解决**

1. 三种湿效果共用一块 BSRAM，BSRAM 从 43 降到 32；
2. 模式切换先输出干声并清空共享区，避免旧尾音串入；
3. 混响采用 1/4 注入、约 0.625 反馈、半干半湿输出；相关削波测试通过，但实机仍有噪声；
4. 用户观察：首音后噪声持续，退出并重新进入 REVERB 后安静；无反馈后松键噪声消失，单独湿声及四条抽头均有撕裂。干声正常；板载参考比较器按键后报告不一致，根因尚未确定。

**下一批：22–26**

- E2 第 3 维优先，其次独立滑音或扫弦；
- 李萨如独立演示已上板，用户反馈优化后流畅度改善；LED 指引仍待做；
- ≤5 ms/延迟和 32 峰硬件计数按仪器条件暂缓；用户讨论过重做混响，但明确说先不开始。

> 测量口径：当前没有逻辑分析仪/示波器，≤10ms 延迟暂缓；R3 实机已有
> “多路测试音符合预期”的主观结果，但无法可靠数出峰数。逐音 note-on
> 力度差异对比已由用户明确取消。

## 6. 边界与禁止

1. 先讲思路，等“可以”再写代码。
2. 不改 `rtl/loom_top.v`，除非用户针对该文件明确授权。
3. 音频链路改动必须单独说明并跑回归；输入/显示增量先走独立工程。
4. PCB 在嘉立创EDA（`Loom_Carrier`）；`PCB/carrier_v0/*.kicad_pcb` 只作历史参考。
5. TFT 独占 PIN71–76；旧 I2C OLED 不进入最终方案。
6. 载板 GND/3V3 靠内层铺铜，不画走线。
7. 摇杆只用 **3.3V** 供电；VRX/VRY 必须经 RC，不能直连 FPGA。
8. 禁止 `git reset` / `git checkout --` / `git clean` / 回退现有改动。

## 7. 硬件与引脚

### 7.1 当前生效引脚

| 功能 | 网络 | FPGA 引脚 |
|---|---|---:|
| 音名键 K1–K4 | `key_n[3:0]` | 28 / 29 / 30 / 31 |
| 音名键 K5–K7 | `key_n[6:4]` | 77 / 85 / 86 |
| MODE 键 | `key_mode_n` | **27** |
| R3 测试模式 | `key_level_n` | **25** |
| 摇杆 X/Y（RC） | `joy_x` / `joy_y` | **48 / 49** |
| TFT | `tft_*` | 71–76 |
| I2S / PA | `audio_*` | 54 / 55 / 56 / 51 |
| 板载 S1 / S2 | `key_timbre_n` / `key_fx_n` | 88 / 87 |

### 7.2 摇杆 RC（每轴）

```
VRX ──[100k]──┬── PIN48
              ├──[47k]── 3V3
              └──[100nF]── GND
```

VRY 同理 → PIN49。摇杆 `+5V` 丝印接 **3V3**。

当前参数：计数 4.5MHz（72MHz/16）、放电 200µs、超时 12ms、中位约 4200、
`SPAN_LEFT=1200`、`SPAN_RIGHT=780`、弯音 ±1 半音、3 点中值 + 一阶低通 +
开机自动对中。Y 轴拆分为 note-on `velocity` 与持续 `expression`。

## 8. 固件 / 构建 / 烧录

**完整演示的 Flash 状态（2026-10-29）**：`fpga/lissajous_demo/impl/pnr/lissajous_demo.fs`，User Code `0x0000EEBA`，SHA256 `91AA94E95F9F1CA5502001BE7954792C43034336A17CF7D406249D098A9B0371`。外部 Flash ID `0x0B4017`，地址 0 写入及校验成功；断电自动加载尚未明确确认。REVERB 噪声未解决。构建方式见 [`fpga/lissajous_demo/README.md`](fpga/lissajous_demo/README.md)。

以下命令和数据是 P6 基线的历史记录，不是当前 Flash 位流。

```powershell
# 综合 + 布局布线
& "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" tmp/build_p6_test_demo.tcl

# 烧录（SRAM，断电丢失）
& "C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe" `
  -d GW2AR-18C -r 2 --fsFile `
  "C:\Users\ReachGao\Desktop\CodeX\loom\fpga\p6_test_demo\impl\pnr\p6_test_demo.fs"
```

- 当前版本 Logic 12436/20736、Register 6977/15750、BSRAM 32/46、
  DSP 21/24，setup/hold 0 违例，最差 setup slack `+0.365 ns`。
- 位流 SHA256：
  `376C5A9E7DF0C7231C5AC142813B3EA116D385B7AB927C36F9E8E9526693D539`。
- 2026-10-25 烧录读回：`User Code = 0x000000D7`、
  `Status Code = 0x00006020`。
- **`DEBUG_JOY=0`**，正式波形 UI 已恢复。

## 9. 关键设计决策

- **取消超声波**（2026-10-23）：赛题不强制；摇杆 Y 承担力度/动态。
- **不用 ADS1115**：摇杆用 FPGA-only RC 测时。
- **MODE 四档**：ONE / TRI / PLUCK ONE / PLUCK TRI；拨弦是包络，不是分解和弦。
- **拨弦一次性**：sustain=0，约 340ms 自然衰减；按住不放也自动释放，不占声部。
- **持续表情**：Y 轴直接控制混音后增益（0.1–1.0），按住音也能实时变化。
- **note-on 力度**：按下瞬间的 Y 值进入 synth_engine，由目标声部锁存；
  expression 与逐音力度不再混为一条语义。
- **R3 测试模式**：PIN25 切换，先等正式声部空闲，测试音独占事件入口，
  退出时等测试音释放后恢复演奏。
- **32 声部资源策略**：逐音增益乘法移入 mixer 顺序累加；弯音由
  `bend_scan.v` 共享一个乘法器逐声部扫描，避免复制 32 份乘法链。
- **TONE 四档**；**FX 四档 = DRY / CHORUS / DELAY / REVERB**；
  音色补偿 SINE/TRI 1.0、SQUARE 0.5、SAW 0.75。

## 10. 已知问题 / 技术债

| 问题 | 说明 |
|---|---|
| 摇杆低位噪声 | 3 点中值去尖峰 + 一阶低通已通过当前位流实机检查 |
| ≤10ms 延迟 | 当前无仪器暂缓；不得用估算值代替，也不急于修改消抖 |
| R3 实机证据 | 当前 32 声部位流启停、TFT TEST、LED 和多路发声已确认 |
| `docs/13` 旧产品形态 | 五度环/12 扇区已被 7 键方案取代，需在 P5D 统一 |
| 32 复音实机验证 | 用户已确认此前 32 声部位流正常；完整演示继续使用该音频链路 |
| REVERB 噪声 | 当前位流首音后持续撕裂；无反馈仅停止持续，单独湿声和四路均有噪声；数字比较器曾锁存不一致，完整根因未确定 |
| 时序余量 | P6 基线最差 setup slack `+0.365 ns`；独立完整演示 setup/hold 0/0，后续 RTL 改动必须重新综合 |

### 踩坑记录（详见 `docs/19` 案例 21–25）

1. Verilog 乘法结果宽度按最大操作数，必须用足够宽的中间量；
2. 单周期 `valid` 不能当持续使能，否则弯音每毫秒回中；
3. `voice.v` 的增益 `case` 只认 4 个 A 加权常量，力度会落到 default=1.0；
4. 10µF 电容让 RC 时间常数大 1000 倍，永远超时；
5. 调试文字列号必须按 8px 字格，已改用二进制方块显示。

## 11. 文件地图

| 文件 | 作用 |
|---|---|
| `rtl/p6_test_demo_top.v` | P6 基线顶层（按键/摇杆/TFT/合成） |
| `rtl/lissajous_demo_top.v` | 当前完整演示独立顶层；Flash 使用该位流 |
| `rtl/display/lissajous_capture.v` / `ui_lissajous_render.v` | 单声道延迟相位轨迹与右侧菜单、分块刷新 |
| `fpga/reverb_*_probe/` | 无反馈、干湿分量、单抽头和板载比较诊断；仅供诊断 |
| `rtl/input/rc_adc.v` | RC 测时采集 |
| `rtl/input/joy_filter.v` | 摇杆 3 点中值 + 一阶低通 |
| `rtl/input/expression_map.v` | Y 轴 note-on 力度与持续 expression |
| `rtl/input/pitch_bend_map.v` | 弯音映射（自动对中值输入） |
| `rtl/input/input_map.v` / `chord_map.v` | 7 键音名 / 7 个自然三和弦 |
| `rtl/synth/voice_adsr.v` | ADSR + 一次性拨弦 |
| `rtl/synth/voice.v` / `synth_top.v` / `synth_engine.v` | 合成链路（弯音/力度/拨弦） |
| `rtl/synth/chorus.v` | 单抽头合唱（DRY/CHORUS） |
| `rtl/synth/delay_effect.v` | 约 250 ms 反馈延迟 |
| `rtl/synth/reverb_effect.v` | 四路短反馈混响 |
| `rtl/synth/fx_engine.v` | P6 四档效果、共享 BSRAM、切换清空与渐变 |
| `rtl/synth/mixer.v` | 32 声部归一化；增益乘积增加一级流水，保证时序 |
| `rtl/display/ui_render.v` / `tft_st7789.v` | TFT UI 与驱动 |
| `rtl/display/wave_capture.v` | 真实采样抓取（波形显示，当前调试页接管） |
| `rtl/test/test_mode.v` | R3 32 路质数相干测试音 |
| `rtl/test/test_mode_router.v` | R3 进入/退出握手与音频源切换 |
| `docs/25_P6集成与验收指南.md` | RTL 路径、硬件装配、延迟与谱峰验收 |
| `docs/26_提交材料检查表.md` | 最终提交前检查 |
| `fpga/p6_test_demo/` | P6 基线工程 |
| `fpga/lissajous_demo/` | 完整演示工程、构建脚本与当前 Flash 位流来源 |

## 12. 维护规则

- 完成阶段 / 改变冻结决策后，同步 `HANDOFF.md`、`README.md` 和对应专项文档；
- 本文件保持“接手所需”，细节下钻 `docs/`；
- 每次更新后跑 `git diff --check`，新加链接要有效。
