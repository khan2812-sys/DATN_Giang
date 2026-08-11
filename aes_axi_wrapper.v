`default_nettype none

module aes_axi_wrapper (
    input wire          aclk,
    input wire          aresetn,

    // --- AXI4-Lite Slave (Control & Key) ---
    input wire [5:0]    s_axi_awaddr,
    input wire          s_axi_awvalid,
    output wire         s_axi_awready,
    input wire [31:0]   s_axi_wdata,
    input wire          s_axi_wvalid,
    output wire         s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input wire          s_axi_bready,
    input wire [5:0]    s_axi_araddr,
    input wire          s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rvalid,
    input wire          s_axi_rready,

    // --- AXI4-Stream Slave (From DMA MM2S) ---
    input wire [127:0]  s_axis_tdata,
    input wire [15:0]   s_axis_tkeep,
    input wire          s_axis_tlast,
    input wire          s_axis_tvalid,
    output wire         s_axis_tready,

    // --- AXI4-Stream Master (To DMA S2MM) ---
    output wire [127:0] m_axis_tdata,
    output wire [15:0]  m_axis_tkeep,
    output wire         m_axis_tlast,
    output wire         m_axis_tvalid,
    input wire          m_axis_tready
);

    // Signals cho AES Core
    wire         core_ready;
    reg          core_encdec, core_keylen;
    reg          core_init; // Chuyển thành thanh ghi điều khiển xung chuẩn
    reg  [255:0] core_key;
    reg          core_next;
    wire [127:0] core_result;
    wire         core_result_valid;

    // --- AXI-Lite Logic ---
    reg [31:0] rdata;
    reg awready, wready, arready, rvalid, bvalid;

    assign s_axi_awready = awready;
    assign s_axi_wready  = wready;
    assign s_axi_arready = arready;
    assign s_axi_rdata   = rdata;
    assign s_axi_rvalid  = rvalid;
    assign s_axi_bvalid  = bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    always @(posedge aclk) begin
        if (!aresetn) begin
            {awready, wready, arready, rvalid, bvalid} <= 5'b0;
            core_init   <= 1'b0; 
            core_encdec <= 1'b1; 
            core_keylen <= 1'b1;
            core_key    <= 256'b0;
        end else begin
            // Xử lý tự động hạ xung init sau 1 chu kỳ tích cực
            if (core_init) core_init <= 1'b0;

            // Write Channel
            if (s_axi_awvalid && s_axi_wvalid && !awready) begin
                awready <= 1'b1;
                wready  <= 1'b1;
                case (s_axi_awaddr[5:2])
                    4'h0: begin
                        core_keylen <= s_axi_wdata[2];
                        core_encdec <= s_axi_wdata[1];
                        core_init   <= s_axi_wdata[0]; // Kích xung hóa vòng
                    end
                    4'h4: core_key[31:0]    <= s_axi_wdata;
                    4'h5: core_key[63:32]   <= s_axi_wdata;
                    4'h6: core_key[95:64]   <= s_axi_wdata;
                    4'h7: core_key[127:96]  <= s_axi_wdata;
                    4'h8: core_key[159:128] <= s_axi_wdata;
                    4'h9: core_key[191:160] <= s_axi_wdata;
                    4'hA: core_key[223:192] <= s_axi_wdata;
                    4'hB: core_key[255:224] <= s_axi_wdata;
                endcase
            end else begin
                awready <= 1'b0;
                wready  <= 1'b0;
            end
            
            if (awready && !bvalid) bvalid <= 1'b1;
            else if (s_axi_bready)  bvalid <= 1'b0;

            // Read Channel
            if (s_axi_arvalid && !arready) arready <= 1'b1;
            else arready <= 1'b0;

            if (arready && !rvalid) begin
                rvalid <= 1'b1;
                rdata  <= (s_axi_araddr[5:2] == 4'h0) ? {29'b0, core_keylen, core_encdec, core_init} : 
                          (s_axi_araddr[5:2] == 4'h1) ? {31'b0, core_ready} : 32'b0;
            end else if (s_axi_rready) rvalid <= 1'b0;
        end
    end

    // --- AXI-Stream Data Path (Sửa đổi FSM chống treo DMA) ---
    reg [1:0]   state;
    reg [15:0]  r_tkeep;
    reg         r_tlast;
    reg [127:0] r_tdata;

    localparam IDLE = 2'd0, BUSY = 2'd1, DONE = 2'd2;

    // SỬA: S_AXIS_TREADY chỉ mở khi FSM ở IDLE VÀ lõi mã hóa rảnh rỗi thật sự
    assign s_axis_tready = (state == IDLE) && core_ready;

    // SỬA timing các tín hiệu Master Stream: Chỉ tích cực khi trạng thái là DONE
    assign m_axis_tvalid = (state == DONE);
    assign m_axis_tdata  = core_result;
    assign m_axis_tkeep  = r_tkeep;
    assign m_axis_tlast  = (state == DONE) ? r_tlast : 1'b0; // Ép tlast đi kèm valid chuẩn timing

    always @(posedge aclk) begin
        if (!aresetn) begin
            state     <= IDLE;
            core_next <= 1'b0;
            r_tdata   <= 128'b0;
            r_tkeep   <= 16'b0;
            r_tlast   <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        r_tdata   <= s_axis_tdata;
                        r_tkeep   <= s_axis_tkeep;
                        r_tlast   <= s_axis_tlast;
                        core_next <= 1'b1;  // Phát lệnh bắt đầu tính toán cho lõi AES
                        state     <= BUSY;
                    end
                end

                BUSY: begin
                    // Đảm bảo xung core_next được giữ đúng 1 chu kỳ đầy đủ tại BUSY 
                    // trước khi kéo về 0 để lõi AES bắt kịp trạng thái CTRL_NEXT
                    if (core_next) begin
                        core_next <= 1'b0;
                    end

                    // Chờ lõi AES xử lý xong toán học và giơ cờ Valid
                    else if (core_result_valid) begin
                        state <= DONE;
                    end
                end

                DONE: begin
                    // Đợi kênh thu DMA (S2MM) nhận xong dữ liệu mã hóa thì mới quay về IDLE
                    if (m_axis_tready) begin
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

    // Instance lõi AES core gốc của Joachim Strombergson
    aes_core u_aes_core (
        .clk(aclk), 
        .reset_n(aresetn),
        .encdec(core_encdec), 
        .init(core_init), 
        .next(core_next), 
        .ready(core_ready),
        .key(core_key), 
        .keylen(core_keylen),
        .block(r_tdata), 
        .result(core_result), 
        .result_valid(core_result_valid)
    );

endmodule