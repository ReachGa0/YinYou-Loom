#!/usr/bin/env python3
"""gen_carrier_v0_pcb.py —— 用 KiCad 官方 Python API 生成载板 v0 的 PCB

**必须用 KiCad 自带的 Python 运行**：
    "C:\\Program Files\\KiCad\\10.0\\bin\\python.exe" tools/pcb/gen_carrier_v0_pcb.py

机械参数：
  沿排间距 2.54mm、核心板 54.04×22.55mm —— 官方 datasheet（打印页 6 / PDF 第 8 页）
  两排母座中心距 20.32mm              —— 用户实测确认（2026-10-12）
  1:1 打印对孔核对                     —— 2026-10-12 用户确认"对上了"

叠层（4 层，2026-10-12 用户决定）：
  L1 F.Cu   ：信号（水平为主）
  L2 In1.Cu ：GND 整片
  L3 In2.Cu ：+3V3 整片
  L4 B.Cu   ：信号（竖直为主）
  两个内层做平面后，信号层不再被铺铜切割，过孔也不受"通道"限制 → 走线难度大降。
"""

import os
import sys
import math

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import loom_carrier_v0 as design          # noqa: E402  连接表（单一数据源）

# ------------------------------------------------------------
# 尺寸与布局
# ------------------------------------------------------------
ROW_SPACING = 20.32        # 两排母座中心距（mm）—— 用户实测确认
BOARD_W = 110.0
BOARD_H = 70.0
COPPER_LAYERS = 4          # 4 层板：L1 信号 / L2 GND / L3 +3V3 / L4 信号
CORE_USB_X = 20.0          # 核心板 USB-C 端在板上的位置（= 母座 pad1 的 x）
CORE_Y_A = 25.0
CORE_Y_B = CORE_Y_A + ROW_SPACING

LIBDIR = r"C:\Program Files\KiCad\10.0\share\kicad\footprints"
SOCKET_LIB = LIBDIR + r"\Connector_PinSocket_2.54mm.pretty"
HEADER_LIB = LIBDIR + r"\Connector_PinHeader_2.54mm.pretty"
CAP_LIB = LIBDIR + r"\Capacitor_THT.pretty"
TERM_LIB = LIBDIR + r"\TerminalBlock_MetzConnect.pretty"
MECH_LIB = LIBDIR + r"\MountingHole.pretty"
SOCKET1x20 = "PinSocket_1x20_P2.54mm_Vertical"

OUT_PCB = os.path.join("PCB", "carrier_v0", "Loom_Carrier_V0.kicad_pcb")

TRACK_W = 0.4          # 信号线宽
PWR_W = 0.5            # 电源线宽（1oz 铜 0.5mm 可过 1A 以上，够背光/灯环；
                       # 注意：避让余量必须随线宽放大，否则粗线会压到旁边的铜）
SEG_EXTRA = 0.45       # 避让余量 = 线宽一半 + 规则间距（0.2） + 余量
VIA_D = 0.6
VIA_DRILL = 0.3
# 自由带：过孔与水平走线可用的横向空带（避开核心板两排焊盘 y=25 / 45.32 与器件行）
YV_TOP = 21.5          # J_TFT 与核心板之间
YV_BOT = 49.0          # 核心板 B 排与下方器件之间
ROUTE_SIGNALS = False  # 由用户在 KiCad 交互式布线；脚本只负责摆件 + 铺铜 + 出清单

