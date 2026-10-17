module psmac_top(
    input         clk, rst,
    input  [1:0]  mode,
    input         sx, sy,
    
    // Horizontal Systolic Flow (Input Features)
    input  [7:0]  x_in,
    input         x_valid_in,
    output reg [7:0] x_out,
    output        x_valid_out,
    
    // Vertical Systolic Flow (Partial Sums)
    input  [31:0] psum_in,
    output [31:0] psum_out,

    // Weight Load (Direct from Global Buffer via mesh wiring)
    input  [7:0]  w_in,
    input         w_valid
);

    // ==========================================
    // 1. Stationary Weight Register
    // ==========================================
    reg [7:0] w_reg;
    reg [1:0] mode_reg;
    reg       sx_reg, sy_reg;
    
    always @(posedge clk) begin
        if (rst) begin
            w_reg    <= 8'b0;
            mode_reg <= 2'b10; // Default INT8
            sx_reg   <= 1'b0;
            sy_reg   <= 1'b0;
        end else if (w_valid) begin
            w_reg    <= w_in;
            mode_reg <= mode;
            sx_reg   <= sx;
            sy_reg   <= sy;
        end
    end

    // ==========================================
    // 2. Data Propagation
    // ==========================================
    always @(posedge clk) begin
        if (rst) x_out <= 8'b0;
        else     x_out <= x_in;     // 1 clock cycle horizontal heartbeat
    end

    // ==========================================
    // 3. Control Pipeline (FSM)
    // ==========================================
    wire pipe_en;
    wire acc_en;

    fsm SYSTOLIC_CTRL (
        .clk(clk),
        .rst(rst),
        .x_valid_in(x_valid_in),
        .x_valid_out(x_valid_out),
        .pipe_en(pipe_en),
        .acc_en(acc_en)
    );

    // ==========================================
    // 4. Arithmetic Core (BitFusion)
    // ==========================================
    wire [79:0] rfu_out_wire;
    wire [79:0] data_out;
    wire [1:0]  mode_out;
    wire        sx_out, sy_out;

    // Operand isolation: freeze inputs when no valid data to save power
    wire [7:0] gated_x = x_valid_in ? x_in : 8'b0;

    rfu RFU (
        .x(gated_x), .y(w_reg), // Computes combinationally using incoming x and stationary w
        .sx(sx_reg), .sy(sy_reg),
        .mode(mode_reg),
        .out(rfu_out_wire)
    );

    pipe_reg PIPELINE (
        .clk(clk), .rst(rst),
        .en(pipe_en),
        .sx(sx_reg), .sy(sy_reg),
        .mode_in(mode_reg),
        .rfu_out(rfu_out_wire),
        .data_out(data_out),
        .mode_out(mode_out),
        .sx_out(sx_out), .sy_out(sy_out)
    );

    accumulator ACCUMULATOR (
        .clk(clk), .rst(rst),
        .data_out(data_out),
        .mode_out(mode_out),
        .acc_en(acc_en),
        .psum_in(psum_in),      // Receives from tile above
        .psum_out(psum_out)     // Sends to tile below
    );

endmodule