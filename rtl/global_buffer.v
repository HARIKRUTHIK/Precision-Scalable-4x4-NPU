module global_buffer #(
    parameter DEPTH = 256
)(
    input clk,
    input rst,

    // --------------------------------------------------------
    // Host Interface
    // --------------------------------------------------------
    input         host_we,
    input [1:0]   host_bank_sel, // 2'b00 = W-Buffer, 2'b01 = X-Buffer
    input [7:0]   host_addr,
    input [31:0]  host_data,     // 32-bits to write 4 bytes at once
    input         pause_stream,  // Inject bubbles in X stream

    // --------------------------------------------------------
    // Controller Interface
    // --------------------------------------------------------
    input         load_w_en,     // Triggers weight streaming
    input         stream_x_en,   // Triggers input streaming + skew
    input [7:0]   vec_len,       // Number of vectors to stream

    // --------------------------------------------------------
    // Array Feed: Weights (broadcast to all tiles)
    // --------------------------------------------------------
    // w_out_0..3 carry the 4 COLUMN weights for the current row.
    // w_row tells the mesh which ROW should latch these weights.
    // Memory layout: w_sram[row] = {W[row][3], W[row][2], W[row][1], W[row][0]}
    output reg [7:0] w_out_0, w_out_1, w_out_2, w_out_3,
    output reg       w_valid,
    output reg [1:0] w_row,      // Which row should latch (0..3)
    output reg [1:0] w_mode,     // Mode for the row being loaded
    output reg       w_sx,       // Signed x flag for the row
    output reg       w_sy,       // Signed y flag for the row

    // --------------------------------------------------------
    // Array Feed (Inputs with Skew to Col 0, rows 0..3)
    // --------------------------------------------------------
    output [7:0] x_out_0, x_out_1, x_out_2, x_out_3,
    output       x_valid_0, x_valid_1, x_valid_2, x_valid_3,

    // --------------------------------------------------------
    // Array Drain (Outputs from Row 3, cols 0..3)
    // --------------------------------------------------------
    input [31:0] psum_in_0, psum_in_1, psum_in_2, psum_in_3,
    input        psum_valid_0, psum_valid_1, psum_valid_2, psum_valid_3,
    
    // --------------------------------------------------------
    // Output to Host (Reading from O-Buffer)
    // --------------------------------------------------------
    input [3:0]   host_read_col,
    output reg [31:0] host_read_data
);

    // ========================================================
    // Internal Memories (The Warehouse)
    // ========================================================
    reg [31:0] w_sram [0:DEPTH-1];
    reg [31:0] x_sram [0:DEPTH-1];
    reg [3:0]  mode_sram [0:3];  // {sx, sy, mode[1:0]} per row
    reg [31:0] o_sram_0 [0:DEPTH-1];
    reg [31:0] o_sram_1 [0:DEPTH-1];
    reg [31:0] o_sram_2 [0:DEPTH-1];
    reg [31:0] o_sram_3 [0:DEPTH-1];

    reg [7:0] o_addr_0, o_addr_1, o_addr_2, o_addr_3;

    // Host Write Logic
    always @(posedge clk) begin
        if (host_we) begin
            if (host_bank_sel == 2'b00) w_sram[host_addr] <= host_data;
            if (host_bank_sel == 2'b01) x_sram[host_addr] <= host_data;
            if (host_bank_sel == 2'b10) mode_sram[host_addr[1:0]] <= host_data[3:0];
        end
    end

    // Host Read Logic (O-Buffer) - uses host_addr
    always @(*) begin
        case (host_read_col)
            4'd0: host_read_data = o_sram_0[host_addr];
            4'd1: host_read_data = o_sram_1[host_addr];
            4'd2: host_read_data = o_sram_2[host_addr];
            4'd3: host_read_data = o_sram_3[host_addr];
            default: host_read_data = 32'd0;
        endcase
    end

    // O-Buffer Write Logic (Catching the drips from the bottom edge)
    always @(posedge clk) begin
        if (rst || stream_x_en) begin
            o_addr_0 <= 8'd0;
            o_addr_1 <= 8'd0;
            o_addr_2 <= 8'd0;
            o_addr_3 <= 8'd0;
        end else begin
            if (psum_valid_0) begin o_sram_0[o_addr_0] <= psum_in_0; o_addr_0 <= o_addr_0 + 8'd1; end
            if (psum_valid_1) begin o_sram_1[o_addr_1] <= psum_in_1; o_addr_1 <= o_addr_1 + 8'd1; end
            if (psum_valid_2) begin o_sram_2[o_addr_2] <= psum_in_2; o_addr_2 <= o_addr_2 + 8'd1; end
            if (psum_valid_3) begin o_sram_3[o_addr_3] <= psum_in_3; o_addr_3 <= o_addr_3 + 8'd1; end
        end
    end

    // ========================================================
    // W-Buffer Read Logic (Load Weights Phase)
    // ========================================================
    // Weight loading is BROADCAST, not shifted.
    // w_sram[row] = {W[row][3], W[row][2], W[row][1], W[row][0]}
    //
    // Cycle 0: Read w_sram[0] -> output col weights for Row 0, w_row=0
    // Cycle 1: Read w_sram[1] -> output col weights for Row 1, w_row=1
    // Cycle 2: Read w_sram[2] -> output col weights for Row 2, w_row=2
    // Cycle 3: Read w_sram[3] -> output col weights for Row 3, w_row=3
    //
    // In the mesh, tile(r,c) only latches when w_valid=1 AND w_row==r.
    // tile(r,c) latches w_out_{c} as its stationary weight.

    reg [7:0] w_addr_cnt;

    always @(posedge clk) begin
        if (rst) begin
            w_addr_cnt <= 8'b0;
            w_valid <= 1'b0;
            w_row <= 2'b0;
            {w_out_3, w_out_2, w_out_1, w_out_0} <= 32'b0;
            w_mode <= 2'b10; // Default INT8
            w_sx <= 1'b0;
            w_sy <= 1'b0;
        end else if (load_w_en || w_valid) begin
            if (load_w_en) begin
                w_addr_cnt <= 8'b0;
                w_valid <= 1'b1;
                w_row <= 2'b0;
                {w_out_3, w_out_2, w_out_1, w_out_0} <= w_sram[0];
                {w_sx, w_sy, w_mode} <= mode_sram[0];
            end else if (w_addr_cnt < 3) begin
                w_addr_cnt <= w_addr_cnt + 1;
                w_row <= w_addr_cnt + 1;
                {w_out_3, w_out_2, w_out_1, w_out_0} <= w_sram[w_addr_cnt + 1];
                {w_sx, w_sy, w_mode} <= mode_sram[w_addr_cnt + 1];
            end else begin
                w_valid <= 1'b0;
            end
        end
    end

    // ========================================================
    // X-Buffer Read & The Skew Engine
    // ========================================================
    reg [7:0] x_addr_cnt;
    wire [31:0] x_sram_out = x_sram[x_addr_cnt];
    reg x_reading;

    always @(posedge clk) begin
        if (rst) begin
            x_addr_cnt <= 8'b0;
            x_reading <= 1'b0;
        end else if ((stream_x_en || x_reading) && !pause_stream) begin
            if (stream_x_en && !x_reading) begin
                x_reading <= 1'b1;
                x_addr_cnt <= 8'b0;
            end else if ((x_addr_cnt + 1) < vec_len) begin
                x_addr_cnt <= x_addr_cnt + 1;
            end else begin
                x_reading <= 1'b0;
            end
        end
    end

    // Break the 32-bit SRAM output into 4 rows of 8-bit pixels
    wire [7:0] raw_x0 = x_sram_out[7:0];
    wire [7:0] raw_x1 = x_sram_out[15:8];
    wire [7:0] raw_x2 = x_sram_out[23:16];
    wire [7:0] raw_x3 = x_sram_out[31:24];
    wire       raw_v  = x_reading & ~pause_stream;

    // Shift registers to enforce the Systolic Skew
    // Row 0 has 1 cycle delay
    // Row 1 has 2 cycle delay
    // Row 2 has 3 cycle delay
    // Row 3 has 4 cycle delay

    // Row 0 (1 cycle)
    reg [7:0] r0_x;
    reg       r0_v;

    // Row 1 (2 cycles)
    reg [7:0] r1_x_d1, r1_x_d2;
    reg       r1_v_d1, r1_v_d2;

    // Row 2 (3 cycles)
    reg [7:0] r2_x_d1, r2_x_d2, r2_x_d3;
    reg       r2_v_d1, r2_v_d2, r2_v_d3;

    // Row 3 (4 cycles)
    reg [7:0] r3_x_d1, r3_x_d2, r3_x_d3, r3_x_d4;
    reg       r3_v_d1, r3_v_d2, r3_v_d3, r3_v_d4;

    always @(posedge clk) begin
        if (rst) begin
            r0_x <= 0; r0_v <= 0;
            r1_x_d1 <= 0; r1_x_d2 <= 0;
            r1_v_d1 <= 0; r1_v_d2 <= 0;
            r2_x_d1 <= 0; r2_x_d2 <= 0; r2_x_d3 <= 0;
            r2_v_d1 <= 0; r2_v_d2 <= 0; r2_v_d3 <= 0;
            r3_x_d1 <= 0; r3_x_d2 <= 0; r3_x_d3 <= 0; r3_x_d4 <= 0;
            r3_v_d1 <= 0; r3_v_d2 <= 0; r3_v_d3 <= 0; r3_v_d4 <= 0;
        end else begin
            // Propagate Row 0
            r0_x <= raw_x0;
            r0_v <= raw_v;

            // Propagate Row 1
            r1_x_d1 <= raw_x1; r1_x_d2 <= r1_x_d1;
            r1_v_d1 <= raw_v;  r1_v_d2 <= r1_v_d1;

            // Propagate Row 2
            r2_x_d1 <= raw_x2; r2_x_d2 <= r2_x_d1; r2_x_d3 <= r2_x_d2;
            r2_v_d1 <= raw_v;  r2_v_d2 <= r2_v_d1; r2_v_d3 <= r2_v_d2;

            // Propagate Row 3
            r3_x_d1 <= raw_x3; r3_x_d2 <= r3_x_d1; r3_x_d3 <= r3_x_d2; r3_x_d4 <= r3_x_d3;
            r3_v_d1 <= raw_v;  r3_v_d2 <= r3_v_d1; r3_v_d3 <= r3_v_d2; r3_v_d4 <= r3_v_d3;
        end
    end

    // Assign final skewed outputs to the array
    assign x_out_0 = r0_x;
    assign x_valid_0 = r0_v;

    assign x_out_1 = r1_x_d2;
    assign x_valid_1 = r1_v_d2;

    assign x_out_2 = r2_x_d3;
    assign x_valid_2 = r2_v_d3;

    assign x_out_3 = r3_x_d4;
    assign x_valid_3 = r3_v_d4;

endmodule
