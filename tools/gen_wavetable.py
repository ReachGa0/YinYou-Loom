import math
import os

from loom_common import TABLE_SIZE, AMP, to_hex16

N = TABLE_SIZE
OUT_DIR = "data/wavetables"


def make_sine():
    table = []
    for i in range(N):
        angle = 2 * math.pi * i / N
        value = round(AMP * math.sin(angle))
        table.append(value)
    return table


def make_saw():
    table = []
    for i in range(N):
        value = round(-AMP + 2 * AMP * i / N)
        table.append(value)
    return table


def make_triangle():
    table = []
    for i in range(N):
        if i < N // 2:
            value = round(-AMP + 4 * AMP * i / N)
        else:
            value = round(AMP - 4 * AMP * (i - N // 2) / N)
        table.append(value)
    return table


def make_square():
    table = []
    for i in range(N):
        if i < N // 2:
            value = AMP
        else:
            value = -AMP
        table.append(value)
    return table


def write_hex(filename, table):
    path = os.path.join(OUT_DIR, filename)
    with open(path, "w") as f:
        for value in table:
            f.write(to_hex16(value) + "\n")


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    write_hex(f"sine_{TABLE_SIZE}x16.hex", make_sine())
    write_hex(f"saw_{TABLE_SIZE}x16.hex", make_saw())
    write_hex(f"triangle_{TABLE_SIZE}x16.hex", make_triangle())
    write_hex(f"square_{TABLE_SIZE}x16.hex", make_square())
    print("done: 4 wavetables written to", OUT_DIR)
