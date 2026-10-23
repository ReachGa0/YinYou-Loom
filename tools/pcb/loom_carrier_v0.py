#!/usr/bin/env python3
"""loom_carrier_v0.py —— 载板 v0 的"单一数据源" + 自检 + 表格生成

载板 v0 的定位（docs/14 §1）：**模块化母板**——只固定/转接 Tang Nano 20K、
分配电源、为成品模块提供带丝印的防插错接口；不把裸芯片放到板上。

本脚本只负责**连接定义**这一层（谁连谁），不负责几何：
  - 两条 1x20 核心板母座（J_CORE_A / J_CORE_B）的**物理顺序 → FPGA 引脚 → 网络名**
  - 三个电源网络 +3V3 / +5V / GND
  - 自检：34 个信号脚是否全部命名、有没有一脚两用、电源脚是否齐全
  - 生成 `PCB/carrier_v0/连接表与电源核对.md`（供逐项核对与万用表实测）

为什么先做这一层：本次面包板踩到的"DC 悬空""插错孔"都属于**连接层**错误，
所以先把连接定义写成可自检的数据，PCB 几何（摆放/走线/Gerber）随后由脚本生成，
再用 kicad-cli DRC 自检。

物理顺序依据：docs/14 §2（来自 Sipeed Tang Nano 20K Datasheet V1.3 第 5 页 +
实物丝印核对），两条母座的 1 脚都应位于 Tang Nano 的 USB-C 一端。
"""

import os
import re
import sys

# ------------------------------------------------------------
# 1. 核心板两条 1x20 排针：**物理顺序**（1 脚在 USB-C 端）
#    元素含义：FPGA 引脚号，或者电源标签 3V3 / 5V / GND
# ------------------------------------------------------------
HEADER_A = ["73", "74", "75", "85", "77", "15", "16", "27", "28", "25",
            "26", "29", "30", "31", "17", "20", "19", "18", "3V3", "GND"]

HEADER_B = ["5V", "GND", "76", "80", "42", "41", "56", "54", "51", "48",
            "55", "49", "86", "79", "GND", "3V3", "72", "71", "53", "52"]

# ------------------------------------------------------------
# 2. FPGA 引脚 → 网络名
#    已冻结的接口用功能名；用途未定的预留脚用 SPARE_<pin>
# ------------------------------------------------------------
NET_OF_PIN = {
    # —— 显示：2.4 寸 ST7789 TFT（2026-10-12 实机验证，见 docs/22）——
    "71": "TFT_SCLK", "72": "TFT_MOSI", "73": "TFT_CS",
    "74": "TFT_DC",   "75": "TFT_RES",  "76": "TFT_BLK",
    # —— 音频：I2S 到板载 MAX98357A（P3 实机出声）——
    "56": "AUDIO_BCLK", "55": "AUDIO_LRCK", "54": "AUDIO_DIN", "51": "AUDIO_PA_EN",
    # —— 演奏键（PIN28-31 实机确认）——
    "28": "KEY1_C4", "29": "KEY2_E4", "30": "KEY3_G4", "31": "KEY4_B4",
    # —— 板载按键（保底通路）——
    "88": "KEY_S1", "87": "KEY_S2",
    # —— 拨动开关（p6 demo 在用；形态待定）——
    "27": "KEY_MODE", "25": "KEY_LEVEL",
    # —— 超声波（接口已冻结，未上板）——
    "26": "ULTRA_TRIG", "80": "ULTRA_ECHO",
    # —— I2C 总线（ADS1115 / MPR121 共用；模块未到货，只引到扩展排母）——
    "77": "I2C_SCL", "85": "I2C_SDA",
    # —— 板载 LED（低电平点亮）——
    "15": "LED0", "16": "LED1", "17": "LED2", "18": "LED3", "19": "LED4", "20": "LED5",
    # —— 板载 WS2812（是否保留未定，暂按保留）——
    "79": "STATUS_WS2812",
    # —— 用途未定的预留脚（调式旋钮 / 触摸 IRQ / 备用）——
    "41": "SPARE_41", "42": "SPARE_42", "48": "SPARE_48", "49": "SPARE_49",
    "52": "SPARE_52", "53": "SPARE_53", "86": "SPARE_86",
}