# 布局表：(位号, 库, 封装, 网络(物理顺序) 或 None=核心板母座, x, y, 旋转, 丝印)
PLACEMENT = [
    ("J_CORE_A", SOCKET_LIB, SOCKET1x20, None, CORE_USB_X, CORE_Y_A, 90, "CORE A"),
    ("J_CORE_B", SOCKET_LIB, SOCKET1x20, None, CORE_USB_X, CORE_Y_B, 90, "CORE B"),
    ("J_TFT", SOCKET_LIB, "PinSocket_1x08_P2.54mm_Vertical",
     ["GND", "+3V3", "TFT_SCLK", "TFT_MOSI", "TFT_RES", "TFT_DC", "TFT_CS", "TFT_BLK"],
     20.0, 16.0, 90, "TFT ST7789"),
    # —— 底部：7 个模块接口排成一行（y=54），落线只从行外竖直落到焊盘 ——
    ("J_KEY1", SOCKET_LIB, "PinSocket_1x02_P2.54mm_Vertical",
     ["KEY1_C4", "GND"], 19.0, 54.0, 90, "KEY C4"),
    ("J_KEY2", SOCKET_LIB, "PinSocket_1x02_P2.54mm_Vertical",
     ["KEY2_E4", "GND"], 28.0, 54.0, 90, "KEY E4"),
    ("J_KEY3", SOCKET_LIB, "PinSocket_1x02_P2.54mm_Vertical",
     ["KEY3_G4", "GND"], 37.0, 54.0, 90, "KEY G4"),
    ("J_KEY4", SOCKET_LIB, "PinSocket_1x02_P2.54mm_Vertical",
     ["KEY4_B4", "GND"], 46.0, 54.0, 90, "KEY B4"),
    ("J_SW1", SOCKET_LIB, "PinSocket_1x02_P2.54mm_Vertical",
     ["KEY_MODE", "GND"], 10.0, 54.0, 90, "SW MODE"),
    ("J_SW2", SOCKET_LIB, "PinSocket_1x02_P2.54mm_Vertical",
     ["KEY_LEVEL", "GND"], 55.0, 54.0, 90, "SW HI/LO"),
    ("J_ULTRA", SOCKET_LIB, "PinSocket_1x04_P2.54mm_Vertical",
     ["+3V3", "ULTRA_TRIG", "ULTRA_ECHO", "GND"], 64.0, 54.0, 90, "ULTRA"),
    ("J_EXT", SOCKET_LIB, "PinSocket_2x10_P2.54mm_Vertical",
     # ⚠️ 顺序 = 板上物理顺序（先上排、再下排，各自从左到右）。
     # 上排放电源地、**下排放信号**：这样信号焊盘能从下方大空带引线，
     # 不必挤在核心板与 J_EXT 之间的窄缝里（2026-10-12 用户建议互换）。
     ["GND", "GND", "GND", "GND", "GND", "GND",
      "+3V3", "+3V3", "+3V3", "+5V_SEL",
      "SPARE_41", "SPARE_42", "SPARE_48", "SPARE_49", "SPARE_52",
      "SPARE_53", "SPARE_86", "I2C_SCL", "I2C_SDA", "GND"],
     78.0, 38.0, 90, "J_EXT 2x10"),
    ("J_PWR", TERM_LIB, "TerminalBlock_MetzConnect_Type101_RT01602HBWC_1x02_P5.08mm_Horizontal",
     ["+5V_SEL", "GND"], 12.0, 6.0, 0, "5V IN"),
    ("JP1", HEADER_LIB, "PinHeader_1x02_P2.54mm_Vertical",
     ["+5V", "+5V_SEL"], 22.0, 6.0, 0, "5V SEL"),
    ("C10", CAP_LIB, "CP_Radial_D8.0mm_P2.50mm", ["+5V_SEL", "GND"], 32.0, 7.0, 0, "100uF"),
    ("C1", CAP_LIB, "C_Disc_D5.0mm_W2.5mm_P2.50mm", ["+3V3", "GND"], 42.0, 7.0, 0, "100n"),
    ("C2", CAP_LIB, "C_Disc_D5.0mm_W2.5mm_P2.50mm", ["+3V3", "GND"], 44.0, 22.5, 0, "100n"),
    ("C3", CAP_LIB, "C_Disc_D5.0mm_W2.5mm_P2.50mm", ["+3V3", "GND"], 70.0, 60.0, 0, "100n"),
    # 注意：J_EXT 的焊盘一直排到 x≈101，所以这三个电容必须放在它**下方**（y≥45）
    ("C4", CAP_LIB, "C_Disc_D5.0mm_W2.5mm_P2.50mm", ["+3V3", "GND"], 96.0, 48.0, 0, "100n"),
    ("C5", CAP_LIB, "C_Disc_D5.0mm_W2.5mm_P2.50mm", ["+3V3", "GND"], 96.0, 56.0, 0, "100n"),
    ("C6", CAP_LIB, "C_Disc_D5.0mm_W2.5mm_P2.50mm", ["+3V3", "GND"], 88.0, 60.0, 0, "100n"),
    ("C7", CAP_LIB, "C_Disc_D5.0mm_W2.5mm_P2.50mm", ["+5V_SEL", "GND"], 12.0, 18.0, 0, "100n"),
]

