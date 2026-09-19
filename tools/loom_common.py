"""
loom_common.py —— 吟游 Loom 的 Python 公共模块

把跨脚本使用的常量与函数集中在这里，避免重复定义和参数顺序写错。
其他脚本用法：
    from loom_common import FS, TABLE_SIZE, AMP, freq_to_inc, inc_to_freq, cents_error
"""

import math

# ---- 音频与波表常量 ----
FS = 48000                      # 采样率 (Hz)
PHASE_BITS = 32                 # 相位累加器位宽
TABLE_BITS = 12                 # 波表地址位宽
TABLE_SIZE = 1 << TABLE_BITS    # 4096
AMP = 32767                     # 16bit 有符号峰值
PHASE_MOD = 1 << PHASE_BITS     # 2^32 = 4294967296


def freq_to_inc(freq: float, fs: int = FS) -> int:
    """把频率(Hz)换算成 32bit 相位累加器的调音字。"""
    return round(freq * PHASE_MOD / fs)


def inc_to_freq(inc: int, fs: int = FS) -> float:
    """把调音字换算回实际频率(Hz)。"""
    return inc * fs / PHASE_MOD


def cents_error(f_actual: float, f_target: float) -> float:
    """返回实际频率相对目标频率的音分误差；正数=偏高，负数=偏低。"""
    return 1200.0 * math.log2(f_actual / f_target)


def to_hex16(value: int) -> str:
    """把 -32768..32767 的整数转成 4 位大写十六进制（16bit 补码）。"""
    if value < 0:
        value = 65536 + value
    return f"{value:04X}"
