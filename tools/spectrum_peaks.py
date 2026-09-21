import sys
import numpy as np

from spectrum import read_wav


def find_top_peaks(samples, fs, count=4, min_sep_hz=20.0, min_freq=80.0):
    n = min(len(samples), 4800)
    x = samples[:n] * np.hanning(n)
    nfft = 65536
    spectrum = np.abs(np.fft.rfft(x, nfft))
    freqs = np.fft.rfftfreq(nfft, d=1.0 / fs)

    spectrum[freqs < min_freq] = 0.0
    peaks = []

    for _ in range(count):
        idx = int(np.argmax(spectrum))
        peak = freqs[idx]
        peaks.append(peak)
        spectrum[(freqs >= peak - min_sep_hz) & (freqs <= peak + min_sep_hz)] = 0.0

    return sorted(peaks)


def main():
    if len(sys.argv) < 3:
        print("usage: spectrum_peaks.py <wav> <freq> [freq ...]")
        return 2

    path = sys.argv[1]
    expected = sorted(float(v) for v in sys.argv[2:])
    samples, fs = read_wav(path)
    peaks = find_top_peaks(samples, fs, count=len(expected))

    ok = len(peaks) == len(expected)
    for actual, target in zip(peaks, expected):
        err = abs(actual - target)
        print(f"peak {actual:8.3f} Hz  expected {target:8.3f} Hz  error {err:6.3f} Hz")
        if err > 12.0:
            ok = False

    if ok and len(peaks) == len(expected):
        print("RESULT: ALL PASS")
        return 0

    print("RESULT: FAIL")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
