`timescale 1ns / 1ps

module npu_4_4_tb;

    reg         clk, rst, npu_en;
    reg  [1:0]  mode;
    reg  [7:0]  vec_len;
    reg         sx, sy;
    reg         host_we;
    reg  [1:0]  host_bank_sel;
    reg  [7:0]  host_addr;
    reg  [31:0] host_data;
    reg  [3:0]  host_read_col;
    reg         pause_stream;
    wire [31:0] host_read_data;
    wire        npu_valid;
    wire [2:0]  state_dbg;

    npu_4_4 #(.DEPTH(256)) uut (
        .clk(clk), .rst(rst),
        .npu_en(npu_en), .mode(mode), .vec_len(vec_len),
        .sx(sx), .sy(sy),
        .host_we(host_we), .host_bank_sel(host_bank_sel),
        .host_addr(host_addr), .host_data(host_data),
        .host_read_col(host_read_col), .host_read_data(host_read_data),
        .npu_valid(npu_valid), .state_dbg(state_dbg),
        .pause_stream(pause_stream)
    );

    always #5 clk = ~clk;

    integer err_count = 0;
    integer total_tests = 0;

    // Golden model structures
    reg [7:0] W [0:3][0:3];
    reg [7:0] X [0:3][0:255];
    reg [31:0] G_O [0:3][0:255];

    reg [1:0] test_mode [0:3];
    reg test_sx [0:3];
    reg test_sy [0:3];

    // ========================================================
    // Golden Model Compute
    // ========================================================
    task compute_golden_model;
        input [7:0] len; // vec_len
        integer r, c, k;
        reg [1:0] m;
        reg sx_flag, sy_flag;
        reg [7:0] w_val, x_val;
        reg signed [31:0] psum;
        reg signed [31:0] p0, p3;
        reg signed [31:0] i2_p0, i2_p1, i2_p2, i2_p3;
        
        reg signed [31:0] w_ext, x_ext;
        reg signed [31:0] w_L, w_H, x_L, x_H;
        begin
            for (c = 0; c < 4; c = c + 1) begin
                for (k = 0; k < len; k = k + 1) begin
                    psum = 0;
                    for (r = 0; r < 4; r = r + 1) begin
                        w_val = W[r][c];
                        x_val = X[r][k];
                        m = test_mode[r];
                        sx_flag = test_sx[r];
                        sy_flag = test_sy[r];
                        
                        if (m == 2'b10) begin // INT8
                            w_ext = (sx_flag && w_val[7]) ? {24'hFFFFFF, w_val} : {24'h0, w_val};
                            x_ext = (sy_flag && x_val[7]) ? {24'hFFFFFF, x_val} : {24'h0, x_val};
                            psum = psum + (w_ext * x_ext);
                        end else if (m == 2'b01) begin // INT4
                            // BitFusion BBU0 (L) is hardcoded unsigned, BBU3 (H) uses sx/sy
                            w_L = {28'h0, w_val[3:0]}; 
                            x_L = {28'h0, x_val[3:0]};
                            w_H = (sx_flag && w_val[7]) ? {28'hFFFFFFF, w_val[7:4]} : {28'h0, w_val[7:4]};
                            x_H = (sy_flag && x_val[7]) ? {28'hFFFFFFF, x_val[7:4]} : {28'h0, x_val[7:4]};
                            p0 = w_L * x_L;
                            p3 = w_H * x_H;
                            psum = psum + p0 + p3;
                        end else begin // INT2
                            // BitFusion BBU0 and BBU3 L-components are architecturally unsigned
                            // Only the most significant multiplier (i2_p3) receives the sx/sy flags
                            i2_p0 = {30'h0, w_val[1:0]} * {30'h0, x_val[1:0]};
                            i2_p1 = {30'h0, w_val[3:2]} * {30'h0, x_val[3:2]};
                            i2_p2 = {30'h0, w_val[5:4]} * {30'h0, x_val[5:4]};
                            i2_p3 = ((sx_flag && w_val[7]) ? {30'h3FFFFFFF, w_val[7:6]} : {30'h0, w_val[7:6]}) * ((sy_flag && x_val[7]) ? {30'h3FFFFFFF, x_val[7:6]} : {30'h0, x_val[7:6]});
                            psum = psum + i2_p0 + i2_p1 + i2_p2 + i2_p3;
                        end
                    end
                    G_O[c][k] = psum;
                end
            end
        end
    endtask

    // ========================================================
    // Host Helpers
    // ========================================================
    task gb_write;
        input [1:0] bank;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            host_we = 1; host_bank_sel = bank; host_addr = addr; host_data = data;
            @(negedge clk);
            host_we = 0;
        end
    endtask

    task write_mode;
        input integer row;
        input [1:0] m;
        input sx_flag;
        input sy_flag;
        begin
            gb_write(2'b10, row[7:0], {28'b0, sx_flag, sy_flag, m});
        end
    endtask

    task gb_read;
        input [3:0] col;
        input [7:0] addr;
        begin
            @(negedge clk);
            host_read_col = col; host_addr = addr;
            @(negedge clk);
        end
    endtask

    // ========================================================
    // Layer 1: Memory check
    // ========================================================
    task check_memory;
        input [7:0] w_addr;
        input [31:0] w_expected;
        begin
            total_tests = total_tests + 1;
            if (uut.GBUF.w_sram[w_addr] !== w_expected) begin
                $display("  ERROR L1: W-SRAM[%0d] = %h, expected %h", w_addr, uut.GBUF.w_sram[w_addr], w_expected);
                err_count = err_count + 1;
            end
        end
    endtask

    // ========================================================
    // Layer 2: Weight check
    // ========================================================
    task check_weight;
        input integer r, c;
        input [7:0] expected;
        begin
            total_tests = total_tests + 1;
            case ({r[1:0], c[1:0]})
                4'b0000: if (uut.row[0].col[0].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[0].col[0].tile.w_reg, expected); err_count=err_count+1; end
                4'b0001: if (uut.row[0].col[1].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[0].col[1].tile.w_reg, expected); err_count=err_count+1; end
                4'b0010: if (uut.row[0].col[2].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[0].col[2].tile.w_reg, expected); err_count=err_count+1; end
                4'b0011: if (uut.row[0].col[3].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[0].col[3].tile.w_reg, expected); err_count=err_count+1; end
                4'b0100: if (uut.row[1].col[0].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[1].col[0].tile.w_reg, expected); err_count=err_count+1; end
                4'b0101: if (uut.row[1].col[1].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[1].col[1].tile.w_reg, expected); err_count=err_count+1; end
                4'b0110: if (uut.row[1].col[2].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[1].col[2].tile.w_reg, expected); err_count=err_count+1; end
                4'b0111: if (uut.row[1].col[3].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[1].col[3].tile.w_reg, expected); err_count=err_count+1; end
                4'b1000: if (uut.row[2].col[0].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[2].col[0].tile.w_reg, expected); err_count=err_count+1; end
                4'b1001: if (uut.row[2].col[1].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[2].col[1].tile.w_reg, expected); err_count=err_count+1; end
                4'b1010: if (uut.row[2].col[2].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[2].col[2].tile.w_reg, expected); err_count=err_count+1; end
                4'b1011: if (uut.row[2].col[3].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[2].col[3].tile.w_reg, expected); err_count=err_count+1; end
                4'b1100: if (uut.row[3].col[0].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[3].col[0].tile.w_reg, expected); err_count=err_count+1; end
                4'b1101: if (uut.row[3].col[1].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[3].col[1].tile.w_reg, expected); err_count=err_count+1; end
                4'b1110: if (uut.row[3].col[2].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[3].col[2].tile.w_reg, expected); err_count=err_count+1; end
                4'b1111: if (uut.row[3].col[3].tile.w_reg !== expected) begin $display("  ERROR L2: tile(%0d,%0d) w_reg=%0d, expected %0d", r, c, uut.row[3].col[3].tile.w_reg, expected); err_count=err_count+1; end
            endcase
        end
    endtask

    // ========================================================
    // Layer 4: O-Buffer check against Golden Model
    // ========================================================
    task check_obuf;
        input [7:0] len;
        integer c, k;
        begin
            for (k = 0; k < len; k = k + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    gb_read(c[3:0], k[7:0]);
                    total_tests = total_tests + 1;
                    if (host_read_data !== G_O[c][k]) begin
                        $display("  [FAIL L0] Output Mismatch -> Tile(Col:%0d, Output Cycle:%0d) | Modes(R0:%b R1:%b R2:%b R3:%b) | Expected: %0d | Actual: %0d", 
                                 c, k, test_mode[0], test_mode[1], test_mode[2], test_mode[3], G_O[c][k], host_read_data);
                        err_count = err_count + 1;
                    end
                end
            end
        end
    endtask

    // ========================================================
    // Layer 3: Timing Monitor (Background)
    // ========================================================
    integer cycle_count = 0;
    integer pause_cycles = 0;
    reg tracking_timing = 0;
    
    always @(posedge clk) begin
        if (npu_en) begin
            cycle_count <= 0;
            pause_cycles <= 0;
            tracking_timing <= 1;
        end else if (tracking_timing) begin
            cycle_count <= cycle_count + 1;
            // Only counts while FSM is in WAIT_X AND wait_cnt hasn't already reached
            // its terminal value -- on the last WAIT_X cycle, next_state->DONE is decided
            // from the already-settled wait_cnt regardless of pause_stream, so a pause
            // pulse landing exactly there has zero effect in the RTL (see npu_ctrl.v).
            if (pause_stream && state_dbg == 4 &&
                uut.CTRL.wait_cnt != ({1'b0, vec_len} + 9'd8))
                pause_cycles <= pause_cycles + 1;
            
            // Expected transitions due to instantaneous npu_en capture:
            // Cycle 0: LOAD_W (Captured instantaneously on posedge)
            // Cycle 1: WAIT_W
            if (cycle_count == 1 && state_dbg !== 2) $display("  ERROR L3: Cycle 1 not in WAIT_W, state=%0d", state_dbg);
            // Cycle 8: STREAM
            if (cycle_count == 8 && state_dbg !== 3) $display("  ERROR L3: Cycle 8 not in STREAM, state=%0d", state_dbg);
            // Cycle 9: WAIT_X
            if (cycle_count == 9 && state_dbg !== 4) $display("  ERROR L3: Cycle 9 not in WAIT_X, state=%0d", state_dbg);
            
            if (npu_valid) begin
                tracking_timing <= 0;
                // npu_valid should fire at exactly cycle 9 + vec_len + 10 + pause_cycles
                if (cycle_count !== 9 + vec_len + 10 + pause_cycles) begin
                    $display("  ERROR L3: npu_valid fired at cycle %0d, expected %0d", cycle_count, 9 + vec_len + 10 + pause_cycles);
                    err_count = err_count + 1;
                end
            end
        end
    end

    // ========================================================
    // Layer 4: Assertion-Based Checking (Continuous Monitoring)
    // ========================================================
    reg x_valid_in_prev;
    reg pipe_en_prev;
    reg rst_prev;
    reg [1:0] w_mode_reg_d [0:3];
    reg w_valid_prev [0:3];
    integer tmp_r;
    
    always @(posedge clk) begin
        // A2: Reset Exclusion - acc_en must never be high when rst was high on previous cycle (sync reset)
        if (rst_prev) begin
            if (uut.row[0].col[0].tile.acc_en === 1'b1) begin
                $display("  [FATAL L4] Reset Exclusion Violation: acc_en is high after rst!");
                err_count = err_count + 1;
            end
        end
        if (!rst) begin
            // A1: Pipeline Validity - x_valid_out should follow x_valid_in delayed by 1 cycle (when pipe_en is high)
            if (pipe_en_prev) begin
                if (uut.row[0].col[0].tile.x_valid_out !== x_valid_in_prev) begin
                    $display("  [FATAL L4] Pipeline Validity Violation: x_valid_out != x_valid_in_prev");
                    err_count = err_count + 1;
                end
            end
            
            // A7: Mode Stability - mode_reg must not change unless w_valid was asserted on previous edge
            for (tmp_r = 0; tmp_r < 4; tmp_r = tmp_r + 1) begin
                case (tmp_r)
                    0: if (!w_valid_prev[0] && uut.row[0].col[0].tile.mode_reg !== w_mode_reg_d[0]) begin $display("  [FATAL L4] Mode Stability Violation R0"); err_count = err_count + 1; end
                    1: if (!w_valid_prev[1] && uut.row[1].col[0].tile.mode_reg !== w_mode_reg_d[1]) begin $display("  [FATAL L4] Mode Stability Violation R1"); err_count = err_count + 1; end
                    2: if (!w_valid_prev[2] && uut.row[2].col[0].tile.mode_reg !== w_mode_reg_d[2]) begin $display("  [FATAL L4] Mode Stability Violation R2"); err_count = err_count + 1; end
                    3: if (!w_valid_prev[3] && uut.row[3].col[0].tile.mode_reg !== w_mode_reg_d[3]) begin $display("  [FATAL L4] Mode Stability Violation R3"); err_count = err_count + 1; end
                endcase
            end
        end
        
        // A3: FSM Legality
        if (state_dbg > 5 && state_dbg !== 8'bxxxxxxxx) begin 
            $display("  [FATAL L4] FSM entered undefined/illegal state: %0d", state_dbg);
            err_count = err_count + 1;
        end
        
        // Update delayed regs
        x_valid_in_prev <= uut.row[0].col[0].tile.x_valid_in;
        pipe_en_prev <= uut.row[0].col[0].tile.pipe_en;
        rst_prev <= rst;
        w_valid_prev[0] <= uut.row[0].col[0].tile.w_valid;
        w_valid_prev[1] <= uut.row[1].col[0].tile.w_valid;
        w_valid_prev[2] <= uut.row[2].col[0].tile.w_valid;
        w_valid_prev[3] <= uut.row[3].col[0].tile.w_valid;
        
        if (rst) begin
            w_mode_reg_d[0] <= 2'b10;
            w_mode_reg_d[1] <= 2'b10;
            w_mode_reg_d[2] <= 2'b10;
            w_mode_reg_d[3] <= 2'b10;
        end else begin
            w_mode_reg_d[0] <= uut.row[0].col[0].tile.mode_reg;
            w_mode_reg_d[1] <= uut.row[1].col[0].tile.mode_reg;
            w_mode_reg_d[2] <= uut.row[2].col[0].tile.mode_reg;
            w_mode_reg_d[3] <= uut.row[3].col[0].tile.mode_reg;
        end
    end

    // ========================================================
    // Run Sweep Execution
    // ========================================================
    task run_test;
        input [8*20:1] test_name;
        input [7:0] len; // vec_len
        integer r, c, k;
        integer timeout_cnt;
        begin
            $display("\n==================================================");
            $display(" TEST: %s (Len: %0d)", test_name, len);
            $display("==================================================");
            
            rst = 1; #20; rst = 0; #10;
            vec_len = len;

            // Compute expected answers
            compute_golden_model(len);

            // Write mode config for all rows
            for (r = 0; r < 4; r = r + 1) write_mode(r, test_mode[r], test_sx[r], test_sy[r]);

            // Write W matrix
            for (r = 0; r < 4; r = r + 1) gb_write(2'b00, r[7:0], {W[r][3], W[r][2], W[r][1], W[r][0]});
            
            // Write X matrix
            for (k = 0; k < len; k = k + 1) gb_write(2'b01, k[7:0], {X[3][k], X[2][k], X[1][k], X[0][k]});

            // L1 Verify W
            for (r = 0; r < 4; r = r + 1) check_memory(r[7:0], {W[r][3], W[r][2], W[r][1], W[r][0]});

            // Run
            @(negedge clk); npu_en = 1;
            @(negedge clk); npu_en = 0;
            
            // L0: Silence Detector (Watchdog)
            timeout_cnt = 0;
            while (!npu_valid && timeout_cnt < (len + 100)) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            
            if (timeout_cnt >= (len + 100)) begin
                $display("  [FATAL L0] SILENCE DETECTOR TIMEOUT: npu_valid never asserted! Expected at cycle %0d", 9 + len + 10);
                err_count = err_count + 1;
                disable run_test; // Abort this specific test
            end
            
            repeat(3) @(negedge clk);

            // L2 Verify W latch
            for (r = 0; r < 4; r = r + 1)
                for (c = 0; c < 4; c = c + 1)
                    check_weight(r, c, W[r][c]);

            // L4 Verify Math
            check_obuf(len);
            
            if (err_count == 0) $display("  -> PASSED");
            else $display("  -> FAILED (%0d errors)", err_count);
        end
    endtask

    // ========================================================
    // Initialize Test Environment
    // ========================================================
    integer i, j;
    integer global_timeout_cnt;
    integer seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 12345;
        $display("Using seed: %0d", seed);
        // Icarus Verilog uses $urandom with srandom(seed) but a standard way for backward comp is to just use a custom seed var for $random(seed).
        
        clk = 0; rst = 1; npu_en = 0;
        mode = 2'b10; vec_len = 8'd4;
        sx = 0; sy = 0;
        pause_stream <= 0;
        host_we = 0; host_bank_sel = 0; host_addr = 0; host_data = 0; host_read_col = 0;
        
        #25 rst = 0; #10;

        // --- TEST SET 1: SEQUENTIAL W, ALL 1s X ---
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = (i*4)+j+1; // 1 to 16
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = 8'h01; // All 1s
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("SeqW_OnesX_INT8", 4);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b01; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("SeqW_OnesX_INT4", 8);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b00; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("SeqW_OnesX_INT2", 16);

        // --- TEST SET 2: MAX POSITIVE (UNSIGNED) ---
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = 8'hFF;
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = 8'hFF;
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("MaxPosW_MaxPosX_INT8", 4);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b01; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("MaxPosW_MaxPosX_INT4", 8);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b00; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("MaxPosW_MaxPosX_INT2", 16);

        // --- TEST SET 3: MAX NEGATIVE (SIGNED) ---
        // 0x80 is -128 in 8-bit signed
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = 8'h80;
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = 8'h80;
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 1; test_sy[i] = 1; end
        run_test("MaxNegW_MaxNegX_INT8", 4);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b01; test_sx[i] = 1; test_sy[i] = 1; end
        run_test("MaxNegW_MaxNegX_INT4", 8);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b00; test_sx[i] = 1; test_sy[i] = 1; end
        run_test("MaxNegW_MaxNegX_INT2", 16);

        // --- TEST SET 4: MIXED SIGN ---
        // W alternates between -128 and +127
        // X alternates between -128 and +127
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = (j%2 == 0) ? 8'h80 : 8'h7F;
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = (j%2 == 0) ? 8'h7F : 8'h80;
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 1; test_sy[i] = 1; end
        run_test("MixedSign_W_X_INT8", 4);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b01; test_sx[i] = 1; test_sy[i] = 1; end
        run_test("MixedSign_W_X_INT4", 8);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b00; test_sx[i] = 1; test_sy[i] = 1; end
        run_test("MixedSign_W_X_INT2", 16);

        // --- TEST SET 5: SINGLE ELEMENT INJECTION ---
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = 8'h00;
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = 8'h00;
        W[0][0] = 8'hAA; // Tile 0,0 gets data
        X[0][0] = 8'h55; // cycle 0 gets data
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("SingleElem_INT8", 4);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b01; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("SingleElem_INT4", 8);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b00; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("SingleElem_INT2", 16);

        // --- TEST SET 6: ALL ZEROS ---
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = 8'h00;
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = 8'h00;
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("Zeros_INT8", 4);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b01; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("Zeros_INT4", 8);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b00; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("Zeros_INT2", 16);

        // --- TEST SET 7: ARBITRARY 4x4 MATRICES (SIGNED) ---
        // W Matrix
        W[0][0] = -8'sd1;  W[0][1] = 8'sd1;   W[0][2] = 8'sd5;   W[0][3] = 8'sd0;
        W[1][0] = 8'sd2;   W[1][1] = -8'sd2;  W[1][2] = -8'sd6;  W[1][3] = 8'sd0;
        W[2][0] = -8'sd3;  W[2][1] = 8'sd3;   W[2][2] = 8'sd7;   W[2][3] = 8'sd10;
        W[3][0] = 8'sd4;   W[3][1] = -8'sd4;  W[3][2] = -8'sd8;  W[3][3] = -8'sd10;
        
        // X Matrix (first 4 cycles)
        for (i=0; i<4; i=i+1) for (j=4; j<256; j=j+1) X[i][j] = 8'h00; // Clear rest
        X[0][0] = 8'sd5;   X[0][1] = -8'sd1;  X[0][2] = 8'sd2;   X[0][3] = 8'sd0;
        X[1][0] = -8'sd6;  X[1][1] = 8'sd2;   X[1][2] = -8'sd3;  X[1][3] = 8'sd0;
        X[2][0] = 8'sd7;   X[2][1] = -8'sd3;  X[2][2] = 8'sd4;   X[2][3] = 8'sd0;
        X[3][0] = -8'sd8;  X[3][1] = 8'sd4;   X[3][2] = -8'sd5;  X[3][3] = 8'sd1;
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 1; test_sy[i] = 1; end
        run_test("Arbitrary_4x4", 4);

        // --- TEST SET 8: ASYMMETRIC SIGN SWEEP (Bug 1 Regression) ---
        // Verify sx=1, sy=0 and sx=0, sy=1 across all precision modes
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = (j%2 == 0) ? 8'h81 : 8'h7F; // Mixed neg/pos
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = (j%2 == 0) ? 8'h7F : 8'h81; // Mixed pos/neg
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 1; test_sy[i] = 0; end
        run_test("Asymmetric_W_X_INT8", 8); // Signed Weight, Unsigned Activation
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b01; test_sx[i] = 1; test_sy[i] = 0; end
        run_test("Asymmetric_W_X_INT4", 8);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b00; test_sx[i] = 1; test_sy[i] = 0; end
        run_test("Asymmetric_W_X_INT2", 8);
        
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 0; test_sy[i] = 1; end
        run_test("Asymmetric_X_W_INT8", 8); // Unsigned Weight, Signed Activation
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b01; test_sx[i] = 0; test_sy[i] = 1; end
        run_test("Asymmetric_X_W_INT4", 8);
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b00; test_sx[i] = 0; test_sy[i] = 1; end
        run_test("Asymmetric_X_W_INT2", 8);

        // --- TEST SET 9: MAX VECTOR BOUNDARY (Bug 2 Regression) ---
        // vec_len = 255. Proves wait_cnt 8-bit wraparound is fixed.
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = 8'h01;
        for (i=0; i<4; i=i+1) for (j=0; j<255; j=j+1) X[i][j] = 8'h01;
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("Max_VecLen_255", 255);

        // --- TEST SET 10: ZERO VECTOR BOUNDARY (Bug 3 Regression) ---
        // vec_len = 0. Proves x_addr_cnt underflow is fixed.
        // We use Zeros so if it does stream, it streams 0s, but the timing check will catch if it lingers.
        for (i=0; i<4; i=i+1) begin test_mode[i] = 2'b10; test_sx[i] = 0; test_sy[i] = 0; end
        run_test("Zero_VecLen_0", 0);

        // --- TEST SET 11: HETEROGENEOUS PRECISION ---
        // Row 0: INT8, Row 1: INT4, Row 2: INT2, Row 3: INT8
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = 8'h7F; // All +127
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = 8'h01; // All +1
        
        test_mode[0] = 2'b10; test_sx[0] = 1; test_sy[0] = 1; // INT8 signed
        test_mode[1] = 2'b01; test_sx[1] = 1; test_sy[1] = 1; // INT4 signed
        test_mode[2] = 2'b00; test_sx[2] = 1; test_sy[2] = 1; // INT2 signed
        test_mode[3] = 2'b10; test_sx[3] = 1; test_sy[3] = 1; // INT8 signed
        run_test("Hetero_Row_Precision", 8);

        // --- TEST SET 12: HETEROGENEOUS SIGNS ---
        // Row 0: Unsigned W/X, Row 1: Signed W/X, Row 2: Signed W/Unsigned X, Row 3: Unsigned W/Signed X
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = 8'hFF;
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = 8'hFF;
        
        test_mode[0] = 2'b10; test_sx[0] = 0; test_sy[0] = 0;
        test_mode[1] = 2'b10; test_sx[1] = 1; test_sy[1] = 1;
        test_mode[2] = 2'b10; test_sx[2] = 1; test_sy[2] = 0;
        test_mode[3] = 2'b10; test_sx[3] = 0; test_sy[3] = 1;
        // ========================================================
        // Layer 2: Aggressive Directed Testing
        // ========================================================
        
        // --- TEST 13: Mode Transition (Back-to-Back) on same row ---
        $display("\n==================================================");
        $display(" TEST: Mode_Transition_B2B");
        $display("==================================================");
        // Load INT8, compute, then immediately load INT4 without reset
        rst = 1; #20; rst = 0; #10;
        for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = 8'h02;
        for (i=0; i<4; i=i+1) for (j=0; j<16; j=j+1) X[i][j] = 8'h02;
        // Run INT8
        for (i=0; i<4; i=i+1) write_mode(i, 2'b10, 0, 0);
        for (i=0; i<4; i=i+1) gb_write(2'b00, i[7:0], {W[i][3], W[i][2], W[i][1], W[i][0]});
        for (i=0; i<16; i=i+1) gb_write(2'b01, i[7:0], {X[3][i], X[2][i], X[1][i], X[0][i]});
        vec_len = 8'd4; compute_golden_model(4);
        @(negedge clk); npu_en = 1; @(negedge clk); npu_en = 0;
        while (!npu_valid) @(posedge clk);
        check_obuf(4); // Should pass INT8
        // Immediately run INT4 (same weights, just mode change)
        for (i=0; i<4; i=i+1) write_mode(i, 2'b01, 0, 0);
        for (i=0; i<4; i=i+1) gb_write(2'b00, i[7:0], {W[i][3], W[i][2], W[i][1], W[i][0]}); // Reload to latch new mode
        compute_golden_model(4);
        @(negedge clk); npu_en = 1; @(negedge clk); npu_en = 0;
        while (!npu_valid) @(posedge clk);
        check_obuf(4); // Should pass INT4 with absolutely no bleed-through

        // --- TEST 14: Valid Gaps and Bursts (Valid-Gating check) ---
        $display("\n==================================================");
        $display(" TEST: Valid_Gaps_And_Bursts");
        $display("==================================================");
        rst = 1; #20; rst = 0; #10;
        // Same setup as INT8
        for (i=0; i<4; i=i+1) write_mode(i, 2'b10, 0, 0);
        for (i=0; i<4; i=i+1) gb_write(2'b00, i[7:0], {W[i][3], W[i][2], W[i][1], W[i][0]});
        for (i=0; i<16; i=i+1) gb_write(2'b01, i[7:0], {X[3][i], X[2][i], X[1][i], X[0][i]});
        vec_len = 8'd8; compute_golden_model(8);
        @(negedge clk); npu_en = 1; @(negedge clk); npu_en = 0;
        // Now inject random pauses while streaming
        fork
            begin
                // Watchdog and wait
                global_timeout_cnt = 0;
                while (!npu_valid && global_timeout_cnt < 200) begin
                    @(posedge clk); global_timeout_cnt = global_timeout_cnt + 1;
                end
                if (global_timeout_cnt >= 200) begin
                    $display("  [FATAL] Timeout in Valid Gaps Test!"); err_count = err_count + 1;
                end
            end
            begin
                // Inject bubbles
                repeat(12) @(posedge clk);
                pause_stream <= 1; repeat(4) @(posedge clk);
                pause_stream <= 0; repeat(2) @(posedge clk);
                pause_stream <= 1; repeat(2) @(posedge clk);
                pause_stream <= 0;
            end
        join
        check_obuf(8);

        // --- TEST 15: Reset Mid-Flight ---
        $display("\n==================================================");
        $display(" TEST: Reset_Mid_Flight");
        $display("==================================================");
        rst = 1; #20; rst = 0; #10;
        for (i=0; i<4; i=i+1) write_mode(i, 2'b10, 0, 0);
        for (i=0; i<4; i=i+1) gb_write(2'b00, i[7:0], {W[i][3], W[i][2], W[i][1], W[i][0]});
        vec_len = 8'd16;
        @(negedge clk); npu_en = 1; @(negedge clk); npu_en = 0;
        repeat(12) @(posedge clk);
        rst = 1; // Assert reset mid-stream!
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(10) @(posedge clk); // Give it time, it should be in IDLE
        if (uut.CTRL.state !== 0) begin $display("  [FATAL] Did not recover to IDLE after reset!"); err_count = err_count+1; end
        // Now run normally to ensure recovery
        for (i=0; i<4; i=i+1) write_mode(i, 2'b10, 0, 0);
        for (i=0; i<4; i=i+1) gb_write(2'b00, i[7:0], {W[i][3], W[i][2], W[i][1], W[i][0]});
        vec_len = 8'd4; compute_golden_model(4);
        @(negedge clk); npu_en = 1; @(negedge clk); npu_en = 0;
        while (!npu_valid) @(posedge clk);
        check_obuf(4);

        // --- TEST 16: Back-to-Back Array Operations ---
        $display("\n==================================================");
        $display(" TEST: Back_to_Back_Operations");
        $display("==================================================");
        rst = 1; #20; rst = 0; #10;
        for (i=0; i<4; i=i+1) write_mode(i, 2'b10, 0, 0);
        for (i=0; i<4; i=i+1) gb_write(2'b00, i[7:0], {W[i][3], W[i][2], W[i][1], W[i][0]});
        vec_len = 8'd4; compute_golden_model(4);
        @(negedge clk); npu_en = 1; @(negedge clk); npu_en = 0;
        while (!npu_valid) @(posedge clk);
        // Immediately trigger again
        @(negedge clk); npu_en = 1; @(negedge clk); npu_en = 0;
        while (!npu_valid) @(posedge clk);
        check_obuf(4);

        if ($test$plusargs("test_mode=random")) begin
            $display("\n==================================================");
            $display(" TEST: Constrained_Random_Test (Seed: %0d)", seed);
            $display("==================================================");
            rst = 1; #20; rst = 0; #10;
            
            // Randomize Modes
            for (i=0; i<4; i=i+1) begin
                test_mode[i] = $urandom(seed) % 3; // 0, 1, 2
                test_sx[i] = $urandom(seed) % 2;
                test_sy[i] = $urandom(seed) % 2;
                write_mode(i, test_mode[i], test_sx[i], test_sy[i]);
            end
            
            // Randomize Data
            for (i=0; i<4; i=i+1) for (j=0; j<4; j=j+1) W[i][j] = $urandom(seed);
            for (i=0; i<4; i=i+1) gb_write(2'b00, i[7:0], {W[i][3], W[i][2], W[i][1], W[i][0]});
            
            // Randomize Vec Len (up to 32)
            vec_len = ($urandom(seed) % 32) + 1; // 1 to 32
            for (i=0; i<4; i=i+1) for (j=0; j<vec_len; j=j+1) X[i][j] = $urandom(seed);
            for (i=0; i<vec_len; i=i+1) gb_write(2'b01, i[7:0], {X[3][i], X[2][i], X[1][i], X[0][i]});
            
            compute_golden_model(vec_len);
            
            @(negedge clk); npu_en = 1; @(negedge clk); npu_en = 0;
            
            // Random Bubbles
            fork
                begin
                    global_timeout_cnt = 0;
                    while (!npu_valid && global_timeout_cnt < 200 + vec_len) begin
                        @(posedge clk); global_timeout_cnt = global_timeout_cnt + 1;
                    end
                    if (global_timeout_cnt >= 200 + vec_len) begin
                        $display("  [FATAL] Timeout in Random Test!"); err_count = err_count + 1;
                    end
                end
                begin
                    repeat(10) @(posedge clk);
                    repeat (4) begin // 4 random burst injections
                        if ($urandom(seed) % 2) begin
                            pause_stream <= 1;
                            repeat (($urandom(seed) % 5) + 1) @(posedge clk);
                            pause_stream <= 0;
                        end
                        repeat (($urandom(seed) % 10) + 1) @(posedge clk);
                    end
                end
            join
            
            check_obuf(vec_len);
        end

        $display("\n==================================================");
        if (err_count == 0)
            $display(" FINAL: ALL %0d CHECKS PASSED SUCCESSFULLY", total_tests);
        else
            $display(" FINAL: FAILED WITH %0d ERRORS OVER %0d CHECKS", err_count, total_tests);
        $display("==================================================\n");

        $finish;
    end

    // ========================================================
    // Layer 0: VCD Tracing
    // ========================================================
    initial begin
        $dumpfile("npu_v2.vcd");
        $dumpvars(0, npu_4_4_tb);
    end

endmodule