TESTPOINTS = [
    # 测试点一律放在"对应网络的目标接口旁边"，这样连线是短链（不占主干带）。
    # +3V3 / GND 的测试点由内层平面直接连通，无需走线。
    # 音频测试点（BCLK/LRCK/DIN）取消：那三根线在核心板上就已接到板载 DAC，
    # 载板不需要引出（docs/23 有记录）。
    # 位置都避开：核心板机械覆盖区(17..68 × 24..46)、4 个安装孔、电容、J_EXT 第二排
    ("TP1", 10.0, 60.0, "+3V3"),     # 左侧空带；由 L3 平面直连
    ("TP2", 25.0, 5.0, "+5V_SEL"),   # 顶部空带，靠 5V 端子/JP1
    ("TP3", 16.0, 66.0, "GND"),      # 右下空带；由 L2 平面直连
    ("TP4", 50.0, 11.0, "TFT_SCLK"), # 顶部空带，靠 J_TFT
    ("TP5", 56.0, 11.0, "TFT_CS"),   # 顶部空带，靠 J_TFT
    ("TP6", 74.0, 30.0, "I2C_SCL"),  # J_EXT 上方空带
    ("TP7", 74.0, 33.0, "I2C_SDA"),  # J_EXT 上方空带
]

MOUNT_HOLES = [("H1", 5.0, 5.0), ("H2", 105.0, 5.0),
               ("H3", 5.0, 65.0), ("H4", 105.0, 65.0)]


def mm(v):
    return pcbnew.FromMM(v)


def pt(x, y):
    return pcbnew.VECTOR2I(mm(x), mm(y))


def pad_physical_order(fp):
    """按物理顺序返回焊盘：一律 (y, x) 排序。

    对单排连接器 = 沿排顺序；对 2xN = 先第一排再第二排（行优先），
    这样连接表里写的"1..N"就是用户在板子上从左到右、从上到下的顺序。
    """
    pads = list(fp.Pads())
    pads.sort(key=lambda p: (p.GetPosition().y, p.GetPosition().x))
    return pads


def place(board, ref, lib, name, nets, x, y, rot, label):
    fp = pcbnew.FootprintLoad(lib, name)
    if fp is None:
        raise RuntimeError("加载封装失败: %s / %s" % (lib, name))
    fp.SetReference(ref)
    fp.SetValue(label)
    fp.SetOrientationDegrees(rot)
    board.Add(fp)

    pads = pad_physical_order(fp)
    p0 = pads[0].GetPosition()
    fp.SetPosition(pcbnew.VECTOR2I(fp.GetPosition().x + mm(x) - p0.x,
                                   fp.GetPosition().y + mm(y) - p0.y))

    if nets is not None:
        if len(pads) != len(nets):
            raise RuntimeError("%s 焊盘数 %d != 网络数 %d" % (ref, len(pads), len(nets)))
        for pad, net_name in zip(pads, nets):
            net = board.FindNet(net_name)
            if net is None:
                net = pcbnew.NETINFO_ITEM(board, net_name)
                board.Add(net)
            pad.SetNet(net)

    # 防插错丝印：只留一个小的 "1" 脚标记（放在封装轮廓外）。
    # 元件的功能由参考号本身表达（J_TFT / J_ULTRA / J_KEY1 …），不再额外加文字，
    # 否则密集区域的丝印会互相压住（DRC 会报 silk_overlap）。
    fp.Value().SetVisible(False)
    bb = fp.GetBoundingBox()
    bx0, by0 = bb.GetLeft() / 1e6, bb.GetTop() / 1e6
    bx1, by1 = bb.GetRight() / 1e6, bb.GetBottom() / 1e6
    add_text(board, "1", bx0 - 1.5, (by0 + by1) / 2.0 - 0.45, 0.9)
    return fp


