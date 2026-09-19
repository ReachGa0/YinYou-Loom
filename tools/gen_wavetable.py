import math
import os

N = 4096
AMP = 32767
FS = 48000
OUT_DIR = "data/wavetables"

def to_hex16(value):
    """
    把 -32767~32767 的整数转换为 4 位的大写十六进制字符串
    """
    if value < 0:
        value = 65536 + value

    return f"{value:04X}"
"""
print(to_hex16(0))
print(to_hex16(32767))
print(to_hex16(-1))
print(to_hex16(-32767))
"""

def make_sine():
    #1. 建一个空列表
    sine = []
    #2. 循环4096次
    for i in range(N):
        #3. 计算 angle = 2 * pi * i / 4096
        angle = 2 * math.pi * i / N
        #4. 计算 value = round(AMP * math.sin(angle))
        value = round(AMP * math.sin(angle))
        #5. 把 value 追加到 table
        sine.append(value)
    #6. 返回 table
    return sine
"""
sine = make_sine()
print(len(sine))
print(sine[0], sine[1024], sine[2048], sine[3072])
"""

def make_saw():
    saw = []
    for i in range(N):
        value = round(-AMP + 2 * AMP * i / N)
        saw.append(value)
    return saw
"""
saw = make_saw()
print(saw[0], saw[int(N/4)], saw[int(N/2)], saw[int(3*N/4)], saw[N-1])
"""

def make_triangle():
    triangle = []
    for i in range(N):
        if i < N // 2:
            value = round(-AMP + 4 * AMP * i / N)
        else:
            value = round(AMP - 4 * AMP * (i - N // 2) / N)
        triangle.append(value)
    return triangle
"""
triangle = make_triangle()
print(triangle[0], triangle[int(N/4)], triangle[int(N/2)], triangle[int(3*N/4)], triangle[N-1])
"""

def make_square():
    square = []
    for i in range(N):
        if i < N // 2:
            value = AMP
        else:
            value = -AMP
        square.append(value)
    return square
"""
square = make_square()
print(square[0], square[int(N/4)], square[int(N/2)], square[int(3*N/4)], square[N-1])
"""

def write_hex(filename, table):
    path = os.path.join(OUT_DIR, filename)
    with open(path, "w") as f:
        for value in table:
            f.write(to_hex16(value) + "\n")

if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    write_hex("sine_4096x16.hex", make_sine())
    write_hex("saw_4096x16.hex", make_saw())
    write_hex("triangle_4096x16.hex", make_triangle())
    write_hex("square_4096x16.hex", make_square())
    print("done: 4 wavetables written to", OUT_DIR)
    