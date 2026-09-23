# OLED 实验记录（已完成点亮）

> 目的：用一个真实外设走通 FPGA 开发全流程，并为 P4S.8「实时视觉反馈」加分项预研。
> 状态：**2026-09-21 已点亮，最终接线、复位、列偏移和显示方向均已确认。**

---

## 一、最终可用配置

| 项目 | 最终值 |
|---|---|
| OLED 模块 | 1.3 寸 4 针 I2C，丝印 `GND VCC SCL SDA` |
| I2C 地址 | `0x3C`（7 位），写地址字节 `0x78` |
| FPGA 引脚 | SCL=PIN71（HSPI_D0），SDA=PIN72（HSPI_D1） |
| 供电 | VCC→3.3V，GND→FPGA GND |
| 初始化 | SH1106 命令序列 |
| 列地址偏移 | 控制器列起点 `0x02`，数据可见区从第 2 列开始 |
| 方向控制 | `A1` 段重映射 + `C8` COM 扫描方向 |
| SCL 速率 | 25 kHz（调试阶段） |
| 复位 | 仅使用上电复位 `por_done` |

### 最终显示图案

- 2 像素边框
- 中央 7 段式数字 `3`
- 用于确认列偏移与显示方向

---

## 二、这次“OLED 风波”的问题链

### 1. PIN52/53 的 SSPI 复用问题

最初的 OLED 接线使用 PIN52/53。这两个脚属于 SSPI 复用资源，必须启用：

```text
Gowin: Project Configuration -> Dual-Purpose Pin
Use SSPI as regular IO = true
```

后续改用 PIN71/PIN72 普通 IO，并把 SSPI 复用关闭，排除了该因素。

### 2. 复位信号 `key_n` 一直拉住 OLED 控制器

`oled_demo_top.v` 原逻辑是：

```verilog
wire rst_n = por_done & key_n;
```

实测 `key_n` 状态异常时，OLED 控制器一直处于复位，I2C 状态机根本不开始工作。
改为：

```verilog
wire rst_n = por_done;
```

后，SCL/SDA 立即开始活动。

### 3. STM32 调试固件缺少中断入口

交叉验证时，STM32 从机最初也表现异常，原因不是 OLED，而是裸 HAL 工程缺少：

```c
void SysTick_Handler(void)      { HAL_IncTick(); }
void I2C1_EV_IRQHandler(void)   { HAL_I2C_EV_IRQHandler(&hi2c1); }
void I2C1_ER_IRQHandler(void)   { HAL_I2C_ER_IRQHandler(&hi2c1); }
```

缺少这些入口时，中断会进入默认死循环。补齐后 STM32 从机能正常匹配 `0x78` 地址。

### 4. 列地址偏移不对

测试图案最初表现为：

- 左边框不可见
- 右边框整体左移 2 像素

说明数据被写入控制器列 0 起始位置，而实际可见区从控制器列 2 开始。
最终把列起点统一改为 `0x02` 后，四条边框完全对齐。

### 5. 显示方向

用 7 段式数字 `3` 验证方向。最终配置：

```text
0xA1：段重映射
0xC8：COM 扫描方向反向
```

屏幕显示的 `3` 方向、镜像关系和上下关系均正确。

---

## 三、交叉验证证据

### STM32 I2C 主机测试

- 扫描到 OLED 地址 `0x3C`
- SH1106 初始化成功
- 2 像素边框实际显示
- PC13 指示灯慢闪

结论：OLED 模块、供电、基础 I2C 接线正常。

### STM32 I2C 从机测试

- STM32 作为 `0x3C` 从机
- FPGA 地址匹配计数 66 次
- I2C 错误计数 0

结论：FPGA I2C 主机发送和地址 ACK 通路正常。

### FPGA 引脚方波测试

- PIN71/PIN72 输出低频方波
- STM32 边沿计数器读到 SCL/SDA 跳变

结论：PIN71/PIN72 到 STM32 的物理连接和共地正常。

---

## 四、当前工程状态

| 文件 | 状态 |
|---|---|
| `rtl/io/i2c_master.v` | 仿真通过，实机 I2C 主机已打通 |
| `rtl/display/oled_sh1106.v` | 实机点亮，完成列偏移和方向校准 |
| `rtl/display/oled_demo_top.v` | 实机运行，当前使用 `por_done` 复位 |
| `fpga/oled_demo/` | 综合、布局布线、位流生成正常 |
| `rtl/encoder_test_top.v` | EC11 + OLED 六格调试顶层，位流生成正常 |
| `fpga/encoder_test/` | 编码器 A/B/C 与 OLED 联合测试工程 |
| STM32 测试工程 | 已完成主机、从机、边沿计数三类验证 |