def add_text(board, text, x, y, size=1.2):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(text)
    t.SetPosition(pt(x, y))
    t.SetLayer(pcbnew.F_SilkS)
    t.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    t.SetTextThickness(mm(size * 0.16))
    try:
        t.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_LEFT)
    except AttributeError:
        pass
    board.Add(t)


def add_outline(board):
    for (x1, y1, x2, y2) in ((0, 0, BOARD_W, 0), (BOARD_W, 0, BOARD_W, BOARD_H),
                             (BOARD_W, BOARD_H, 0, BOARD_H), (0, BOARD_H, 0, 0)):
        seg = pcbnew.PCB_SHAPE(board)
        seg.SetShape(pcbnew.SHAPE_T_SEGMENT)
        seg.SetStart(pt(x1, y1))
        seg.SetEnd(pt(x2, y2))
        seg.SetLayer(pcbnew.Edge_Cuts)
        seg.SetWidth(mm(0.1))
        board.Add(seg)


def add_zone(board, layer, net_name):
    zone = pcbnew.ZONE(board)
    zone.SetLayer(layer)
    zone.SetNet(board.FindNet(net_name))
    # 明确给平面设 clearance：否则铺铜会贴着别的网络的焊盘（DRC 报"短路"）
    try:
        zone.SetLocalClearance(mm(0.5))
    except AttributeError:
        pass
    outline = zone.Outline()
    outline.NewOutline()
    for (x, y) in ((0.6, 0.6), (BOARD_W - 0.6, 0.6),
                   (BOARD_W - 0.6, BOARD_H - 0.6), (0.6, BOARD_H - 0.6)):
        outline.Append(mm(x), mm(y))
    board.Add(zone)
    return zone


def pads_of(board, net_name):
    out = []
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            if pad.GetNetname() == net_name:
                out.append(pad)
    return out


def track(board, x1, y1, x2, y2, layer, net, width=TRACK_W):
    if abs(x1 - x2) < 1e-6 and abs(y1 - y2) < 1e-6:
        return None
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(pt(x1, y1))
    t.SetEnd(pt(x2, y2))
    t.SetWidth(mm(width))
    t.SetLayer(layer)
    t.SetNet(net)
    board.Add(t)
    return t


def via(board, x, y, net):
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(pt(x, y))
    v.SetWidth(mm(VIA_D))
    v.SetDrill(mm(VIA_DRILL))
    v.SetViaType(pcbnew.VIATYPE_THROUGH)
    v.SetNet(net)
    board.Add(v)
    return v


def core_pads(board):
    return [p for fp in board.GetFootprints()
            if fp.GetReference() in ("J_CORE_A", "J_CORE_B")
            for p in fp.Pads()]


def link(board, a, b, width=TRACK_W):
    """一段连接：竖直段走底层（用 a 的 x）、水平段走顶层（用 b 的 y），拐角过孔。"""
    x1, y1 = a.GetPosition().x / 1e6, a.GetPosition().y / 1e6
    x2, y2 = b.GetPosition().x / 1e6, b.GetPosition().y / 1e6
    net = a.GetNet()
    track(board, x1, y1, x1, y2, pcbnew.B_Cu, net, width)
    via(board, x1, y2, net)
    track(board, x1, y2, x2, y2, pcbnew.F_Cu, net, width)


def route_net(board, net_name, width=TRACK_W):
    """从核心板引脚出发，按链式连接该网络的所有焊盘（支持测试点等第 3 个焊盘）。"""
    pads = pads_of(board, net_name)
    if len(pads) < 2:
        return False
    cores = [p for p in pads if p in core_pads(board)]
    rest = [p for p in pads if p not in cores]
    order = cores[:1] + rest + cores[1:]
    for i in range(len(order) - 1):
        link(board, order[i], order[i + 1], width)
    return True


