// ============================================================
// font8x16_rom.v —— 8×16 ASCII 字库 ROM（同步读，推断为 BSRAM）
//
// 数据由 tools/gen_font8x16.py 生成：data/fonts/font8x16.hex
//   地址 = (字符码 - 0x20) * 16 + 行号      96 字符 × 16 行 = 1536 字节
//   行内 bit7 = 最左像素，bit0 = 最右像素
//
// 推断 BSRAM 的写法要点（见 docs/19 案例 3）：同步读 + 数据路径不带复位。
//
// ⚠️ $readmemh 找不到文件时只报警告、ROM 会静默变成全 0（屏幕上的字全空），
//    所以每次综合后必须看日志里有没有 readmemh 的告警（loom_top.v 里也有同类提醒）。
//    路径按"调用 gw_sh 的目录"解析 = 仓库根目录。
// ============================================================

module font8x16_rom #(
    parameter INIT_FILE = "../../data/fonts/font8x16.hex"
)(
    input  wire        clk,
    input  wire [10:0] addr,       // 0..1535
    output reg  [7:0]  data        // 比 addr 晚 1 拍
);

    reg [7:0] mem [0:1535];

    initial begin
        $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        data <= mem[addr];
    end

endmodule
