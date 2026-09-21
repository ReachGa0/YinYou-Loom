// ============================================================
// wavetable_arbiter.v —— 多声部共享波表仲裁器
//
// 每个 sample_en 周期只启动一次扫描，依次读取所有声部的
// 波表地址。72MHz 下每采样有 1500 个时钟，4/8/16/32 声部
// 的顺序读取都足够。
// ============================================================

module wavetable_arbiter #(
    parameter VOICES    = 4,
    parameter ADDR_BITS = 12,
    parameter SAMPLE_W  = 16,
    parameter INIT_FILE0 = "data/wavetables/sine_4096x16.hex",
    parameter INIT_FILE1 = "data/wavetables/square_4096x16.hex"
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          sample_en,
    input  wire                          table_sel,
    input  wire [VOICES*ADDR_BITS-1:0]   wave_addr_flat,

    output reg  [VOICES*SAMPLE_W-1:0]    wave_sample_flat,
    output reg  [VOICES-1:0]             wave_valid,
    output reg                           scan_done
);
    localparam IDX_W = (VOICES <= 1) ? 1 : $clog2(VOICES);

    reg [IDX_W-1:0] scan_idx;
    reg             scan_active;
    reg [IDX_W-1:0] read_idx_d1;
    reg             read_valid_d1;
    reg             done_pending;

    wire [ADDR_BITS-1:0] bank_addr =
        wave_addr_flat[scan_idx*ADDR_BITS +: ADDR_BITS];
    wire signed [SAMPLE_W-1:0] bank_data;

    wavetable_bank #(
        .ADDR_BITS  (ADDR_BITS),
        .DATA_W     (SAMPLE_W),
        .INIT_FILE0 (INIT_FILE0),
        .INIT_FILE1 (INIT_FILE1)
    ) u_bank (
        .clk       (clk),
        .addr      (bank_addr),
        .table_sel (table_sel),
        .data      (bank_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_idx         <= {IDX_W{1'b0}};
            scan_active      <= 1'b0;
            read_idx_d1      <= {IDX_W{1'b0}};
            read_valid_d1    <= 1'b0;
            done_pending     <= 1'b0;
            wave_sample_flat <= {VOICES*SAMPLE_W{1'b0}};
            wave_valid       <= {VOICES{1'b0}};
            scan_done        <= 1'b0;
        end else begin
            wave_valid <= {VOICES{1'b0}};
            scan_done  <= done_pending;
            done_pending <= 1'b0;

            read_valid_d1 <= scan_active;
            read_idx_d1   <= scan_idx;

            if (read_valid_d1) begin
                wave_sample_flat[read_idx_d1*SAMPLE_W +: SAMPLE_W] <= bank_data;
                wave_valid[read_idx_d1] <= 1'b1;
                if (read_idx_d1 == VOICES - 1)
                    done_pending <= 1'b1;
            end

            if (sample_en) begin
                scan_idx    <= {IDX_W{1'b0}};
                scan_active <= 1'b1;
            end else if (scan_active) begin
                if (scan_idx == VOICES - 1)
                    scan_active <= 1'b0;
                else
                    scan_idx <= scan_idx + 1'b1;
            end
        end
    end
endmodule
