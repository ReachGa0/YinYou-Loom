"""
adsr_check.py —— analyze sim/out/voice_dump.txt and verify the ADSR shape.

用法：
    python tools/adsr_check.py [dump路径] [期望的 sustain_level]

方法：把波形按"一个音周期"长度的窗口切段，对每段求 RMS，得到平滑的包络曲线。
      窗口必须覆盖完整周期，否则峰值会随相位抖动，平台检测会失准。

检查项：
    1. 开头接近静音
    2. 存在一段上升（Attack）
    3. 存在一段下降（Decay）
    4. 存在一段近似恒定（Sustain），且电平符合 sustain_level 的理论缩放
    5. 末尾下降到接近 0（Release）
"""

import math
import sys

import numpy as np

# 一个音周期 ≈ fs / 440 ≈ 109 个样本
WINDOW = 109


def envelope_rms(data, win=WINDOW):
    """按 win 个样本切段求 RMS，得到平滑包络（正弦波 RMS = 幅度/√2）。"""
    return np.array([
        math.sqrt(float(np.mean(data[i:i + win] ** 2)))
        for i in range(0, len(data) - win + 1, win)
    ])


def find_plateau(env, tol=0.03):
    """找最长的"整段波动小于 tol"的连续段（Sustain），返回 (起点, 长度)。

    判据用 (max - min) / mean，而不是"相邻两点的变化量"：
    线性下降的 Decay 段相邻变化也不大，但整段跨度很大，用跨度才能区分开。
    """
    best_start, best_len = 0, 1
    n = len(env)
    for s in range(n):
        for e in range(s + 2, n + 1):
            seg = env[s:e]
            mean = float(seg.mean())
            if mean <= 0.0:
                break
            spread = (float(seg.max()) - float(seg.min())) / mean
            if spread > tol:
                break
            if (e - s) > best_len:
                best_start, best_len = s, e - s
    return best_start, best_len


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "sim/out/voice_dump.txt"
    expect_sustain = float(sys.argv[2]) if len(sys.argv) > 2 else None

    data = np.loadtxt(path)
    env = envelope_rms(data)

    peak = float(env.max())
    peak_i = int(env.argmax())
    plat_s, plat_len = find_plateau(env)
    plat_v = float(env[plat_s:plat_s + plat_len].mean())

    print(f"file    = {path}")
    print(f"samples = {len(data)}   amp range = {int(data.min())} ~ {int(data.max())}")
    print(f"windows = {len(env)} (each {WINDOW} samples, RMS envelope)")
    print(f"peak    = {peak:.0f} at window {peak_i}")
    print(f"plateau = {plat_v:.0f} (windows {plat_s}..{plat_s + plat_len - 1}, len {plat_len})")
    print()

    print("envelope curve (each '#' = 500):")
    for k, v in enumerate(env):
        print(f"  w{k:3d}  {v:8.0f}  {'#' * int(v / 500)}")
    print()

    ok = True

    cond1 = env[0] < 0.3 * peak
    print(f"[{'PASS' if cond1 else 'FAIL'}] starts at a low level"
          f" (first window {env[0]:.0f} < 30% of peak)")
    ok = ok and cond1

    cond2 = peak_i > 0 and env[peak_i] > env[0]
    print(f"[{'PASS' if cond2 else 'FAIL'}] attack rises ({env[0]:.0f} -> {peak:.0f})")
    ok = ok and cond2

    cond3 = plat_s > peak_i and env[plat_s] < env[peak_i]
    print(f"[{'PASS' if cond3 else 'FAIL'}] decay falls ({env[peak_i]:.0f} -> {plat_v:.0f})")
    ok = ok and cond3

    cond4 = plat_len >= 3
    print(f"[{'PASS' if cond4 else 'FAIL'}] sustain holds flat ({plat_len} windows)")
    ok = ok and cond4

    tail = env[plat_s + plat_len:]
    cond5 = len(tail) > 0 and tail[-1] < 0.05 * peak
    print(f"[{'PASS' if cond5 else 'FAIL'}] release decays to near zero"
          f" (last {tail[-1] if len(tail) else -1:.0f})")
    ok = ok and cond5

    if expect_sustain is not None:
        # 正弦 RMS = 峰值/√2；包络增益 = sustain_level / 65536
        theory = expect_sustain * 32767.0 / 65536.0 / math.sqrt(2.0)
        err = abs(plat_v - theory) / theory * 100.0
        cond6 = err < 5.0
        print(f"[{'PASS' if cond6 else 'FAIL'}] sustain level matches theory"
              f" (measured {plat_v:.0f} vs theory {theory:.0f}, err {err:.1f}%)")
        ok = ok and cond6

    print()
    print("RESULT: " + ("ALL PASS" if ok else "SOME CHECKS FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