def seg_clear(x1, y1, x2, y2, obstacles, extra=0.35):
    """线段是否避开障碍焊盘。

    obstacles 元素是 (x, y, r)：**必须带上焊盘半径**，否则走线会从焊盘上穿过去
    （这是本轮踩到的坑：只按"点 + 小余量"判定，DRC 报出一堆间距/短路）。
    判定：线段采样点到焊盘中心的距离 >= 焊盘半径 + extra（extra 含线宽一半与规则间距）。
    """
    length = math.hypot(x2 - x1, y2 - y1)
    n = max(2, int(length / 0.25))
    for i in range(n + 1):
        t = i / n
        x = x1 + (x2 - x1) * t
        y = y1 + (y2 - y1) * t
        for (px, py, pr) in obstacles:
            if (px - x) ** 2 + (py - y) ** 2 < (pr + extra) ** 2:
                return False
    return True


TRUNK_BANDS = {                 # 主干（水平段）可用的 y 区间，每条网络独占一条
    "J_TFT": (9.0, 14.5),       # TFT 之上（J_TFT 行在 y=16）
    "J_EXT": (26.0, 36.0),      # 扩展排母上方自由带（它的信号焊盘在第 1 排，必须从上落线）
    "J_PWR": (2.5, 5.0), "JP1": (2.5, 5.0),
    "C10": (2.5, 5.0), "C7": (2.5, 5.0),
}
DEFAULT_BANDS = [(46.5, 52.5), (56.0, 65.0)]    # 底部那一行接口：上带 / 下带
GRID = 0.25