# +5V_SEL 是"5V 选择轨"：外部 5V 端子 + J_EXT 的 5V 脚 + JP1 的一侧；
# JP1 另一侧接核心板 USB 5V(+5V)，插上跳线帽 = 用 USB 供电，拔掉 = 只用外部 5V。
POWER_NETS = ("+3V3", "+5V", "+5V_SEL", "GND")
POWER_LABEL = {"3V3": "+3V3", "5V": "+5V", "GND": "GND"}

# ------------------------------------------------------------
# 3. 模块接口（载板上要放的排母）
#    verified 字段写"怎么确认的"：已实机验证 / 接口已冻结但实物脚序待核 / 无极性
#    未到货或型号未定的模块（ADS1115、MPR121、12 档旋钮）**不在这里**，
#    它们的引脚全部走 J_EXT 通用扩展排母（见 docs/23 §1 的范围决定）。
# ------------------------------------------------------------
CONNECTORS = [
    dict(ref="J_TFT", label='2.4" TFT (ST7789)', pins=[
        "GND", "+3V3", "TFT_SCLK", "TFT_MOSI", "TFT_RES", "TFT_DC", "TFT_CS", "TFT_BLK"],
        verified="2026-10-12 实测：丝印顺序 GND/3V3/SCL/SDA/RES/DC/CS/BLK"),
    dict(ref="J_ULTRA", label="HC-SR04P 超声波", pins=[
        "+3V3", "ULTRA_TRIG", "ULTRA_ECHO", "GND"],
        verified="接口已冻结（docs/17）；实物排针脚序接板前核对"),
    dict(ref="J_KEY1", label="演奏键 C4", pins=["KEY1_C4", "GND"], verified="2 脚开关，无极性"),
    dict(ref="J_KEY2", label="演奏键 E4", pins=["KEY2_E4", "GND"], verified="2 脚开关，无极性"),
    dict(ref="J_KEY3", label="演奏键 G4", pins=["KEY3_G4", "GND"], verified="2 脚开关，无极性"),
    dict(ref="J_KEY4", label="演奏键 B4", pins=["KEY4_B4", "GND"], verified="2 脚开关，无极性"),
    dict(ref="J_SW1", label="模式开关（独奏/和弦）", pins=["KEY_MODE", "GND"], verified="2 脚开关，无极性"),
    dict(ref="J_SW2", label="电平开关（HI/LO）", pins=["KEY_LEVEL", "GND"], verified="2 脚开关，无极性"),
    # 通用扩展排母 2x10：未定用途的引脚全引出来（含 I2C 与全部 SPARE）
    # 注意：PIN76 是 TFT 背光（TFT_BLK），不是备用脚 —— 这里只列真正的 SPARE
    dict(ref="J_EXT", label="通用扩展排母 2x10", pins=[
        "SPARE_41", "SPARE_42", "SPARE_48", "SPARE_49", "SPARE_52",
        "SPARE_53", "SPARE_86", "I2C_SCL", "I2C_SDA", "GND",
        "GND", "GND", "GND", "GND", "GND", "GND",
        "+3V3", "+3V3", "+3V3", "+5V_SEL"],
        verified="本板定义（未定用途引脚全部引出，避免固死）"),
]

# 测试点（1 脚焊盘）
TEST_POINTS = [
    ("TP_3V3", "+3V3"), ("TP_5V", "+5V"), ("TP_GND", "GND"),
    ("TP_BCLK", "AUDIO_BCLK"), ("TP_LRCK", "AUDIO_LRCK"), ("TP_DIN", "AUDIO_DIN"),
    ("TP_TFT_SCLK", "TFT_SCLK"), ("TP_TFT_CS", "TFT_CS"),
]

