# Loom 工程交接

> 状态：**当前有效**
> 更新日期：**2026-10-24**
> 仓库：https://github.com/ReachGa0/YinYou-Loom · 分支 `main`
> 最新提交：`67c8d68`（已推送，工作区干净）
> **作品提交截止：2026-11-04 18:00（剩 11 天）**

## 0. 新对话 30 秒启动

新对话按 `AGENTS.md` 第六节执行：

1. 完整读本文件；
2. 核对 `README.md`「当前进度快照」、`docs/04`、`docs/06`、`docs/16`；
3. 向用户复述：**当前阶段 / 角色 / 已完成 / 下一步 / 禁止事项**；
4. **等用户确认后**再动手；写代码前先讲思路，用户说“可以”才写。

新对话最短上下文：

> P5 交互层已完成 8 键 PCB（7 音名 + MODE 键）、MODE 四档（含单音/和弦拨弦）、
> TONE/FX 各 4 档、摇杆 FPGA-only RC（X 弯音、Y 持续表情）；超声波取消。
> 基础要求只剩 ≤10ms 延迟未实测。进阶优先做 R3 测试模式 + E1 32 复音。

## 1. 项目一句话

**吟游 Loom**：运行在 Sipeed Tang Nano 20K（GW2AR-LV18）上的 FPGA 实时多音色合成器。
音频生成链路全部由 HDL 逐声部、逐样本完成，不使用 MCU 参与功能，不使用预录 PCM。

## 2. 一页看懂当前状态

| 项目 | 当前值 |
|---|---|
| 阶段 | **P5 交互层**（载板 v0 并行推进） |
| 角色 | **角色 E · 硬件工程师** |
| 固件 | `p6_test_demo`，**User Code = 0x000093A9** |
| 硬件 | 自制 8 键 PCB + 2.4″ TFT + HW-504 摇杆（外接 RC） |
| 已验证 | 7 音名 + MODE 键、4 音色、4 效果、Pitch Bend、持续表情、拨弦 |
| 基础缺口 | **≤10ms 延迟未实测** |
| 进阶缺口 | E1 32 复音 / E2 第 3 维+延迟+混响 / E3 视听 / R3 测试模式集成 |
| 工作区 | 干净；`main...origin/main` 同步 |

## 3. 已完成（不要重做）

| 项 | 证据 |
|---|---|
| P0–P4、四声部上板 | `docs/04`、P4 位流与实测记录 |
| P5A 按键 + 消抖 + 多声部归一化 | 实机四键、混音不破音 |
| 2.4″ TFT（PIN71–76） | `docs/22`，屏参 12MHz / MADCTL 0xA0 / 反显关 |
| 8 键 PCB | 用户 2026-10-23 实机确认全部正常 |
| MODE 四档 | ONE / TRI / PLUCK ONE / PLUCK TRI，含一次性拨弦包络 |
| TONE 四档 | SINE / SQUARE / SAW / TRIANGLE |
| FX 四档 | DRY / CHORUS / VIBRATO / TREMOLO |
| 摇杆 RC 链路 | `rc_adc.v` + `pitch_bend_map.v`；X 弯音、Y 表情均实测有效 |
| 回归 | `tb_rc_adc`、`tb_pitch_bend_map`、`tb_chorus`、`tb_synth_engine`、`tb_p5_baseline`、`tb_ui_render` 等全 PASS |

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
| **E1** | ≥32 复音 / ≥32 加法分量 / 多条物理建模（三选一） | 4 复音 | **优先做 32 复音** |
| E2.1 | ≥3 维表情 | 2 维 | 用变阻器加第 3 维（颤音深度/滑音时间） |
| E2.6/7/8 | 混响 / 延迟 / 合唱 | 只有合唱 | 补 delay + reverb |
| **E3** | ≤5ms、无抖动、可视化 | 波形部分；其余无 | LED 指引 + 李萨如优先，频谱成本高 |
| E4 | 脱机 LED 曲目指引；蓝牙/App 可选 | 无 | LED 指引可做；蓝牙放弃 |
| **R3** | 测试模式多频输出 + 独立谱峰 | 模块存在但**未接顶层** | **优先集成** |

## 5. 新对话建议从这里开始

**第一优先：R3 + E1（同一套工作）**

1. 把 `rtl/test/test_mode.v` 接进一个演示顶层（或 `p6_test_demo` 的测试模式分支）；
2. 把 `VOICES` 从 4 扩到 32：
   - `voice_alloc` 支持 32（IDX_W=5）；
   - `mixer` 归一化档位扩到 32（当前只处理 1/2/3/4）；
   - `test_mode` 频率表扩到 32 个互不成谐波的 k 值；
   - UI 的 `st_voices` 只显示 0–4 即可。
