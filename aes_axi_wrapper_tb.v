`timescale 1ns / 1ps
`default_nettype none

module aes_axi_wrapper_tb;

    // --- Clock & Reset Signals ---
    reg aclk;
    reg aresetn;

    // --- AXI4-Lite Slave Interface ---
    reg [5:0]   s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg [31:0]  s_axi_wdata;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    reg [5:0]   s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // --- AXI4-Stream Slave Interface ---
    reg [127:0] s_axis_tdata;
    reg [15:0]  s_axis_tkeep;
    reg         s_axis_tlast;
    reg         s_axis_tvalid;
    wire        s_axis_tready;

    // --- AXI4-Stream Master Interface ---
    wire [127:0] m_axis_tdata;
    wire [15:0]  m_axis_tkeep;
    wire         m_axis_tlast;
    wire         m_axis_tvalid;
    reg          m_axis_tready;

    // --- Testbench Monitor Registers ---
    reg [127:0] reg_original_pt;  // Luu du lieu goc
    reg [127:0] reg_encrypted_ct; // Luu du lieu sau ma hoa
    reg [127:0] reg_decrypted_pt; // Luu du lieu sau giai ma
    reg [31:0]  status_data;
    reg         m_last_captured;

    // --- UUT Instance ---
    aes_axi_wrapper uut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready)
    );

    // --- Clock Generator (100MHz) ---
    always #5 aclk = ~aclk;

    // --- Tasks phuc vu AXI-Lite & Stream ---
    
    // 1. Task ghi AXI-Lite
    task axi_lite_write(input [5:0] addr, input [31:0] data);
    begin
        @(posedge aclk);
        s_axi_awaddr  <= addr;
        s_axi_wdata   <= data;
        s_axi_awvalid <= 1'b1;
        s_axi_wvalid  <= 1'b1;
        s_axi_bready  <= 1'b1;
        
        @(posedge aclk);
        while (!(s_axi_awready && s_axi_wready)) @(posedge aclk);
        
        s_axi_awvalid <= 1'b0;
        s_axi_wvalid  <= 1'b0;
        
        while (!s_axi_bvalid) @(posedge aclk);
        s_axi_bready  <= 1'b0;
        @(posedge aclk);
    end
    endtask

    // 2. Task doc AXI-Lite
    task axi_lite_read(input [5:0] addr, output [31:0] data);
    begin
        @(posedge aclk);
        s_axi_araddr  <= addr;
        s_axi_arvalid <= 1'b1;
        s_axi_rready  <= 1'b1;
        
        @(posedge aclk);
        while (!s_axi_arready) @(posedge aclk);
        s_axi_arvalid <= 1'b0;
        
        while (!s_axi_rvalid) @(posedge aclk);
        data          = s_axi_rdata;
        s_axi_rready  <= 1'b0;
        @(posedge aclk);
    end
    endtask

    // 3. Task day du lieu vao Slave Stream (TX)
    task axis_push(input [127:0] data, input last);
    begin
        @(posedge aclk);
        s_axis_tdata  <= data;
        s_axis_tkeep  <= 16'hFFFF;
        s_axis_tlast  <= last;
        s_axis_tvalid <= 1'b1;
        
        @(posedge aclk);
        while (!s_axis_tready) @(posedge aclk);
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
    end
    endtask

    // 4. Task hung du lieu tu Master Stream (RX)
    task axis_pull(output [127:0] captured_data, output captured_last);
    begin
        m_axis_tready <= 1'b1;
        @(posedge aclk);
        while (!m_axis_tvalid) @(posedge aclk);
        captured_data = m_axis_tdata;
        captured_last = m_axis_tlast;
        m_axis_tready <= 1'b0;
        @(posedge aclk);
    end
    endtask

    // --- Kich ban Mo Phong ---
