import math
import sys

FS = 48000

def freq_to_inc(freq):
    return round(freq * (1 << 32) / FS)

def inc_to_freq(inc):
    return inc * FS / (1 << 32)

def cents_error(f_actual, f_target):
    return 1200 * math.log2(f_actual / f_target)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        f = float(sys.argv[1])
        inc = freq_to_inc(f)
        fa = inc_to_freq(inc)
        err = cents_error(fa, f)
        print(f"f_target = {f:.6f} Hz")
        print(f"inc      = {inc}")
        print(f"f_actual = {fa:.6f} Hz")
        print(f"error    = {err:.6f} cents")
    else:
        max_err = 0
        max_n = 0
        for n in range(21, 109):
            f = 440 * 2 ** ((n - 69) / 12)
            inc = freq_to_inc(f)
            fa = inc_to_freq(inc)
            err = cents_error(fa, f)
            if abs(err) > max_err:
                max_err = abs(err)
                max_n = n
        print("MIDI", max_n, "max error:", max_err, "cents")