3. 资源估算：8 声部 LUT 885 / DSP 8，32 声部约 LUT 3500 / DSP 32，20K 的 20736 LUT / 48 DSP 放得下；需以实际综合报告为准。
4. 演示：测试模式一次点亮 32 个声部 → 频谱数 32 个峰 → R2 吞吐量 = 32 × 48k = 1.536M。

**第二优先**：E2 第 3 维 + 延迟/混响。
**第三优先**：E3 LED 指引 / 李萨如、恢复正式 UI（关 `DEBUG_JOY`）。

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
`SPAN_LEFT=1200`、`SPAN_RIGHT=780`、弯音 ±1 半音、一阶低通 + 开机自动对中。

## 8. 固件 / 构建 / 烧录

```powershell
# 综合 + 布局布线
& "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" tmp/build_p6_test_demo.tcl

# 烧录（SRAM，断电丢失）
& "C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe" `
  -d GW2AR-18C -r 2 --fsFile `
  "C:\Users\ReachGao\Desktop\CodeX\loom\fpga\p6_test_demo\impl\pnr\p6_test_demo.fs"
```

- 当前版本 Logic 3514/20736、BSRAM 19/46、DSP 12.5/24，setup/hold 0 违例。
- **`DEBUG_JOY=1` 目前开着**（调试页）；演示前把 `rtl/p6_test_demo_top.v` 里
  `ui_render #(.DEBUG_JOY(1))` 改回 0，恢复正式波形 UI。

## 9. 关键设计决策

- **取消超声波**（2026-10-23）：赛题不强制；摇杆 Y 承担力度/动态。
- **不用 ADS1115**：摇杆用 FPGA-only RC 测时。
- **MODE 四档**：ONE / TRI / PLUCK ONE / PLUCK TRI；拨弦是包络，不是分解和弦。
- **拨弦一次性**：sustain=0，约 340ms 自然衰减；按住不放也自动释放，不占声部。
- **持续表情**：Y 轴直接控制混音后增益（0.1–1.0），按住音也能实时变化。
- **TONE/FX 各 4 档**；音色补偿 SINE/TRI 1.0、SQUARE 0.5、SAW 0.75。

## 10. 已知问题 / 技术债

| 问题 | 说明 |
|---|---|
| 摇杆低位噪声 | 已低通 + 显示屏蔽低 4 位；可再加中值滤波 |
| ≤10ms 延迟 | 未实测；10ms 消抖需降到 3–5ms 并验证 |
| 测试模式未集成 | `rtl/test/test_mode.v` 存在但没有任何顶层例化它 |
| `docs/13` 旧产品形态 | 五度环/12 扇区已被 7 键方案取代，需在 P5D 统一 |
| `DEBUG_JOY=1` | 当前是调试页，演示前关掉 |
| 32 复音 | 未做；是当前分数杠杆最大的进阶项 |

### 踩坑记录（详见 `docs/19` 案例 21–25）

1. Verilog 乘法结果宽度按最大操作数，必须用足够宽的中间量；
2. 单周期 `valid` 不能当持续使能，否则弯音每毫秒回中；
3. `voice.v` 的增益 `case` 只认 4 个 A 加权常量，力度会落到 default=1.0；
4. 10µF 电容让 RC 时间常数大 1000 倍，永远超时；
5. 调试文字列号必须按 8px 字格，已改用二进制方块显示。

## 11. 文件地图

| 文件 | 作用 |
|---|---|
| `rtl/p6_test_demo_top.v` | **当前主演示顶层**（按键/摇杆/TFT/合成） |
| `rtl/input/rc_adc.v` | RC 测时采集 |
| `rtl/input/pitch_bend_map.v` | 弯音映射（自动对中值输入） |
| `rtl/input/input_map.v` / `chord_map.v` | 7 键音名 / 7 个自然三和弦 |
| `rtl/synth/voice_adsr.v` | ADSR + 一次性拨弦 |
| `rtl/synth/voice.v` / `synth_top.v` / `synth_engine.v` | 合成链路（弯音/力度/拨弦） |
| `rtl/synth/chorus.v` | FX 四档（DRY/CHORUS/VIBRATO/TREMOLO） |
| `rtl/display/ui_render.v` / `tft_st7789.v` | TFT UI 与驱动 |
| `rtl/display/wave_capture.v` | 真实采样抓取（波形显示，当前调试页接管） |
| `rtl/test/test_mode.v` | R3 测试模式（**待接顶层**） |
| `fpga/p6_test_demo/` | 当前工程、`src/*.cst`、构建产物 |

## 12. 维护规则

- 完成阶段 / 改变冻结决策后，同步 `HANDOFF.md`、`README.md` 和对应专项文档；
- 本文件保持“接手所需”，细节下钻 `docs/`；
- 每次更新后跑 `git diff --check`，新加链接要有效。
