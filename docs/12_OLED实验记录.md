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
| STM32 测试工程 | 已完成主机、从机、边沿计数三类验证 |

---

## 五、后续清理项

1. `key_n` 当前未参与逻辑，会产生未使用输入警告；后续要么移除顶层端口和 `.cst` 约束，要么改成“重新初始化”按键。
2. 当前 `pix_byte` 是测试图案（2 像素边框 + 数字 `3`），后续做实时视觉反馈时需要替换为通用帧缓冲或波形显示。
3. OLED 相关实验改动已统一整理提交。

---

## 六、经验教训

1. 复用脚问题要先查 Gowin 的 Dual-Purpose Pin，不要先怀疑芯片或模块。
2. 遇到 I2C 不通时，用 STM32 做主从交叉验证，比继续盲改 FPGA 更快。
3. 裸 HAL 工程必须补齐 SysTick 和 I2C 中断入口，否则会卡在默认死循环。
4. SH1106 的可见区列偏移不一定固定是 2；最终以实际屏幕边框测试结果为准。
5. 涉及上电复位时，按键输入不要直接串进全系统复位，除非已确认按键电平稳定可靠。