class Router:
    """4 层走线器：竖直走 L4、水平走 L1，用"同层占用网格"自己避让。"""

    def __init__(self, board):
        self.board = board
        self.occ = {pcbnew.F_Cu: {}, pcbnew.B_Cu: {}}     # 格子 -> 网络名
        self.used_y = set()
        self.used_ch = set()                              # 已占用的竖直通道 x
        self.failed = []
        self.debug = []

    @staticmethod
    def _k(x, y):
        return (int(round(x / GRID)), int(round(y / GRID)))

    def _samples(self, x1, y1, x2, y2):
        n = max(2, int(math.hypot(x2 - x1, y2 - y1) / (GRID * 0.5)))
        for i in range(n + 1):
            t = i / n
            yield x1 + (x2 - x1) * t, y1 + (y2 - y1) * t

    def mark(self, layer, x1, y1, x2, y2, net_name):
        for (x, y) in self._samples(x1, y1, x2, y2):
            self.occ[layer][self._k(x, y)] = net_name

    def busy(self, layer, x1, y1, x2, y2, net_name):
        """同层是否已有**别的网络**的铜。

        ⚠️ 余量必须按"线宽 + 规则间距"给足：两条 0.4mm 走线中心距 < 0.6mm 就会
        违反 0.2mm 净间距。这里留 3 格（0.75mm），同网络允许重叠。
        """
        guard = 3
        for (x, y) in self._samples(x1, y1, x2, y2):
            kx, ky = self._k(x, y)
            for dx in range(-guard, guard + 1):
                for dy in range(-guard, guard + 1):
                    owner = self.occ[layer].get((kx + dx, ky + dy))
                    if owner is not None and owner != net_name:
                        return True
        return False

    STEP_Y = 1.0        # 主干 y 间距（≥0.75mm 余量要求）

    def try_direct(self, pa, pb, obstacles, net_name, width, max_len=14.0):
        """短连线直连：一条顶层折线（L 形），不占主干、不打过孔。"""
        x1, y1 = pa.GetPosition().x / 1e6, pa.GetPosition().y / 1e6
        x2, y2 = pb.GetPosition().x / 1e6, pb.GetPosition().y / 1e6
        if math.hypot(x2 - x1, y2 - y1) > max_len:
            return False
        net = pa.GetNet()
        for (cx, cy) in ((x1, y2), (x2, y1)):
            segs = [((x1, y1), (cx, cy)), ((cx, cy), (x2, y2))]
            ok = True
            for ((ax, ay), (bx, by)) in segs:
                if not seg_clear(ax, ay, bx, by, obstacles, SEG_EXTRA) or \
                   self.busy(pcbnew.F_Cu, ax, ay, bx, by, net_name):
                    ok = False
                    break
            if not ok:
                continue
            for ((ax, ay), (bx, by)) in segs:
                track(self.board, ax, ay, bx, by, pcbnew.F_Cu, net, width)
                self.mark(pcbnew.F_Cu, ax, ay, bx, by, net_name)
            return True
        return False

    def route_net(self, net_name, width=TRACK_W, debug=None):
        """把一条网络从起点焊盘链式连到其余焊盘，返回是否全部成功。

        起点优先取核心板母座上的焊盘；没有（例如 +5V 这种只出现在载板上的网络）
        就取最左边的焊盘作起点。"""
        pads = pads_of(self.board, net_name)
        cores = [p for p in pads if p in core_pads(self.board)]
        if len(pads) < 2:
            return False
        a = cores[0] if cores else min(
            pads, key=lambda p: (p.GetPosition().x, p.GetPosition().y))
        net = a.GetNet()
        x1, y1 = a.GetPosition().x / 1e6, a.GetPosition().y / 1e6
        obstacles = []
        for fp in self.board.GetFootprints():
            for p in fp.Pads():
                if p.GetNetname() == net_name:
                    continue
                sz = p.GetSize()
                r = max(sz.x, sz.y) / 2e6            # 焊盘半径（mm）
                obstacles.append((p.GetPosition().x / 1e6,
                                  p.GetPosition().y / 1e6, r))
        row_is_a = y1 < 34.0
        dir1 = -1.0 if row_is_a else 1.0              # A 排向上逃逸 / B 排向下逃逸
        # 逃逸通道：焊盘列的 ±1.27 间隙。A/B 两排 x 重合，所以通道必须"独占"，
        # 不够就往 ±3.81、±6.35… 的间隙挪（45° 斜线自然拉长）。
        xe = ye = None
        for dx in (1.27, -1.27, 3.81, -3.81, 6.35, -6.35, 8.89, -8.89,
                   11.43, -11.43, 13.97, -13.97, 16.51, -16.51):
            cand = round(x1 + dx, 2)
            if cand in self.used_ch:
                continue
            # ⚠️ 必须检查整条 45° 斜线（不是只查端点），否则通道数量会被严重低估
            yc = round(y1 + dir1 * abs(dx), 2)
            if not seg_clear(x1, y1, cand, yc, obstacles, SEG_EXTRA) \
               or self.busy(pcbnew.F_Cu, x1, y1, cand, yc, net_name):
                continue
            xe, ye = cand, yc
            break
        if xe is None:
            self.failed.append("%s 找不到逃逸通道" % net_name)
            return False
        self.used_ch.add(xe)
        ok = True
        # 链式顺序：核心板脚 → 各模块接口 → 测试点（测试点作末梢，走短线）
        others = [p for p in pads if p is not a]
        others.sort(key=lambda p: (p.GetParentFootprint().GetReference().startswith("TP"),
                                   p.GetPosition().x))
        cur = a
        for tp in others:
            prev = cur
            cur = tp
            x1, y1 = prev.GetPosition().x / 1e6, prev.GetPosition().y / 1e6
            x2 = tp.GetPosition().x / 1e6
            y2 = tp.GetPosition().y / 1e6
            ref = tp.GetParentFootprint().GetReference()
            if ref.startswith("TP"):
                # 测试点是末梢：优先短直连
                if self.try_direct(prev, tp, obstacles, net_name, width, max_len=32.0):
                    continue
            bands = [TRUNK_BANDS[ref]] if ref in TRUNK_BANDS else DEFAULT_BANDS
            placed = False
            for (lo, hi) in bands:
                dir2 = -1.0 if lo < y2 else 1.0       # 入线从目标行的哪一侧进来
                # 入线竖直段同样走焊盘列的间隙，两侧择一并独占通道
                xg = None
                for dx in (1.27, -1.27):
                    cand = round(x2 + dx, 2)
                    if cand in self.used_ch:
                        continue
                    if seg_clear(cand, y2 + dir2 * 1.27, cand, y2 + dir2 * 1.27,
                                 obstacles, SEG_EXTRA):
                        xg = cand
                        break
                if xg is None:
                    continue
                yg = round(y2 + dir2 * 1.27, 2)       # 斜入点，落在目标行之外
                y = lo
                while y <= hi + 1e-6:
                    ym = round(y, 2)
                    r1 = not seg_clear(xe, ye, xe, ym, obstacles, SEG_EXTRA) \
                         or self.busy(pcbnew.B_Cu, xe, ye, xe, ym, net_name)
                    r2 = not seg_clear(xe, ym, xg, ym, obstacles, SEG_EXTRA) \
                         or self.busy(pcbnew.F_Cu, xe, ym, xg, ym, net_name)
                    r3 = not seg_clear(xg, ym, xg, yg, obstacles, SEG_EXTRA) \
                         or self.busy(pcbnew.B_Cu, xg, ym, xg, yg, net_name)
                    r4 = not seg_clear(xg, yg, x2, y2, obstacles, SEG_EXTRA) \
                         or self.busy(pcbnew.F_Cu, xg, yg, x2, y2, net_name)
                    if r1 or r2 or r3 or r4:
                        if debug is not None and len(debug) < 16:
                            debug.append("%s → %s y=%.2f 竖直=%d 主干=%d 落线=%d 入线=%d"
                                         % (net_name, ref, ym, r1, r2, r3, r4))
                        y += self.STEP_Y
                        continue
                    track(self.board, x1, y1, xe, ye, pcbnew.F_Cu, net, width)   # ① 逃逸 L1
                    via(self.board, xe, ye, net)
                    track(self.board, xe, ye, xe, ym, pcbnew.B_Cu, net, width)   # ② 竖直 L4
                    via(self.board, xe, ym, net)
                    track(self.board, xe, ym, xg, ym, pcbnew.F_Cu, net, width)   # ③ 主干 L1
                    via(self.board, xg, ym, net)
                    track(self.board, xg, ym, xg, yg, pcbnew.B_Cu, net, width)   # ④ 落线 L4
                    via(self.board, xg, yg, net)
                    track(self.board, xg, yg, x2, y2, pcbnew.F_Cu, net, width)   # ⑤ 斜入 L1
                    self.mark(pcbnew.F_Cu, x1, y1, xe, ye, net_name)
                    self.mark(pcbnew.B_Cu, xe, ye, xe, ym, net_name)
                    self.mark(pcbnew.F_Cu, xe, ym, xg, ym, net_name)
                    self.mark(pcbnew.B_Cu, xg, ym, xg, yg, net_name)
                    self.mark(pcbnew.F_Cu, xg, yg, x2, y2, net_name)
                    self.used_y.add((net_name, ym))
                    self.used_ch.add(xg)
                    placed = True
                    break
                if placed:
                    break
            if not placed:
                ok = False
                self.failed.append(
                    "%s → %s(%.1f,%.1f) 无可用主干；竖直段障碍=%s 主干障碍=%s 落线障碍=%s"
                    % (net_name, ref, x2, y2,
                       not seg_clear(xe, ye, xe, (bands[0][0]), obstacles, 0.45),
                       self.busy(pcbnew.F_Cu, xe, bands[0][0], x2, bands[0][0], net_name),
                       bool([1 for (px, py, _pr) in obstacles
                             if abs(px - x2) < 0.9 and bands[0][0] <= py <= y2])))
        return ok


