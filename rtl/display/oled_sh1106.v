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
    parameter POR_CYCLES = 27_000_000 / 5      // 上电等待（默认约 200ms）
) (
    input  wire clk,
    input  wire rst_n,
    output wire scl,
    inout  wire sda
);
    // SH1106 从机地址 0x3C，左移一位 + 写标志 = 0x78
    localparam [7:0] I2C_ADDR   = 8'h78;
    localparam [7:0] CTRL_CMD   = 8'h00;       // 控制字节：后面跟命令
    localparam [7:0] CTRL_DATA  = 8'h40;       // 控制字节：后面跟数据

    localparam INIT_LEN = 25;                  // 初始化命令条数（不含 0xAF）

    // ------------------------------------------------------------
    // 初始化命令表（手册 4.4.2「内供 VCC」序列，去掉开显示命令）
    // ------------------------------------------------------------
    function [7:0] init_cmd;
        input [4:0] idx;
        begin
            case (idx)
                5'd0 : init_cmd = 8'hAE;   // display off
                5'd1 : init_cmd = 8'h02;   // 列地址低 4 位（SH1106 从第 2 列开始）
                5'd2 : init_cmd = 8'h10;   // 列地址高 4 位
                5'd3 : init_cmd = 8'h40;   // 显示起始行 = 0
                5'd4 : init_cmd = 8'hB0;   // 页地址 = 0
                5'd5 : init_cmd = 8'h81;   // 对比度设置
                5'd6 : init_cmd = 8'hFF;   //   对比度值
                5'd7 : init_cmd = 8'hA1;   // 段重映射
                5'd8 : init_cmd = 8'hA6;   // 正常显示（非反色）
                5'd9 : init_cmd = 8'hA8;   // 多路复用比
                5'd10: init_cmd = 8'h3F;   //   1/64 duty
                5'd11: init_cmd = 8'hAD;   // 电荷泵
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
    endfunction

    // ------------------------------------------------------------
    // 测试图案：边框
    // ------------------------------------------------------------
    function [7:0] pix_byte;
        input [3:0] pg;
        input [7:0] cx;
        reg   [7:0] b;
        begin
            b = 8'h00;
            if (pg == 4'd0 || pg == 4'd7)
                b = 8'hFF;                 // 上下两条横边
            if (cx == 8'd0)
                b = b | 8'h01;             // 左边框（页内第 0 行）
            if (cx == 8'd127)
                b = b | 8'h80;             // 右边框（页内第 7 行）
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
               PH_ON    = 2'd2;

    reg [2:0]  state;
    reg [1:0]  bstep;         // 事务内字节序号：0=地址 1=控制 2=有效字节
    reg [1:0]  phase;         // PH_INIT / PH_FRAME / PH_ON
    reg [4:0]  init_idx;
    reg [3:0]  page;
    reg [1:0]  pcmd;          // 页设置的三条命令
    reg [7:0]  col;
    reg        writing_data;  // 1 = 正在发页数据
    reg        disp_on_sent;

    reg        m_start;
    reg [7:0]  m_data;
    wire       m_busy;
    wire       m_ack;
    reg        busy_seen;

    localparam POR_W = $clog2(POR_CYCLES + 1);
    reg [POR_W-1:0] por_cnt;

    // ------------------------------------------------------------
    // 当前要发送的三个字节
    // ------------------------------------------------------------
    wire [7:0] page_cmd_byte = (pcmd == 2'd0) ? (8'hB0 | {4'd0, page}) :
                               (pcmd == 2'd1) ? 8'h02 : 8'h10;

    wire [7:0] ctrl_byte = (phase == PH_FRAME && writing_data) ? CTRL_DATA : CTRL_CMD;

    wire [7:0] payload = (phase == PH_INIT)  ? init_cmd(init_idx) :
                         (phase == PH_FRAME) ? (writing_data ? pix_byte(page, col) : page_cmd_byte) :
                         8'hAF;                                  // PH_ON

    wire [7:0] tx_byte = (bstep == 2'd0) ? I2C_ADDR :
                         (bstep == 2'd1) ? ctrl_byte : payload;

    // ------------------------------------------------------------
    // I2C 主机
    // ------------------------------------------------------------
    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .SCL_HZ (SCL_HZ)
    ) u_i2c (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (m_start),
        .data    (m_data),
        .do_stop (1'b1),
        .busy    (m_busy),
        .ack     (m_ack),
        .scl     (scl),
        .sda     (sda)
    );

    // ------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_POR;
            por_cnt      <= {POR_W{1'b0}};
            bstep        <= 2'd0;
            phase        <= PH_INIT;
            init_idx     <= 5'd0;
            page         <= 4'd0;
            pcmd         <= 2'd0;
            col          <= 8'd0;
            writing_data <= 1'b0;
            disp_on_sent <= 1'b0;
            m_start      <= 1'b0;
            m_data       <= 8'd0;
            busy_seen    <= 1'b0;
        end else begin
            case (state)

                S_POR: begin
                    if (por_cnt == POR_CYCLES[POR_W-1:0])
                        state <= S_ISSUE;
                    else
                        por_cnt <= por_cnt + 1'b1;
                end

                S_ISSUE: begin
                    m_data  <= tx_byte;
                    m_start <= 1'b1;
                    busy_seen <= 1'b0;
                    state   <= S_WAIT;
                end

                S_WAIT: begin
                    m_start <= 1'b0;
                    if (m_busy)
                        busy_seen <= 1'b1;
                    else if (busy_seen)
                        state <= S_NEXT;
                end

                S_NEXT: begin
                    if (bstep != 2'd2) begin
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
