import sys
import wave
import numpy as np

from loom_common import cents_error

def read_wav(path):
    with wave.open(path, "rb") as w:
        fs = w.getframerate()
        n = w.getnframes()
        raw = w.readframes(n)
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    return samples, fs

def find_peak_freq(samples, fs, fft_size=4096, zero_pad=65536):
    n = min(fft_size, len(samples))
    x = samples[:n] * np.hanning(n)
    spectrum = np.abs(np.fft.rfft(x, zero_pad))
    freqs = np.fft.rfftfreq(zero_pad, d=1.0 / fs)
    idx = np.argmax(spectrum)
    return freqs[idx]

if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "sim/out/sine_440.wav"
    expected = float(sys.argv[2]) if len(sys.argv) > 2 else 440.0

    samples, fs = read_wav(path)
    peak = find_peak_freq(samples, fs)

    print(f"file     = {path}")
    print(f"fs       = {fs} Hz")
    print(f"samples  = {len(samples)}")
    print(f"peak     = {peak:.3f} Hz")
    print(f"expected = {expected:.3f} Hz")
    print(f"error    = {cents_error(peak, expected):.3f} cents")