# ------------------------------------------------------------
# 4. BOM（**全通孔**：不用任何贴片，手焊友好）
#    封装名均为 KiCad 官方库里的通孔封装；括号里是购买关键词。
# ------------------------------------------------------------
PARTS = [
    # 位号, 元件, 规格, KiCad 封装, 数量, 备注
    ("J_CORE_A/B", "母座 1x20", "2.54mm 直插", "PinSocket_1x20_P2.54mm_Vertical", 2,
     "核心板插这里"),
    ("J_TFT", "母座 1x8", "2.54mm 直插", "PinSocket_1x08_P2.54mm_Vertical", 1,
     "脚序已实测确认"),
    ("J_ULTRA", "母座 1x4", "2.54mm 直插", "PinSocket_1x04_P2.54mm_Vertical", 1,
     "接板前核对模块脚序"),
    ("J_KEY1-4", "母座 1x2", "2.54mm 直插", "PinSocket_1x02_P2.54mm_Vertical", 4,
     "演奏键"),
    ("J_SW1-2", "母座 1x2", "2.54mm 直插", "PinSocket_1x02_P2.54mm_Vertical", 2,
     "模式 / 电平开关"),
    ("J_EXT", "母座 2x10", "2.54mm 直插", "PinSocket_2x10_P2.54mm_Vertical", 1,
     "通用扩展"),
    ("J_PWR", "螺钉端子 2P", "5.08mm 脚距（如 KF301-2P）",
     "TerminalBlock_MetzConnect_Type101_RT01602HBWC_1x02_P5.08mm_Horizontal", 1,
     "外部 5V 输入（大焊盘，好焊好接线）"),
    ("JP1", "排针 1x2 + 跳线帽", "2.54mm 直插", "PinHeader_1x02_P2.54mm_Vertical", 1,
     "隔离外部 5V 与 USB 5V"),
    ("C1-C9", "独石电容 0.1uF/50V", "通孔 Ø5.0mm、2.5mm 脚距",
     "C_Disc_D5.0mm_W2.5mm_P2.50mm", 9,
     "每个模块接口旁去耦（特意选大体积，好手焊）"),
    ("C10", "电解电容 100uF/25V", "通孔 Ø8.0mm、2.5mm 脚距",
     "CP_Radial_D8.0mm_P2.50mm", 1,
     "5V 轨体电容"),
    ("TP1-TP8", "排针 1x1（测试点）", "2.54mm 直插", "PinHeader_1x01_P2.54mm_Vertical", 8,
     "可夹探针；不装也行"),
    ("H1-H4", "M3 安装孔", "Ø3.2mm 通孔", "MountingHole_3.2mm_M3", 4,
     "板角固定"),
]

# 不引到任何排母的网络（在核心板上已经用掉了，载板不再需要接口）
NOT_ROUTED = {
    "LED0": "板载 LED", "LED1": "板载 LED", "LED2": "板载 LED",
    "LED3": "板载 LED", "LED4": "板载 LED", "LED5": "板载 LED",
    "STATUS_WS2812": "板载 WS2812（是否外接灯环未定，暂不固化接口）",
    "AUDIO_BCLK": "板载 MAX98357A，喇叭接核心板 J4",
    "AUDIO_LRCK": "板载 MAX98357A",
    "AUDIO_DIN": "板载 MAX98357A",
    "AUDIO_PA_EN": "板载 MAX98357A 使能",
    "KEY_S1": "板载按键（保底通路）",
    "KEY_S2": "板载按键（保底通路）",
}

OUT_DIR = os.path.join("PCB", "carrier_v0")
OUT_MD = os.path.join(OUT_DIR, "连接表与电源核对.md")