// ========================================================
    // KICH BAN MO PHONG CHINH CHUAN THEO LOGIC RTL CUA BAN
    // ========================================================
    initial begin
        // --- 0. Khoi tao trang thai ban dau ---
        aclk           = 1'b0;
        aresetn        = 1'b0;
        s_axi_awaddr   = 0; s_axi_awvalid  = 0; s_axi_wdata = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_araddr   = 0; s_axi_arvalid  = 0; s_axi_rready = 0;
        s_axis_tdata   = 0; s_axis_tkeep   = 0; s_axis_tlast = 0; s_axis_tvalid = 0;
        m_axis_tready  = 0;
        
        reg_original_pt  = 128'b0;
        reg_encrypted_ct = 128'b0;
        reg_decrypted_pt = 128'b0;

        #40;
        aresetn        = 1'b1; // Nha reset
        #20;

        $display("==========================================================");
        $display("BAT DAU MO PHONG: DIEU KHIEN CHUAN THEO CONFIG RTL CUA BAN");
        $display("==========================================================");

        // --------------------------------------------------------
        // STEP 1: NAP KHOA AES-256 (8 Words)
        // --------------------------------------------------------
        $display("[BUOC 1] Dang nap 8 words khoa vao cac thanh ghi...");
        axi_lite_write(6'h10, 32'h00010203); // Key Word 0
        axi_lite_write(6'h14, 32'h04050607); // Key Word 1
        axi_lite_write(6'h18, 32'h08090A0B); // Key Word 2
        axi_lite_write(6'h1C, 32'h0C0D0E0F); // Key Word 3
        axi_lite_write(6'h20, 32'h10111213); // Key Word 4
        axi_lite_write(6'h24, 32'h14151617); // Key Word 5
        axi_lite_write(6'h28, 32'h18191A1B); // Key Word 6
        axi_lite_write(6'h2C, 32'h1C1D1E1F); // Key Word 7

        // --------------------------------------------------------
        // STEP 2: KICH HOAT XUNG INIT DE MO RONG KHOA MA HOA
        // --------------------------------------------------------
        $display("[BUOC 2] Kich xung INIT len 1 (Keylen=1, EncDec=1, Init=1)...");
        axi_lite_write(6'h00, 32'h7); // 3'b111 -> 32'h7
        
        $display("[BUOC 2] Ha xung INIT xuong 0 (Keylen=1, EncDec=1, Init=0)...");
        axi_lite_write(6'h00, 32'h6); // 3'b110 -> 32'h6

        // Polling cho den khi khoi mo rong khoa bao san sang (core_ready = 1)
        status_data = 32'h0;
        while (status_data[0] == 1'b0) begin
            axi_lite_read(6'h04, status_data); 
            #10;
        end
        $display("[STATUS] Mo rong khoa cho AES-256 da HOAN TAT!");

        // --------------------------------------------------------
        // STEP 3 + 4: DUA DU LIEU VAO (RTL tu dong kich hoat core_next)
        // --------------------------------------------------------
        reg_original_pt = 128'h00112233445566778899aabbccddeeff; 
        $display("[BUOC 3+4] Day Plaintext vao Stream. RTL se tu kich hoat core_next!");
        
        fork
            axis_push(reg_original_pt, 1'b1); // Ham nay tu dong doi valid & ready bat tay
            axis_pull(reg_encrypted_ct, m_last_captured); // Don lay Ciphertext o dau ra
        join

        // ---------------- 5. QUY TRINH GIAI MA TUONG TU ----------------
        $display("\n--- BAT DAU CHUYEN SANG QUY TRINH GIAI MA ---");

        $display("[GIAI MA] Kich xung INIT cho Giai ma (Keylen=1, EncDec=0, Init=1)...");
        axi_lite_write(6'h00, 32'h5); // 3'b101 -> 32'h5
        
        $display("[GIAI MA] Ha xung INIT xuong 0 (Keylen=1, EncDec=0, Init=0)...");
        axi_lite_write(6'h00, 32'h4); // 3'b100 -> 32'h4

        // Cho core giai ma san sang
        status_data = 32'h0;
        while (status_data[0] == 1'b0) begin
            axi_lite_read(6'h04, status_data);
            #10;
        end
        $display("[STATUS] Core da san sang nhan du lieu Giai ma!");

        // Day khoi Ciphertext vua nhan vao lai duong Stream de khoi phuc Plaintext
        $display("[GIAI MA] Day Ciphertext vao Stream...");
        fork
            axis_push(reg_encrypted_ct, 1'b1);
            axis_pull(reg_decrypted_pt, m_last_captured);
        join

        // ---------------- 6. IN KET QUA KIEM TRA ----------------
        $display("\n==========================================================");
        $display("               BANG SO SANH DU LIEU CHU KY AES-256        ");
        $display("==========================================================");
        $display("1. Plaintext ban dau : %h", reg_original_pt);
        $display("2. Ciphertext ma hoa : %h", reg_encrypted_ct);
        $display("3. Plaintext khoi phuc: %h", reg_decrypted_pt);
        $display("==========================================================");

        if (reg_original_pt == reg_decrypted_pt) begin
            $display(">>> KET QUA: THANH CONG! He thong chay dung kịch ban.");
        end else begin
            $display(">>> KET QUA: THAT BAI! Du lieu khoi phuc khong trung khop.");
        end
        $display("==========================================================\n");

        #50;
        $finish;
    end

endmodule
`default_nettype wire