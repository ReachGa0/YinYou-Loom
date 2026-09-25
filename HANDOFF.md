# Loom 工程交接

> 状态：当前有效
> 更新日期：2026-09-23
> 用途：让新对话用最少上下文恢复工程状态。本文件是入口和索引，不是最终决策记录。

## 0. 新对话如何使用

新对话开始时，先完整读取本文件，再按 `AGENTS.md` 第六节核对下面这些权威文件：

- `README.md` 的「当前进度快照」
- `docs/04_任务拆解.md` 的当前执行顺序
- `docs/06_决策登记与延后策略.md`
- `docs/16_V1范围与输入语义.md`
- 当前专项设计文档，例如 `docs/17_P5C超声波设计.md`

然后先向用户复述：当前阶段、当前角色、已完成内容、下一步、禁止事项。
**得到用户明确确认前，不要创建或修改 Verilog、testbench 或工程脚本。**

可以直接把下面这句发给新对话：

```text
请先完整读取 HANDOFF.md，再按 AGENTS.md 第六节核对 README、docs/04、docs/06、docs/16 和当前专项设计文档，并检查 git status。先复述阶段、角色、下一步和禁止事项，等我确认；确认前不要写代码。
```

若仓库文档与用户最新描述冲突，以用户最新明确描述为准，并提醒更新对应文档。

## 1. 项目一句话

**吟游 Loom**：运行在 Sipeed Tang Nano 20K（GW2AR-LV18）上的 FPGA 实时多音色合成器。
音频生成链路必须全部由 HDL 逐声部、逐样本完成，不使用 MCU 参与功能，不使用预录 PCM。

## 2. 当前阶段

| 项目 | 当前状态 |
|---|---|
| 阶段 | **P5 交互层** |
| 子阶段 | **P5C 超声波测距入口** |
| 角色 | **角色 E · 硬件工程师** |
| 已完成上游 | P0、P1、P2、P3、P4、P5A |
| 当前主线 | 按 `docs/17_P5C超声波设计.md` 实现并验证超声波测距 |
| 下一阶段 | P5D 统一输入语义，随后 P6 测试验证 |

### 当前专项任务（2026-09-25）

物料（MPR121 / SPI OLED / 电位器等）尚未到货，等待期内先做**硬件设计**：

- 任务：**触摸模块的电源图 + PCB**（24 电极 / 2 片 MPR121 / I2C + IRQ），**不写 Verilog**；
- 入口文档：[`docs/20_触摸模块硬件设计与交接.md`](docs/20_触摸模块硬件设计与交接.md)
  （含电气要点、交付格式约定、验收标准，第 8 节是可直接粘贴的提示词）；
- 引脚基线：[`docs/15_P5网络映射表.md`](docs/15_P5网络映射表.md) §7（v2 提案，待确认）；
- 前置决策（必须先问用户）：MPR121 用**模块还是裸芯片**、24 电极的**形态与尺寸**、
  与核心板的**连接方式**、是否预留**自研 RC 备用焊盘**。

### 已完成且不要重做

- P3 I2S 输出与板载 MAX98357A 已上板出声。
- P4 四声部合成已上板演示。
- P5A 四键、10 ms 软件消抖、多声部归一化第一版已实机确认。
- 多键同时按下不再破音，按键数变化时已实机确认平滑。
- `timbre_fx_demo_top` 已用旧 OLED 显示音色、效果器和按键数。
- v1.0 输入语义、P5C 测距接口和验证计划已经冻结。

### 已完成（2026-09-23，仿真阶段）

- `rtl/input/sonar_range.v` **已创建**，接口与 `docs/17` 第 3 节一致。
- `sim/tb_sonar_range.v` **已创建**，`docs/17` 第 6 节 10 个用例全过。
- `sim/run_all.ps1` **已注册** `tb_sonar_range`，全量回归 23 套、失败 0 套。

### 当前明确未完成

- 超声波模块尚未到货，P5C **未上板验证**。
- `fpga/p5c_sonar_demo` 尚未建立。
- P5C.2 的力度 / 动态映射和 P5D 统一 `input_map` 尚未完成。

**设计文档存在不代表代码已实现，也不代表已经授权直接创建代码。**

## 3. 当前必须遵守的边界

1. 先讲实现思路，再等用户明确说“可以”，之后才能写代码。
2. 不修改正式 `rtl/loom_top.v`，除非用户针对该文件明确授权。
3. PCB 母板暂停，优先做面包板 / 杜邦线模块验证。
4. 自研电容触摸、TFT、WS2812 是 v1.0 后的增量，不阻塞 P5C / P5D。
5. OLED 调试工程使用 PIN71 / PIN72；这两个引脚又是 TFT SCLK / MOSI，同一工程只能二选一。
6. 工作区已有大量未提交改动。禁止 `git reset`、`git checkout --`、`git clean` 或回退任何现有改动。

截至本文件更新时，`git status` 为 **31 项已修改、11 项未跟踪，共 42 项变化**。
新对话应重新运行 `git status --porcelain=v1` 核对，不要只信这个快照数字。

## 4. P5C 硬件连接

