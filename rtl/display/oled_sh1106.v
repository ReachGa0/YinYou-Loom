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
    parameter PATTERN_MODE = 0                 // 0=原测试图案，1=六格调试图案
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
    // 测试图案：2 像素边框 + 中央 7 段式数字 3
    // ------------------------------------------------------------
    function [7:0] pix_byte;
        input [3:0] pg;
        input [7:0] cx;
        input [5:0] bits;
        reg   [7:0] b;
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
            end else begin
                // 六格调试图案：每格约 19 像素宽，bit=1 时填充。
                for (block = 0; block < 6; block = block + 1)
                    if (cx >= block*21 && cx <= block*21 + 18 &&
                        pg >= 4'd1 && pg <= 4'd6)
                        b = bits[block] ? 8'hFF : 8'h00;
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