def write_connection_list(board, path):
    """生成"逐根连线清单"：每条网络要连哪几个焊盘（带脚号与坐标），供手工布线。"""
    groups = {}
    for fp in board.GetFootprints():
        ref = fp.GetReference()
        for pad in pad_physical_order(fp):
            net = pad.GetNetname()
            if net:
                groups.setdefault(net, []).append(
                    (ref, pad.GetNumber(),
                     pad.GetPosition().x / 1e6, pad.GetPosition().y / 1e6))
    planes = ("GND", "+3V3")
    lines = [
        "# 载板 v0 · 逐根连线清单（手工布线用）",
        "",
        "> 由 `tools/pcb/gen_carrier_v0_pcb.py` 生成；坐标是**焊盘中心**（mm）。",
        "> `GND` / `+3V3` 由内层平面连通（L2 / L3），**不需要走线**。",
        "> 建议：短连线先走；横线优先走 L1、竖线优先走 L4；换层按 `V` 打过孔。",
        "",
        "| 网络 | 要连的焊盘（位号-脚号 @坐标） |",
        "|---|---|",
    ]
    nets = [n for n in sorted(groups) if n not in planes]
    for net in nets:
        items = " ／ ".join("%s-%s @(%.2f, %.2f)" % (r, pn, x, y)
                            for (r, pn, x, y) in groups[net])
        lines.append("| `%s` | %s |" % (net, items))
    with open(path, "w", encoding="utf-8", newline="\n") as fp:
        fp.write("\n".join(lines) + "\n")
    print("已生成连线清单: %s（%d 条网络）" % (path, len(nets)))