def net_of(label: str) -> str:
    """把排针上的一个标签（FPGA 引脚号或电源标签）翻成网络名。"""
    if label in POWER_LABEL:
        return POWER_LABEL[label]
    return NET_OF_PIN.get(label, "")


def check() -> int:
    """连接层自检：不依赖 EDA，先把'一脚两用/漏接电源'这类错误挡在生成之前。"""
    problems = []
    all_labels = HEADER_A + HEADER_B

    # (1) 每个信号脚都必须有网络名
    for label in all_labels:
        if label in POWER_LABEL:
            continue
        if not net_of(label):
            problems.append("排针脚 %s 没有分配网络名" % label)

    # (2) 同一个网络名不能出现在两个不同的 FPGA 引脚上（电源除外）
    seen = {}
    for label in all_labels:
        if label in POWER_LABEL:
            continue
        net = net_of(label)
        if net in seen and seen[net] != label:
            problems.append("网络 %s 同时挂在引脚 %s 和 %s" % (net, seen[net], label))
        seen[net] = label

    # (3) 排针上不能出现同一个 FPGA 引脚号两次
    pin_seen = {}
    for label in all_labels:
        if label in POWER_LABEL:
            continue
        if label in pin_seen:
            problems.append("FPGA 引脚 %s 在排针上出现两次" % label)
        pin_seen[label] = True

    # (4) 电源脚必须齐全：+3V3 两处、+5V 一处、GND 三处（docs/14 §2）
    need_a = {"+3V3": 1, "+5V": 0, "GND": 1}
    need_b = {"+3V3": 1, "+5V": 1, "GND": 2}
    for name, header, need in (("J_CORE_A", HEADER_A, need_a),
                               ("J_CORE_B", HEADER_B, need_b)):
        got = {"+3V3": 0, "+5V": 0, "GND": 0}
        for label in header:
            if label in POWER_LABEL:
                got[POWER_LABEL[label]] += 1
        for rail in ("+3V3", "+5V", "GND"):
            if got[rail] != need[rail]:
                problems.append("%s 的 %s 脚数 = %d，应为 %d"
                                % (name, rail, got[rail], need[rail]))

    # (5) 排针长度必须是 20
    for name, header in (("J_CORE_A", HEADER_A), ("J_CORE_B", HEADER_B)):
        if len(header) != 20:
            problems.append("%s 长度 = %d，应为 20" % (name, len(header)))

    # (6) 每个模块接口的信号网络必须真实存在
    all_nets = set(NET_OF_PIN.values()) | set(POWER_NETS)
    routed = {}
    for conn in CONNECTORS:
        for net in conn["pins"]:
            if net not in all_nets:
                problems.append("%s 引用了不存在的网络 %s" % (conn["ref"], net))
            if net not in POWER_NETS:
                routed.setdefault(net, []).append(conn["ref"])

    # (7) 信号网络只能出现在一个模块接口上（电源/地除外）
    for net, refs in routed.items():
        if len(refs) > 1:
            problems.append("网络 %s 出现在多个接口: %s" % (net, ", ".join(refs)))

    # (8) 完整性：每个信号网络要么被引到一个接口，要么在"不引出"名单里写明理由
    for net in sorted(all_nets):
        if net in POWER_NETS:
            continue
        if net not in routed and net not in NOT_ROUTED:
            problems.append("网络 %s 既没有引出，也没在 NOT_ROUTED 里说明理由" % net)

    print("=== 连接层自检 ===")
    print("  排针脚总数      : %d（A %d + B %d）"
          % (len(all_labels), len(HEADER_A), len(HEADER_B)))
    print("  已命名信号脚    : %d" % len([x for x in all_labels if x not in POWER_LABEL]))
    print("  电源/地脚       : %d"
          % len([x for x in all_labels if x in POWER_LABEL]))
    print("  模块接口        : %d 个（%s）"
          % (len(CONNECTORS), ", ".join(c["ref"] for c in CONNECTORS[:4]) + " …"))
    print("  已引出信号网络  : %d" % len(routed))
    print("  明确不引出      : %d 个（板载 LED / 板载 WS2812 / 板载功放 / 板载按键）"
          % len(NOT_ROUTED))
    if problems:
        for p in problems:
            print("  [FAIL] " + p)
        return 1
    print("  结果            : 全部通过（无漏命名、无一脚两用、电源脚齐全）")
    return 0


