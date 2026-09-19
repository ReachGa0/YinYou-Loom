import sys
import wave
import array

from loom_common import FS

def read_samples(path):
    samples = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                samples.append(int(line))
    return samples

def write_wav(samples, path, fs=FS):
    data = array.array('h', samples)
    if sys.byteorder == "big":
        data.byteswap()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(fs)
        w.writeframes(data.tobytes())

if __name__ == "__main__":
    in_path = sys.argv[1] if len(sys.argv) > 1 else "sim/out/sine_440.txt"
    out_path = sys.argv[2] if len(sys.argv) > 2 else "sim/out/sine_440.wav"
    samples = read_samples(in_path)
    print(f"read {len(samples)} samples from {in_path}")
    write_wav(samples, out_path)
    print(f"wrote {out_path}")