def main() -> int:
    rc = design.check()
    if rc:
        print("连接表自检未通过，停止生成")
        return rc

    board = pcbnew.BOARD()
    board.SetCopperLayerCount(COPPER_LAYERS)
    for lay in (pcbnew.In1_Cu, pcbnew.In2_Cu):
        board.SetLayerType(lay, pcbnew.LT_SIGNAL)
    print("=== 摆件 ===")
    for (ref, lib, name, nets, x, y, rot, label) in PLACEMENT:
        if nets is None:                       # 核心板母座用连接表的网络
            nets = [design.net_of(lbl) for lbl in
                    (design.HEADER_A if ref == "J_CORE_A" else design.HEADER_B)]
        place(board, ref, lib, name, nets, x, y, rot, label)
        print("  %-10s (%s, %.1f) %s" % (ref, "%g" % x, y, label))

    for (ref, x, y, net) in TESTPOINTS:
        fp = place(board, ref, HEADER_LIB, "PinHeader_1x01_P2.54mm_Vertical", [net],
                   x, y, 0, ref)
        fp.Reference().SetVisible(False)      # 测试点太密，参考号会互相压：由文档索引
        fp.Value().SetVisible(False)
    for (ref, x, y) in MOUNT_HOLES:
        fp = pcbnew.FootprintLoad(MECH_LIB, "MountingHole_3.2mm_M3")
        fp.SetReference(ref)
        fp.SetPosition(pt(x, y))
        board.Add(fp)

    add_outline(board)

    print("=== 走线（竖直走底层 / 水平走顶层 / 拐角过孔）===")
    signal_nets = []
    for (ref, lib, name, nets, x, y, rot, label) in PLACEMENT:
        if nets is None:
            continue
        for n in nets:
            if n not in design.POWER_NETS and n not in signal_nets:
                signal_nets.append(n)
    router = Router(board)
    routed = 0
    if ROUTE_SIGNALS:
        # 先走"从核心板出来的顺序"，靠前的网络先占主干，后面的依次避让
        signal_nets.sort(key=lambda n: min(
            (p.GetPosition().x / 1e6) for p in pads_of(board, n)))
        for net_name in signal_nets:
            if router.route_net(net_name, TRACK_W, router.debug):
                routed += 1
    print("  已走信号网络 %d / %d" % (routed, len(signal_nets)))
    for msg in router.failed:
        print("  [未走通] " + msg)
    for msg in router.debug:
        print("  [调试] " + msg)

    # +5V 选择轨：端子 → JP1(pin2) → C10 → J_EXT 的 +5V_SEL
    if ROUTE_SIGNALS:
        for net_name in ("+5V_SEL", "+5V"):
            n = len(pads_of(board, net_name))
            router.route_net(net_name, PWR_W)
            print("  %s: %d 个焊盘（1.5mm 加粗）" % (net_name, n))

    add_zone(board, pcbnew.In1_Cu, "GND")       # L2：GND 整片
    add_zone(board, pcbnew.In2_Cu, "+3V3")      # L3：+3V3 整片
    filler = pcbnew.ZONE_FILLER(board)
    filler.Fill(board.Zones())

    os.makedirs(os.path.dirname(OUT_PCB), exist_ok=True)
    pcbnew.SaveBoard(OUT_PCB, board)
    print("已生成: %s" % OUT_PCB)
    write_connection_list(board, os.path.join(os.path.dirname(OUT_PCB), "连线清单.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
