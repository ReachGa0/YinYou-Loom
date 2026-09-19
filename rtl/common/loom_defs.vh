// ============================================================
// loom_defs.vh —— 吟游 Loom Verilog 公共常量
// 用法：在 RTL / testbench 里 `include "loom_defs.vh"
//       编译时加：iverilog -I rtl/common ...
// ============================================================

`ifndef LOOM_DEFS_VH
`define LOOM_DEFS_VH

// ---- 音频与波表 ----
`define FS          48000          // 采样率 48kHz
`define PHASE_BITS  32             // 相位累加器位宽
`define TABLE_BITS  12             // 波表地址位宽
`define TABLE_SIZE  4096           // 1 << TABLE_BITS
`define AMP         32767          // 16bit 有符号峰值

// ---- 常用调音字 ----
`define INC_440     32'd39370534  // 440Hz @ 48kHz

// ---- 波表文件路径（相对仓库根目录）----
`define WAVETABLE_SINE      "data/wavetables/sine_4096x16.hex"
`define WAVETABLE_SAW       "data/wavetables/saw_4096x16.hex"
`define WAVETABLE_TRIANGLE  "data/wavetables/triangle_4096x16.hex"
`define WAVETABLE_SQUARE    "data/wavetables/square_4096x16.hex"

`endif // LOOM_DEFS_VH