def write_table() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    lines = []
    add = lines.append

    add("# 载板 v0 · 连接表与电源核对")
    add("")
    add("> 本文件由 `tools/pcb/loom_carrier_v0.py` **生成**，不要手改；")
    add("> 要改连接关系请改脚本再重新生成（这样连接定义始终可自检、可复现）。")
    add("")
    add("## 0. 这份表要你做的两件事")
    add("")
    add("1. **核对物理方向**：两条母座的 **1 脚都在 Tang Nano 的 USB-C 那一端**")
    add("   （`docs/14` §2：连接器符号可以旋转 180°，但焊盘编号必须与实物一致；")
    add("   两种表示不能混用）。")
    add("2. **用万用表实测核心板的电源脚**（最可靠，不依赖任何文档）：")
    add("     - 只给核心板供电（USB-C），万用表直流档量**核心板排针上的每一个脚**；")
    add("     - 找出哪些脚是 `+3V3`、哪些是 `+5V`、哪些是 `GND`，与下表第 2 列的")
    add("       “电源位置”对照；不一致就先停下来告诉我，不要接线。")
    add("")
    add("## 1. J_CORE_A（1x20 母座，1 脚在 USB-C 端）")
    add("")
    add("| 母座脚 | 核心板引脚 | 网络名 | 说明 |")
    add("|---:|---|---|---|")
    notes_a = {
        "TFT_CS": "TFT 片选", "TFT_DC": "TFT 数据/命令", "TFT_RES": "TFT 复位",
        "I2C_SDA": "I2C 数据（ADS1115/MPR121 共用）", "I2C_SCL": "I2C 时钟",
        "ULTRA_TRIG": "超声波触发", "KEY_MODE": "模式开关（独奏/和弦）",
        "KEY_LEVEL": "电平开关（HI/LO 调试）",
    }
    for i, label in enumerate(HEADER_A, start=1):
        net = net_of(label)
        desc = "电源" if label in POWER_LABEL else notes_a.get(net, "")
        if re.match(r"KEY\d", net):
            desc = "演奏键（C4/E4/G4/B4），低有效"
        elif net.startswith("LED"):
            desc = "板载 LED（低电平点亮）"
        add("| %d | %s | `%s` | %s |" % (i, label, net, desc))
    add("")
    add("## 2. J_CORE_B（1x20 母座，1 脚在 USB-C 端）")
    add("")
    add("| 母座脚 | 核心板引脚 | 网络名 | 说明 |")
    add("|---:|---|---|---|")
    notes_b = {
        "TFT_BLK": "TFT 背光（高电平点亮；此线**没有**串联二极管）",
        "ULTRA_ECHO": "超声波回波（3.3V 模块）",
        "AUDIO_BCLK": "I2S 位时钟", "AUDIO_LRCK": "I2S 左右声道",
        "AUDIO_DIN": "I2S 数据", "AUDIO_PA_EN": "功放使能",
        "STATUS_WS2812": "板载 WS2812 数据（5V 器件，需电平转换）",
        "TFT_MOSI": "TFT 数据（MOSI）", "TFT_SCLK": "TFT 时钟",
    }
    for i, label in enumerate(HEADER_B, start=1):
        net = net_of(label)
        desc = "电源" if label in POWER_LABEL else notes_b.get(net, "")
        add("| %d | %s | `%s` | %s |" % (i, label, net, desc))
    add("")
    add("## 3. 电源汇总（板级）")
    add("")
    add("| 电网 | 来源 | 核心板上的取电点 | 备注 |")
    add("|---|---|---|---|")
    add("| `+3V3` | Tang Nano 20K 的 3V3 | J_CORE_A-19、J_CORE_B-16 | **两处都要接** |")
    add("| `+5V` | Tang Nano 20K 的 5V（USB 供电） | J_CORE_B-1 | 与外部 5V 之间必须跳线/隔离 |")
    add("| `GND` | 全部共地 | J_CORE_A-20、J_CORE_B-2、J_CORE_B-15 | **三处都要接** |")
    add("")
    add("## 4. 信号脚使用情况（自动统计）")
    add("")
    used = sorted(NET_OF_PIN.items(), key=lambda kv: (kv[1]))
    add("| 网络名 | FPGA 引脚 | 类别 |")
    add("|---|---|---|")
    for pin, net in used:
        if net.startswith("SPARE"):
            cat = "预留（未定用途）"
        elif net.startswith(("TFT", "AUDIO", "KEY", "ULTRA", "I2C", "LED", "STATUS")):
            cat = "已冻结/已验证"
        else:
            cat = ""
        add("| `%s` | %s | %s |" % (net, pin, cat))
    add("")
    add("> 预留脚（`SPARE_41/42/48/49/52/53/86`）按 docs/15 §7 的 v2 提案保留：")
    add("> 将来调式旋钮要用 BCD 输出（4 脚）才接得下，普通 1P12T 接不下 —— 这条")
    add("> 没定之前**不固化到铜箔**，只引到通用扩展排母。")
    add("")
    add("## 5. 模块接口（载板上要放的排母）")
    add("")
    add("| 位号 | 接口 | 脚数 | 逐脚网络（1→N） | 脚序怎么确认的 |")
    add("|---|---|---:|---|---|")
    for conn in CONNECTORS:
        add("| `%s` | %s | %d | %s | %s |"
            % (conn["ref"], conn["label"], len(conn["pins"]),
               " / ".join("`%s`" % n for n in conn["pins"]),
               conn["verified"]))
    add("")
    add("> ⚠️ 打样前对每个标注「按实物核对脚序」的接口（当前：超声波）逐脚确认：")
    add("> 模块丝印 → 实物排针脚号 → 本条网络。**顺序错的排母等于整板返工。**")
    add("")
    add("## 6. 不引出的网络（及理由）")
    add("")
    add("| 网络 | 为什么不引到排母 |")
    add("|---|---|")
    for net in sorted(NOT_ROUTED):
        add("| `%s` | %s |" % (net, NOT_ROUTED[net]))
    add("")
    add("## 7. 测试点")
    add("")
    add("| 测试点 | 网络 |")
    add("|---|---|")
    for name, net in TEST_POINTS:
        add("| `%s` | `%s` |" % (name, net))
    add("")
    add("## 8. BOM（全通孔，手焊友好）")
    add("")
    add("> 全板**不用任何贴片元件**：去耦用 Ø5mm 独石电容、体电容用 Ø8mm 电解、")
    add("> 电源入口用 5.08mm 螺钉端子、跳线用 2.54mm 排针 + 跳线帽。")
    add("")
    add("| 位号 | 元件 | 规格 | KiCad 封装 | 数量 | 备注 |")
    add("|---|---|---|---|---:|---|")
    for ref, name, spec, fp_name, qty, note in PARTS:
        add("| `%s` | %s | %s | `%s` | %d | %s |"
            % (ref, name, spec, fp_name, qty, note))
    add("")
    add("> 螺钉端子的封装名不同厂家不同，但**脚距都是 5.08mm**；买 KF301-2P 即可。")

    with open(OUT_MD, "w", encoding="utf-8", newline="\n") as fp:
        fp.write("\n".join(lines) + "\n")
    print("已生成: %s（%d 行）" % (OUT_MD, len(lines)))


def main() -> int:
    rc = check()
    write_table()
    return rc


if __name__ == "__main__":
    sys.exit(main())
