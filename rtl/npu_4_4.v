module npu_4_4 #(
    parameter ROWS  = 4,
    parameter COLS  = 4,
    parameter DEPTH = 256
)(
    input              clk,
    input              rst,
    input              npu_en,
    // DEPRECATED: mode/sx/sy kept for backward-compatibility with host interface only.
    // Per-row precision is now configured via host writes to bank_sel=2'b10 (mode_sram).
    // These ports are NOT connected to any tile — they are intentionally left unconnected.
    input  [1:0]       mode,   // unused — configure precision via host_bank_sel=2'b10
    input  [7:0]       vec_len,
    input              sx, sy, // unused — configure precision via host_bank_sel=2'b10

    // Host writes to Global Buffer
    input              host_we,
    input  [1:0]       host_bank_sel,
    input  [7:0]       host_addr,
    input  [31:0]      host_data,
    input              pause_stream, // New input for testing

    // Host reads from O-Buffer
    input  [3:0]       host_read_col,
    output [31:0]      host_read_data,

    // Status
    output             npu_valid,
    output [2:0]       state_dbg
);

    // ========================================================
    // Internal Wires: Global Buffer <-> Mesh
    // ========================================================

    // Weight bus: GB broadcasts 4 column-weights + row selector
    wire [7:0] gb_w_out [0:3]; // gb_w_out[col] = weight for that column
    wire       gb_w_valid;
    wire [1:0] gb_w_row;       // Which row should latch
    // Per-row mode config: driven by global_buffer with a DIFFERENT value each LOAD_W
    // cycle (one per row). Each tile only latches when tile_w_valid is high for its row.
    wire [1:0] gb_row_mode; // mode for the row currently being loaded (changes each cycle)
    wire       gb_row_sx;   // sx  for the row currently being loaded
    wire       gb_row_sy;   // sy  for the row currently being loaded

    // X bus: GB skewed outputs -> Col 0 left edge of each row
    wire [7:0] gb_x_out_0, gb_x_out_1, gb_x_out_2, gb_x_out_3;
    wire       gb_x_valid_0, gb_x_valid_1, gb_x_valid_2, gb_x_valid_3;

    // Controller signals
    wire load_w_en, stream_x_en;

    // ========================================================
    // Mesh Interconnect Wires
    // ========================================================

    // Horizontal: x data and valid flowing left->right across columns
    wire [7:0]  x_h [0:ROWS-1][0:COLS]; // index 0 = left edge input
    wire        xv_h [0:ROWS-1][0:COLS]; // valid for above

    // Vertical: psum flowing top->bottom across rows
    wire [31:0] psum_v [0:ROWS][0:COLS-1]; // index 0 = top edge (0)

    // ========================================================
    // Connect Global Buffer outputs to mesh edges
    // ========================================================

    // X inputs: Global Buffer skewed outputs -> Col 0 left edge
    assign x_h[0][0] = gb_x_out_0;  assign xv_h[0][0] = gb_x_valid_0;
    assign x_h[1][0] = gb_x_out_1;  assign xv_h[1][0] = gb_x_valid_1;
    assign x_h[2][0] = gb_x_out_2;  assign xv_h[2][0] = gb_x_valid_2;
    assign x_h[3][0] = gb_x_out_3;  assign xv_h[3][0] = gb_x_valid_3;

    // Psum inputs: Top edge is 0 (no tile above row 0)
    assign psum_v[0][0] = 32'd0;
    assign psum_v[0][1] = 32'd0;
    assign psum_v[0][2] = 32'd0;
    assign psum_v[0][3] = 32'd0;

    // ========================================================
    // 4x4 Tile Mesh (The Heart of the NPU)
    // ========================================================
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : row
            for (c = 0; c < COLS; c = c + 1) begin : col

                // tile_w_valid is HIGH for exactly ONE row per LOAD_W cycle.
                // That row's tiles latch w_in AND gb_row_mode/sx/sy simultaneously,
                // giving each row its own independent stationary precision config.
                wire tile_w_valid = gb_w_valid & (gb_w_row == r[1:0]);

                psmac_top tile (
                    .clk(clk), .rst(rst),
                    .mode(gb_row_mode), .sx(gb_row_sx), .sy(gb_row_sy), // per-row precision

                    // Horizontal X flow: left -> right
                    .x_in(x_h[r][c]),
                    .x_valid_in(xv_h[r][c]),
                    .x_out(x_h[r][c+1]),
                    .x_valid_out(xv_h[r][c+1]),

                    // Vertical Psum flow: top -> bottom
                    .psum_in(psum_v[r][c]),
                    .psum_out(psum_v[r+1][c]),

                    // Weight: direct from GB, gated by row
                    .w_in(gb_w_out[c]),
                    .w_valid(tile_w_valid)
                );

            end
        end
    endgenerate

    // ========================================================
    // Bottom Edge Psum Valid -> O-Buffer
    // ========================================================
    // psum_out from bottom row is valid when the accumulator inside
    // the bottom tile fires (acc_en). acc_en is 1 cycle after x_valid_in.
    // x_valid_out of tile(3,c) = xv_h[3][c+1].
    // acc_en fires same cycle as x_valid_out. So psum_out is valid
    // the cycle acc_en is high = same cycle x_valid_out is high.
    // But psum_out is registered (posedge), so it's valid 1 cycle AFTER acc_en.
    // We need a 1-cycle delay of x_valid_out from the bottom row.

    wire psum_valid_bottom [0:COLS-1];
    generate
        for (c = 0; c < COLS; c = c + 1) begin : psum_valid_gen
            reg pv_d1;
            always @(posedge clk) begin
                if (rst) pv_d1 <= 1'b0;
                else     pv_d1 <= xv_h[ROWS-1][c+1]; // x_valid_out of bottom tile
            end
            assign psum_valid_bottom[c] = pv_d1;
        end
    endgenerate

    // ========================================================
    // Global Buffer Instance
    // ========================================================
    wire [7:0] gb_w_out_0, gb_w_out_1, gb_w_out_2, gb_w_out_3;
    assign gb_w_out[0] = gb_w_out_0;
    assign gb_w_out[1] = gb_w_out_1;
    assign gb_w_out[2] = gb_w_out_2;
    assign gb_w_out[3] = gb_w_out_3;

    global_buffer #(.DEPTH(DEPTH)) GBUF (
        .clk(clk), .rst(rst),

        // Host Interface
        .host_we(host_we),
        .host_bank_sel(host_bank_sel),
        .host_addr(host_addr),
        .host_data(host_data),
        .pause_stream(pause_stream),

        // Controller Interface
        .load_w_en(load_w_en),
        .stream_x_en(stream_x_en),
        .vec_len(vec_len),

        // Weight outputs -> broadcast to all tiles
        .w_out_0(gb_w_out_0), .w_out_1(gb_w_out_1),
        .w_out_2(gb_w_out_2), .w_out_3(gb_w_out_3),
        .w_valid(gb_w_valid),
        .w_row(gb_w_row),
        .w_mode(gb_row_mode),
        .w_sx(gb_row_sx),
        .w_sy(gb_row_sy),

        // Skewed X outputs -> mesh left edge
        .x_out_0(gb_x_out_0), .x_out_1(gb_x_out_1),
        .x_out_2(gb_x_out_2), .x_out_3(gb_x_out_3),
        .x_valid_0(gb_x_valid_0), .x_valid_1(gb_x_valid_1),
        .x_valid_2(gb_x_valid_2), .x_valid_3(gb_x_valid_3),

        // Bottom edge -> O-Buffer
        .psum_in_0(psum_v[ROWS][0]), .psum_in_1(psum_v[ROWS][1]),
        .psum_in_2(psum_v[ROWS][2]), .psum_in_3(psum_v[ROWS][3]),
        .psum_valid_0(psum_valid_bottom[0]), .psum_valid_1(psum_valid_bottom[1]),
        .psum_valid_2(psum_valid_bottom[2]), .psum_valid_3(psum_valid_bottom[3]),

        // Host read
        .host_read_col(host_read_col),
        .host_read_data(host_read_data)
    );

    // ========================================================
    // NPU Controller (The Maestro)
    // ========================================================
    npu_ctrl CTRL (
        .clk(clk),
        .rst(rst),
        .npu_en(npu_en),
        .vec_len(vec_len),
        .pause_stream(pause_stream),
        .load_w_en(load_w_en),
        .stream_x_en(stream_x_en),
        .npu_valid(npu_valid),
        .state_dbg(state_dbg)
    );

endmodule