| 信号 | 约定 |
|---|---|
| 模块 | 优先 `HC-SR04P` 3.3V 版本 |
| 供电 | `+3V3` |
| TRIG | FPGA `PIN26`，网络名 `ULTRA_TRIG` |
| ECHO | FPGA `PIN80`，网络名 `ULTRA_ECHO` |
| 地 | 与 FPGA 共地 |

普通 5V `HC-SR04` 不能把 Echo 直接接 FPGA，必须做电平保护。分压或电平转换均可；
上电前先实测 Echo 高电平，确认不超过 3.3V 后再接 PIN80。`1kΩ + 2kΩ` 在 5.25V
供电下不是安全余量。

## 5. P5C 冻结接口

权威定义在 `docs/17_P5C超声波设计.md` 第 3 节。当前接口为：

```verilog
module sonar_range #(
    parameter CLK_MHZ     = 72,
    parameter TRIG_US     = 12,
    parameter PERIOD_US   = 70_000,
    parameter TIMEOUT_US  = 30_000,
    parameter STUCK_US    = 100_000,
    parameter MIN_ECHO_US = 50,
    parameter MAX_DIST_MM = 4500
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg         trig,
    input  wire        echo,
    output reg  [15:0] distance_mm,
    output reg         valid,
    output reg         fault,
    output reg  [7:0]  stuck_cnt
);
```

关键行为：

- 状态机：`S_IDLE -> S_TRIG -> S_WAIT_HI -> S_MEASURE -> S_CALC`。
- ECHO 是异步输入，必须两级同步，状态机只使用同步值和边沿脉冲。
- `PERIOD_US` 是两次 TRIG 启动间隔下限，不是固定周期。
- `distance_mm` 无效时保持上一次有效值；复位值为 `16'hFFFF`。
- `valid` 只在一次测量通过校验时为高，并保持到下一次进入 `S_TRIG`。
- `fault` 在 ECHO 卡高超过 `STUCK_US` 后锁存；只有成功测量才清除。
- `S_WAIT_HI` 用电平判断 ECHO，不能只等上升沿。
- `S_WAIT_LO` 必须有界超时，不能让 ECHO 卡高拖死状态机。

## 6. 已确认的实现口径（写代码时必须遵守）

以下 6 条口径已于 2026-09-23 与用户确认，并已同步进
`docs/17_P5C超声波设计.md`（第 4.3 / 4.4 / 4.5 / 5 / 6 节）。写代码时按此执行，
不需要再重复确认，也不要再按旧口径实现：

1. 时间戳必须只在状态转移时单次刷新：
   - `t_state` 只在 `S_TRIG -> S_WAIT_HI` 和 `S_MEASURE -> S_WAIT_LO` 时刷新。
   - `t_echo_rise` 只在 `S_WAIT_HI -> S_MEASURE` 时刷新。
   - `t_echo_fall` 只在 `S_MEASURE` 检测到下降沿时刷新。
   - 禁止在 `S_WAIT_HI`、`S_MEASURE`、`S_WAIT_LO` 中每个时钟周期无条件刷新时间戳，否则超时失效，回波时间也可能恒为 0。
2. TRIG 宽度按 1 µs 粒度实现和断言，只要求 `>= 10 µs`，不声称 ns 级宽度或抖动。
3. `valid` 的保持期只写“保持到下一次进入 `S_TRIG`”，不要写“约 57 ms”。
4. 距离换算采用四舍五入（权威定义见 `docs/17` 第 5 节）：

```text
distance_mm = ((echo_us * 11233) + 32'h8000) >> 16
```

该常数对应约 `0.171402 mm/µs`，即约 `342.8 m/s`，不是 `0.1715 mm/µs`。

5. `us_cnt` 等计数器和 `PERIOD_US` 等参数显式使用 32 位宽度，避免宽度和符号警告。
6. 不增加 `rise_seen` 状态。ECHO 在 TRIG 前已经为高时可能产生看起来合法的假距离，
   已登记为已知残余风险（见 `docs/17` 第 4.5 节）；v1.0 不扩大冻结状态机。

## 7. 推荐实施顺序

1. ✅ 已完成：`docs/17` 实现口径已同步并确认。
2. 讲解 `sonar_range.v` 的周期级实现思路，等用户确认。
3. 创建 `rtl/input/sonar_range.v`。
4. 创建 `sim/tb_sonar_range.v`，先单独跑完 `docs/17` 第 6 节用例。
5. 仿真通过后，再修改 `sim/run_all.ps1`，把 `tb_sonar_range` 加进 P5 小节。
6. 建立独立 `fpga/p5c_sonar_demo`，用旧 OLED 显示 `distance_mm / valid / fault`。
7. 距离稳定后，再做力度 / 动态映射和 P5D 输入合并。

不要把 `tb_sonar_range` 加入 `sim/run_sim.ps1`；该脚本是音频链路专用入口。

## 8. 维护规则

- 完成一个阶段或改变冻结决策后，同步更新本文件、`README.md` 和对应专项文档。
- 本文件保持短小，只写接手真正需要的信息；完整细节下钻到 `docs/`。
- 每次更新后运行 `git diff --check`，并确认新加链接有效。
