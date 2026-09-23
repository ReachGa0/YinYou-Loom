// ============================================================
// oled_sh1106.v —— SH1106 (128x64, I2C) 显示控制器
//
// 上电流程：等待 → 初始化命令 → 写第一帧 → 开显示(0xAF) → 循环刷新
//
// 里程碑 1 的测试图案是"边框"：能暴露列偏移 / 页地址错误。
//
// 说明：每个字节走一次独立的 I2C 事务（START...STOP），逻辑简单、时序宽容，
//       代价是刷新较慢（100kHz 下约 8 fps）。速度优化留到屏幕点亮之后。
// ============================================================

module oled_sh1106 #(
    parameter CLK_HZ     = 27_000_000,
    parameter SCL_HZ     = 100_000,
    parameter POR_CYCLES = 27_000_000 / 5,     // 上电等待（默认约 200ms）
    parameter PATTERN_MODE = 0                 // 0=原测试图案，1=六格调试图案，2=状态文字
) (
    input  wire clk,
    input  wire rst_n,
    input  wire ssd1306_mode,       // 1 = 用 SSD1306 初始化序列，0 = SH1106
    input  wire [5:0] indicator_bits,
    output wire scl,
    inout  wire sda,
    output wire [1:0] dbg_phase,    // 调试用：0=初始化 1=刷屏 2=开显示
    output reg        dbg_ack_seen  // 调试用：只要收到过一次从机应答就置 1
);
    // SH1106 从机地址 0x3C，左移一位 + 写标志 = 0x78
    localparam [7:0] I2C_ADDR   = 8'h78;
    localparam [7:0] CTRL_CMD   = 8'h00;       // 控制字节：后面跟命令
    localparam [7:0] CTRL_DATA  = 8'h40;       // 控制字节：后面跟数据

    localparam INIT_LEN = 25;                  // 初始化命令条数（不含 0xAF）

    // ------------------------------------------------------------
    // 初始化命令表（都不含开显示 0xAF，它在第一帧写完后单独发）
    //
    // 模块手册自相矛盾：机械图写 SSD1306，命令章节却指向 SH1106，
    // 初始化序列用的是 SH1106 专有的 0xAD。因此这里两种都实现，
    // 由 ssd1306_mode 选择，方便实机确认。
    //
    //   SH1106 ：电荷泵用 0xAD,0x8B；可见区从第 2 列开始（列地址 0x02）
    //   SSD1306：电荷泵用 0x8D,0x14；可见区从第 0 列开始；页寻址模式 0x20,0x02
    // ------------------------------------------------------------
    function [7:0] init_cmd;
        input [4:0] idx;
        begin
            if (ssd1306_mode) begin
                case (idx)
                    5'd0 : init_cmd = 8'hAE;   // display off
                    5'd1 : init_cmd = 8'hD5;   // 时钟分频
                    5'd2 : init_cmd = 8'h80;
                    5'd3 : init_cmd = 8'hA8;   // 多路复用比
                    5'd4 : init_cmd = 8'h3F;   //   1/64
                    5'd5 : init_cmd = 8'hD3;   // 显示偏移
                    5'd6 : init_cmd = 8'h00;
                    5'd7 : init_cmd = 8'h40;   // 显示起始行 0
                    5'd8 : init_cmd = 8'h8D;   // 电荷泵（SSD1306 用 0x8D）
                    5'd9 : init_cmd = 8'h14;   //   使能
                    5'd10: init_cmd = 8'h20;   // 寻址模式
                    5'd11: init_cmd = 8'h02;   //   页寻址（与 SH1106 写法一致）
                    5'd12: init_cmd = 8'hA1;   // 段重映射
                    5'd13: init_cmd = 8'hC8;   // COM 扫描方向反向
                    5'd14: init_cmd = 8'hDA;   // COM 引脚配置
                    5'd15: init_cmd = 8'h12;
                    5'd16: init_cmd = 8'h81;   // 对比度
                    5'd17: init_cmd = 8'hCF;
                    5'd18: init_cmd = 8'hD9;   // 预充电周期
                    5'd19: init_cmd = 8'hF1;
                    5'd20: init_cmd = 8'hDB;   // VCOMH
                    5'd21: init_cmd = 8'h40;
                    5'd22: init_cmd = 8'hA4;   // 恢复显示 RAM 内容
                    5'd23: init_cmd = 8'hA6;   // 正常显示（非反色）
                    5'd24: init_cmd = 8'h00;   // 补位：低列地址 0（无害）
                    default: init_cmd = 8'h00;
                endcase
            end else begin
                case (idx)
                    5'd0 : init_cmd = 8'hAE;   // display off
                    5'd1 : init_cmd = 8'h02;   // 列地址低 4 位（本模块从第 2 列开始）
                    5'd2 : init_cmd = 8'h10;   // 列地址高 4 位
                    5'd3 : init_cmd = 8'h40;   // 显示起始行 = 0
                    5'd4 : init_cmd = 8'hB0;   // 页地址 = 0
                    5'd5 : init_cmd = 8'h81;   // 对比度设置
                    5'd6 : init_cmd = 8'hFF;   //   对比度值
                    5'd7 : init_cmd = 8'hA1;   // 段重映射
                    5'd8 : init_cmd = 8'hA6;   // 正常显示（非反色）
                    5'd9 : init_cmd = 8'hA8;   // 多路复用比
                    5'd10: init_cmd = 8'h3F;   //   1/64 duty
                    5'd11: init_cmd = 8'hAD;   // 电荷泵（SH1106 用 0xAD）
                    5'd12: init_cmd = 8'h8B;   //   内部 VCC
                    5'd13: init_cmd = 8'h33;   //   VPP = 9V
                    5'd14: init_cmd = 8'hC8;   // COM 扫描方向反向
                    5'd15: init_cmd = 8'hD3;   // 显示偏移
                    5'd16: init_cmd = 8'h00;
                    5'd17: init_cmd = 8'hD5;   // 时钟分频
                    5'd18: init_cmd = 8'h80;
                    5'd19: init_cmd = 8'hD9;   // 预充电周期
                    5'd20: init_cmd = 8'h1F;
                    5'd21: init_cmd = 8'hDA;   // COM 引脚配置
                    5'd22: init_cmd = 8'h12;
                    5'd23: init_cmd = 8'hDB;   // VCOMH
                    5'd24: init_cmd = 8'h40;
                    default: init_cmd = 8'h00;
                endcase
            end
        end
    endfunction

    // ------------------------------------------------------------
    // PATTERN_MODE=2：小型状态页。indicator_bits 编码：
    //   [0]   timbre：0=SINE，1=SQUARE
    //   [1]   bypass：0=CHORUS，1=DRY
    //   [5:2] 当前按键数 0..4
    // ------------------------------------------------------------
    function [7:0] status_char;
        input [2:0] line;
        input [4:0] pos;
        input [5:0] bits;
        reg [7:0] ch;
        begin
            ch = 8'h20;
            case (line)
                3'd0: begin // TIMBRE ...
                    case (pos)
                        4'd0: ch = 8'h54; // T
                        4'd1: ch = 8'h49; // I
                        4'd2: ch = 8'h4D; // M
                        4'd3: ch = 8'h42; // B
                        4'd4: ch = 8'h52; // R
                        4'd5: ch = 8'h45; // E
                        4'd6: ch = 8'h20;
                        4'd7: ch = bits[0] ? 8'h53 : 8'h53; // S
                        4'd8: ch = bits[0] ? 8'h51 : 8'h49; // Q / I
                        4'd9: ch = bits[0] ? 8'h55 : 8'h4E; // U / N
                        4'd10: ch = bits[0] ? 8'h41 : 8'h45; // A / E
                        4'd11: ch = bits[0] ? 8'h52 : 8'h20; // R / space
                        4'd12: ch = bits[0] ? 8'h45 : 8'h20; // E / space
                        default: ch = 8'h20;
                    endcase
                end
                3'd2: begin // FX ...
                    case (pos)
                        4'd0: ch = 8'h46; // F
                        4'd1: ch = 8'h58; // X
                        4'd2: ch = 8'h20;
                        4'd3: ch = bits[1] ? 8'h44 : 8'h43; // D / C
                        4'd4: ch = bits[1] ? 8'h52 : 8'h48; // R / H
                        4'd5: ch = bits[1] ? 8'h59 : 8'h4F; // Y / O
                        4'd6: ch = bits[1] ? 8'h20 : 8'h52; // space / R
                        4'd7: ch = bits[1] ? 8'h20 : 8'h55; // space / U
                        4'd8: ch = bits[1] ? 8'h20 : 8'h53; // space / S
                        default: ch = 8'h20;
                    endcase
                end
                3'd4: begin // VOICE n/4
                    case (pos)
                        4'd0: ch = 8'h56; // V
                        4'd1: ch = 8'h4F; // O
                        4'd2: ch = 8'h49; // I
                        4'd3: ch = 8'h43; // C
                        4'd4: ch = 8'h45; // E
                        4'd5: ch = 8'h20;
                        4'd6: ch = 8'h30 + bits[5:2];
                        4'd7: ch = 8'h2F; // /
                        4'd8: ch = 8'h34; // 4
                        default: ch = 8'h20;
                    endcase
                end
                default: ch = 8'h20;
            endcase
            status_char = ch;
        end
    endfunction

    // ------------------------------------------------------------
    // PATTERN_MODE=3：P6 状态页。indicator_bits 编码：
    //   [0]   0=演奏 PERF，1=测试 TEST
    //   [1]   音色 0=SINE，1=SQUARE
    //   [2]   效果 1=DRY，0=CHORUS
    //   [5:3] 仍在发声的声部数 0..4
    // 现有字模只覆盖 / 0-4 与 A B C D E F H I M N O P Q R S T U V X Y，
    // 没有 5 6 7 8 9 与 G J K L W Z，所以本页用词刻意避开了这些字符。
    // ------------------------------------------------------------
    function [7:0] test_status_char;
        input [2:0] line;
        input [4:0] pos;
        input [5:0] bits;
        reg [7:0] ch;
        begin
            ch = 8'h20;
            if (line == 3'd0) begin          // TEST MODE / PERF MODE
                case (pos)
                    4'd0: ch = bits[0] ? 8'h54 : 8'h50; // T / P
                    4'd1: ch = 8'h45;                   // E
                    4'd2: ch = bits[0] ? 8'h53 : 8'h52; // S / R
                    4'd3: ch = bits[0] ? 8'h54 : 8'h46; // T / F
                    4'd5: ch = 8'h4D;                   // M
                    4'd6: ch = 8'h4F;                   // O
                    4'd7: ch = 8'h44;                   // D
                    4'd8: ch = 8'h45;                   // E
                    default: ch = 8'h20;
                endcase
            end else if (line == 3'd2) begin // VOICE n/4
                case (pos)
                    4'd0: ch = 8'h56;                   // V
                    4'd1: ch = 8'h4F;                   // O
                    4'd2: ch = 8'h49;                   // I
                    4'd3: ch = 8'h43;                   // C
                    4'd4: ch = 8'h45;                   // E
                    4'd6: ch = 8'h30 + bits[5:3];       // 音数 0..4
                    4'd7: ch = 8'h2F;                   // /
                    4'd8: ch = 8'h34;                   // 4
                    default: ch = 8'h20;
                endcase
            end else if (line == 3'd4) begin
                if (bits[0]) begin                   // 4 NONHARM TONE
                    case (pos)
                        4'd0: ch = 8'h34;               // 4
                        4'd2: ch = 8'h4E;               // N
                        4'd3: ch = 8'h4F;               // O
                        4'd4: ch = 8'h4E;               // N
                        4'd5: ch = 8'h48;               // H
                        4'd6: ch = 8'h41;               // A
                        4'd7: ch = 8'h52;               // R
                        4'd8: ch = 8'h4D;               // M
                        4'd10: ch = 8'h54;              // T
                        4'd11: ch = 8'h4F;              // O
                        4'd12: ch = 8'h4E;              // N
                        4'd13: ch = 8'h45;              // E
                        default: ch = 8'h20;
                    endcase
                end else begin                       // SINE DRY / SQUA CHOR
                    case (pos)
                        4'd0: ch = 8'h53;               // S
                        4'd1: ch = bits[1] ? 8'h51 : 8'h49; // Q / I
                        4'd2: ch = bits[1] ? 8'h55 : 8'h4E; // U / N
                        4'd3: ch = bits[1] ? 8'h41 : 8'h45; // A / E
                        4'd5: ch = bits[2] ? 8'h44 : 8'h43; // D / C
                        4'd6: ch = bits[2] ? 8'h52 : 8'h48; // R / H
                        4'd7: ch = bits[2] ? 8'h59 : 8'h4F; // Y / O
                        4'd8: ch = bits[2] ? 8'h20 : 8'h52; // sp / R
                        default: ch = 8'h20;
                    endcase
                end
            end
            test_status_char = ch;
        end
    endfunction

    // 标准 5x7 点阵的 5 个列字节；每个列字节的 bit0 是最上面一行。
    function [6:0] glyph_col;
        input [7:0] ch;
        input [2:0] col;
        reg [6:0] g;
        begin
            case (ch)
                8'h41: case (col) 0:g=7'h7E; 1:g=7'h11; 2:g=7'h11; 3:g=7'h11; default:g=7'h7E; endcase // A
                8'h42: case (col) 0:g=7'h7F; 1:g=7'h49; 2:g=7'h49; 3:g=7'h49; default:g=7'h36; endcase // B
                8'h43: case (col) 0:g=7'h3E; 1:g=7'h41; 2:g=7'h41; 3:g=7'h41; default:g=7'h22; endcase // C
                8'h44: case (col) 0:g=7'h7F; 1:g=7'h41; 2:g=7'h41; 3:g=7'h22; default:g=7'h1C; endcase // D
                8'h45: case (col) 0:g=7'h7F; 1:g=7'h49; 2:g=7'h49; 3:g=7'h49; default:g=7'h41; endcase // E
                8'h46: case (col) 0:g=7'h7F; 1:g=7'h09; 2:g=7'h09; 3:g=7'h09; default:g=7'h01; endcase // F
                8'h48: case (col) 0:g=7'h7F; 1:g=7'h08; 2:g=7'h08; 3:g=7'h08; default:g=7'h7F; endcase // H
                8'h49: case (col) 0:g=7'h00; 1:g=7'h41; 2:g=7'h7F; 3:g=7'h41; default:g=7'h00; endcase // I
                8'h4D: case (col) 0:g=7'h7F; 1:g=7'h02; 2:g=7'h0C; 3:g=7'h02; default:g=7'h7F; endcase // M
                8'h4E: case (col) 0:g=7'h7F; 1:g=7'h04; 2:g=7'h08; 3:g=7'h10; default:g=7'h7F; endcase // N
                8'h4F: case (col) 0:g=7'h3E; 1:g=7'h41; 2:g=7'h41; 3:g=7'h41; default:g=7'h3E; endcase // O
                8'h50: case (col) 0:g=7'h7F; 1:g=7'h09; 2:g=7'h09; 3:g=7'h09; default:g=7'h06; endcase // P
                8'h51: case (col) 0:g=7'h3E; 1:g=7'h41; 2:g=7'h51; 3:g=7'h21; default:g=7'h5E; endcase // Q
                8'h52: case (col) 0:g=7'h7F; 1:g=7'h09; 2:g=7'h19; 3:g=7'h29; default:g=7'h46; endcase // R
                8'h53: case (col) 0:g=7'h46; 1:g=7'h49; 2:g=7'h49; 3:g=7'h49; default:g=7'h31; endcase // S
                8'h54: case (col) 0:g=7'h01; 1:g=7'h01; 2:g=7'h7F; 3:g=7'h01; default:g=7'h01; endcase // T
                8'h55: case (col) 0:g=7'h3F; 1:g=7'h40; 2:g=7'h40; 3:g=7'h40; default:g=7'h3F; endcase // U
                8'h56: case (col) 0:g=7'h1F; 1:g=7'h20; 2:g=7'h40; 3:g=7'h20; default:g=7'h1F; endcase // V
                8'h58: case (col) 0:g=7'h63; 1:g=7'h14; 2:g=7'h08; 3:g=7'h14; default:g=7'h63; endcase // X
                8'h59: case (col) 0:g=7'h07; 1:g=7'h08; 2:g=7'h70; 3:g=7'h08; default:g=7'h07; endcase // Y
                8'h30: case (col) 0:g=7'h3E; 1:g=7'h51; 2:g=7'h49; 3:g=7'h45; default:g=7'h3E; endcase // 0
                8'h31: case (col) 0:g=7'h00; 1:g=7'h42; 2:g=7'h7F; 3:g=7'h40; default:g=7'h00; endcase // 1
                8'h32: case (col) 0:g=7'h42; 1:g=7'h61; 2:g=7'h51; 3:g=7'h49; default:g=7'h46; endcase // 2
                8'h33: case (col) 0:g=7'h21; 1:g=7'h41; 2:g=7'h45; 3:g=7'h4B; default:g=7'h31; endcase // 3
                8'h34: case (col) 0:g=7'h18; 1:g=7'h14; 2:g=7'h12; 3:g=7'h7F; default:g=7'h10; endcase // 4
                8'h2F: case (col) 0:g=7'h20; 1:g=7'h10; 2:g=7'h08; 3:g=7'h04; default:g=7'h02; endcase // /
                default: g = 7'h00;
            endcase
            glyph_col = g;
        end
    endfunction

    // ------------------------------------------------------------
    // 测试图案：2 像素边框 + 中央 7 段式数字 3
    // ------------------------------------------------------------
    function [7:0] pix_byte;
        input [3:0] pg;
        input [7:0] cx;
        input [5:0] bits;
        reg   [7:0] b;
        reg   [2:0] char_col;
        integer char_pos;
        reg   [7:0] ch;
        reg   [6:0] glyph;
        integer block;
        begin
            b = 8'h00;
            if (PATTERN_MODE == 0) begin
                if (pg == 4'd0)
                    b = 8'h03;                 // 顶部 2 行像素
                if (pg == 4'd7)
                    b = 8'hC0;                 // 底部 2 行像素
                if (cx == 8'd0 || cx == 8'd1 ||
                    cx == 8'd126 || cx == 8'd127)
                    b = 8'hFF;                 // 左右各 2 列像素

                // 7 段式数字 3：水平段 x=40..87，右侧竖段 x=82..87
                case (pg)
                    4'd1: b = b |
                        ((cx >= 8'd40 && cx <= 8'd87) ? 8'h3F : 8'h00) |
                        ((cx >= 8'd82 && cx <= 8'd87) ? 8'hC0 : 8'h00);
                    4'd2: b = b |
                        ((cx >= 8'd82 && cx <= 8'd87) ? 8'hFF : 8'h00);
                    4'd3: b = b |
                        ((cx >= 8'd82 && cx <= 8'd87) ? 8'h1F : 8'h00) |
                        ((cx >= 8'd40 && cx <= 8'd87) ? 8'hE0 : 8'h00);
                    4'd4: b = b |
                        ((cx >= 8'd40 && cx <= 8'd87) ? 8'h07 : 8'h00) |
                        ((cx >= 8'd82 && cx <= 8'd87) ? 8'hF8 : 8'h00);
                    4'd5: b = b |
                        ((cx >= 8'd82 && cx <= 8'd87) ? 8'hFF : 8'h00);
                    4'd6: b = b |
                        ((cx >= 8'd82 && cx <= 8'd87) ? 8'h03 : 8'h00) |
                        ((cx >= 8'd40 && cx <= 8'd87) ? 8'hFC : 8'h00);
                    default: b = b;
                endcase
            end else if (PATTERN_MODE == 1) begin
                // 六格调试图案：每格约 19 像素宽，bit=1 时填充。
                for (block = 0; block < 6; block = block + 1)
                    if (cx >= block*21 && cx <= block*21 + 18 &&
                        pg >= 4'd1 && pg <= 4'd6)
                        b = bits[block] ? 8'hFF : 8'h00;
            end else begin
                // 状态文字：page 0/2/4 各承载一整行 5x7 字模。
                if ((pg == 4'd0 || pg == 4'd2 || pg == 4'd4) && cx >= 8'd4) begin
                    char_col = (cx - 8'd4) % 6;
                    char_pos = (cx - 8'd4) / 6;
                    if (char_col < 3'd5) begin
                        ch      = (PATTERN_MODE == 3)
                                ? test_status_char(pg[2:0], char_pos[4:0], bits)
                                : status_char(pg[2:0], char_pos[4:0], bits);
                        glyph   = glyph_col(ch, char_col);
                        b       = {1'b0, glyph};
                    end
                end
            end
            pix_byte = b;
        end
    endfunction

    // ------------------------------------------------------------
    // 状态与寄存器
    // ------------------------------------------------------------
    localparam S_POR   = 3'd0,
               S_ISSUE = 3'd1,
               S_WAIT  = 3'd2,
               S_NEXT  = 3'd3;

    localparam PH_INIT  = 2'd0,
               PH_FRAME = 2'd1,
               PH_ON    = 2'd2,
               PH_PROBE = 2'd3;   // 上电先探测从机地址

    reg [2:0]  state;
    reg [1:0]  bstep;         // 事务内字节序号：0=地址 1=控制 2=有效字节
    reg [1:0]  phase;         // PH_INIT / PH_FRAME / PH_ON
    reg [4:0]  init_idx;
    reg [3:0]  page;
    reg [1:0]  pcmd;          // 页设置的三条命令
    reg [7:0]  col;
    reg        writing_data;  // 1 = 正在发页数据
    reg        disp_on_sent;

    reg        m_req;
    reg [7:0]  m_data;
    wire       m_busy;
    wire       m_done;
    wire       m_ack;

    // 从机地址自动探测：先试 0x3C（0x78），不应答再试 0x3D（0x7A）
    reg [7:0]  addr_reg  = 8'h78;
    reg        probe_idx = 1'b0;
    wire [7:0] probe_addr = probe_idx ? 8'h7A : 8'h78;

    // 一次事务固定三个字节：0=从机地址 1=控制字节 2=有效字节
    // 探测阶段是单字节事务（同时带 START 和 STOP）
    wire m_first = (phase == PH_PROBE) ? 1'b1 : (bstep == 2'd0);
    wire m_last  = (phase == PH_PROBE) ? 1'b1 : (bstep == 2'd2);

    localparam POR_W = $clog2(POR_CYCLES + 1);
    reg [POR_W-1:0] por_cnt;

    // ------------------------------------------------------------
    // 当前要发送的三个字节
    // ------------------------------------------------------------
    // 本模块实测可见区相对数据右偏 2 列，需要从控制器列 2 开始
    wire [7:0] col_lo = 8'h02;

    wire [7:0] page_cmd_byte = (pcmd == 2'd0) ? (8'hB0 | {4'd0, page}) :
                               (pcmd == 2'd1) ? col_lo : 8'h10;

    wire [7:0] ctrl_byte = (phase == PH_FRAME && writing_data) ? CTRL_DATA : CTRL_CMD;

    wire [7:0] payload = (phase == PH_INIT)  ? init_cmd(init_idx) :
                         (phase == PH_FRAME) ? (writing_data ? pix_byte(page, col, indicator_bits) : page_cmd_byte) :
                         8'hAF;                                  // PH_ON

    wire [7:0] tx_byte = (phase == PH_PROBE) ? probe_addr :
                         (bstep == 2'd0) ? addr_reg :
                         (bstep == 2'd1) ? ctrl_byte : payload;

    assign dbg_phase = phase;

    // 收到过一次 ACK（ack==0）就锁存，供 LED 指示
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dbg_ack_seen <= 1'b0;
        else if (m_done && !m_ack)
            dbg_ack_seen <= 1'b1;
    end

    // ------------------------------------------------------------
    // I2C 主机
    // ------------------------------------------------------------
    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .SCL_HZ (SCL_HZ)
    ) u_i2c (
        .clk   (clk),
        .rst_n (rst_n),
        .req   (m_req),
        .first (m_first),
        .last  (m_last),
        .data  (m_data),
        .busy  (m_busy),
        .done  (m_done),
        .ack   (m_ack),
        .scl   (scl),
        .sda   (sda)
    );

    // ------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_POR;
            por_cnt      <= {POR_W{1'b0}};
            bstep        <= 2'd0;
            phase        <= PH_PROBE;
            addr_reg     <= 8'h78;
            probe_idx    <= 1'b0;
            init_idx     <= 5'd0;
            page         <= 4'd0;
            pcmd         <= 2'd0;
            col          <= 8'd0;
            writing_data <= 1'b0;
            disp_on_sent <= 1'b0;
            m_req        <= 1'b0;
            m_data       <= 8'd0;
        end else begin
            case (state)

                S_POR: begin
                    if (por_cnt == POR_CYCLES[POR_W-1:0])
                        state <= S_ISSUE;
                    else
                        por_cnt <= por_cnt + 1'b1;
                end

                S_ISSUE: begin
                    m_data <= tx_byte;
                    m_req  <= 1'b1;
                    state  <= S_WAIT;
                end

                S_WAIT: begin
                    m_req <= 1'b0;
                    if (m_done)
                        state <= S_NEXT;
                end

                S_NEXT: begin
                    if (phase == PH_PROBE) begin
                        // 探测：每字节一个独立事务
                        bstep <= 2'd0;
                        if (!m_ack) begin              // 收到 ACK → 采用这个地址
                            addr_reg  <= probe_addr;
                            probe_idx <= 1'b0;
                            phase     <= PH_INIT;
                        end else if (probe_idx) begin  // 两个地址都没应答
                            addr_reg  <= 8'h78;
                            probe_idx <= 1'b0;
                            phase     <= PH_INIT;
                        end else begin
                            probe_idx <= 1'b1;         // 试下一个地址
                        end
                        state <= S_ISSUE;
                    end else if (bstep != 2'd2) begin
                        bstep <= bstep + 1'b1;
                    end else begin
                        bstep <= 2'd0;
                        case (phase)

                            PH_INIT: begin
                                if (init_idx == INIT_LEN - 1) begin
                                    init_idx     <= 5'd0;
                                    phase        <= PH_FRAME;
                                    page         <= 4'd0;
                                    pcmd         <= 2'd0;
                                    writing_data <= 1'b0;
                                end else begin
                                    init_idx <= init_idx + 1'b1;
                                end
                            end

                            PH_FRAME: begin
                                if (!writing_data) begin
                                    if (pcmd == 2'd2) begin
                                        pcmd         <= 2'd0;
                                        col          <= 8'd0;
                                        writing_data <= 1'b1;
                                    end else begin
                                        pcmd <= pcmd + 1'b1;
                                    end
                                end else begin
                                    if (col == 8'd127) begin
                                        col          <= 8'd0;
                                        writing_data <= 1'b0;
                                        if (page == 4'd7) begin
                                            page <= 4'd0;
                                            if (!disp_on_sent)
                                                phase <= PH_ON;      // 第一帧写完 → 开显示
                                        end else begin
                                            page <= page + 1'b1;
                                        end
                                    end else begin
                                        col <= col + 1'b1;
                                    end
                                end
                            end

                            PH_ON: begin
                                disp_on_sent <= 1'b1;
                                phase        <= PH_FRAME;
                                page         <= 4'd0;
                                pcmd         <= 2'd0;
                                writing_data <= 1'b0;
                            end

                            default: phase <= PH_INIT;

                        endcase
                    end
                    state <= S_ISSUE;
                end

                default: state <= S_POR;

            endcase
        end
    end

endmodule