---

### 音色 / 合唱 demo 中的 OLED 状态页

2026-09-23 在独立工程 `fpga/timbre_fx_demo/` 中复用了这块 1.3 寸 SH1106，
用于显示当前音色、效果器和按键数。接线不变：

```text
OLED SCL -> PIN71
OLED SDA -> PIN72
```

`rtl/display/oled_sh1106.v` 的 `PATTERN_MODE=2` 显示：

```text
TIMBRE SINE / SQUARE
FX     DRY / CHORUS
VOICE  n/4
```

其中 `indicator_bits[0]` 表示音色，`indicator_bits[1]` 表示效果旁路，
`indicator_bits[5:2]` 表示当前按下的按键数。该状态页已通过
`sim/tb_oled_status.v` 逐字节仿真，并在 `timbre_fx_demo` 位流中与音频逻辑一起运行。

---

## 五、后续清理项

1. `key_n` 当前未参与逻辑，会产生未使用输入警告；后续要么移除顶层端口和 `.cst` 约束，要么改成“重新初始化”按键。
2. `pix_byte` 现在支持两种图案：默认边框/数字 `3`，以及 `PATTERN_MODE=1` 的六格调试条。后续做正式产品 TFT 显示时，再替换为通用帧缓冲或文本绘制。
3. OLED 相关实验改动已统一整理提交。

### EC11 + OLED 联合调试

> 本段保留的是早期引脚确认实验。当前产品实物模块为
> `A / C / B / VCC / GND`，没有独立按压开关，`C` 应接 `GND`。
> 旧测试顶层 `encoder_test_top.v` 把 `enc_c` 当作 `enc_sw_n`，不能用于当前模块的正式接线。

用于确认五引脚 EC11 模块的实际引脚行为：

- 编码器 A/B/C 分别接 PIN25/PIN26/PIN27；
- OLED SCL/SDA 继续使用 PIN71/PIN72；
- OLED 六格从左到右表示左旋事件、右旋事件、按压事件、C 消抖状态、A 原始状态、B 原始状态；
- 位流位于 `fpga/encoder_test/impl/pnr/encoder_test.fs`。

上电观察方式：

- 旋转编码器时，观察左侧两格是否发生翻转；
- 按下轴时，观察第三、第四格是否变化；
- 如果第五、第六格随旋转交替变化，说明 A/B 正常；
- 如果按轴时只有第四格变化，说明 C 是按键输出；
- 如果 C 在旋转时也变化，说明它不是单纯按键，需要重新确认接线。

如果 A/B/C 的对应关系仍不明确，可烧录更简单的原始电平探针位流：

```text
fpga/encoder_raw_test/impl/pnr/encoder_raw_test.fs
```

探针位流的 LED 含义：

```text
LED0 = A 为低      LED1 = A 为高
LED2 = B 为低      LED3 = B 为高
LED4 = C 为低      LED5 = C 为高
```

旋转时哪一对 LED 交替亮灭，就说明哪一个引脚正在输出编码器信号。

如果怀疑某个 FPGA 引脚或杜邦线有问题，可以使用 A/B 专项位流：

```text
fpga/encoder_ab_test/impl/pnr/encoder_ab_test.fs
```

该位流只使用 PIN25 和 PIN27，不再使用 PIN26，用于隔离引脚或跳线故障。

如果连“高低对”都不方便判断，还可以用单引脚活动探针：

```text
fpga/encoder_edge_test/impl/pnr/encoder_edge_test.fs
```

```text
LED0：A 发生过边沿，翻转一次
LED1：B 发生过边沿，翻转一次
LED2：C 发生过边沿，翻转一次
LED3/4/5：A/B/C 当前高电平状态
```

---

## 六、经验教训

1. 复用脚问题要先查 Gowin 的 Dual-Purpose Pin，不要先怀疑芯片或模块。
2. 遇到 I2C 不通时，用 STM32 做主从交叉验证，比继续盲改 FPGA 更快。
3. 裸 HAL 工程必须补齐 SysTick 和 I2C 中断入口，否则会卡在默认死循环。
4. SH1106 的可见区列偏移不一定固定是 2；最终以实际屏幕边框测试结果为准。
5. 涉及上电复位时，按键输入不要直接串进全系统复位，除非已确认按键电平稳定可靠。
