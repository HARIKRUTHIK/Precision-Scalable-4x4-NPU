module psmac_top(
    input        clk, rst,
    input        psmac_en,
    input  [1:0] mode,
    input        sx, sy,
    input  [7:0] vec_len,
    input        we_w,
    input  [7:0] w_addr, w_data,
    input        we_x,
    input  [7:0] x_addr, x_data,
    output [31:0] result,
    output        out_valid
   
);

    wire        clear, acc_en, pipe_en;
    wire        out_valid_fsm;
    wire [7:0]  addr;
    wire [7:0]  x_out, w_out;
    wire [79:0] rfu_out_wire;
    wire [79:0] data_out;
    wire [1:0]  mode_out;
    wire        sx_out, sy_out;

    
    // Cycle N:   addr → x_out/w_out valid (combinational)
    //            RFU computes (combinational)
    // Cycle N+1: pipe_reg latches RFU → data_out valid
    // Cycle N+2: accumulator adds
    // acc_en_d1 aligns acc_en with pipe_reg output

    reg acc_en_d1;
    always @(posedge clk) begin
        if (rst) acc_en_d1 <= 1'b0;
        else     acc_en_d1 <= acc_en;
    end

    // out_valid: 1-cycle delay to align with result stability
    reg ov_d1;
    always @(posedge clk) begin
        if (rst) ov_d1 <= 1'b0;
        else     ov_d1 <= out_valid_fsm;
    end
    assign out_valid = ov_d1;

    fsm FSM(
        .clk(clk), .rst(rst),
        .psmac_en(psmac_en),
        .mode(mode),
        .vec_len(vec_len),
        .clear(clear),
        .acc_en(acc_en),
        .pipe_en(pipe_en),
        .out_valid(out_valid_fsm),
        .addr(addr)
    );

    weight_mem #(.DEPTH(256)) WEIGHT_MEM(
        .clk(clk),
        .addr(addr),
        .we_w(we_w), .w_addr(w_addr), .w_data(w_data),
        .we_x(we_x), .x_addr(x_addr), .x_data(x_data),
        .x_out(x_out), .w_out(w_out)
    );

    rfu RFU(
        .x(x_out), .y(w_out),
        .sx(sx), .sy(sy),
        .mode(mode),
        .out(rfu_out_wire)
    );

    pipe_reg PIPELINE(
        .clk(clk), .rst(rst),
        .en(pipe_en),
        .sx(sx), .sy(sy),
        .mode_in(mode),
        .rfu_out(rfu_out_wire),
        .data_out(data_out),
        .mode_out(mode_out),
        .sx_out(sx_out), .sy_out(sy_out)
    );

    accumulator ACCUMULATOR(
        .clk(clk), .rst(rst),
        .data_out(data_out),
        .mode_out(mode_out),
        .acc_en(acc_en_d1),
        .clear(clear),
        .result(result)
    );

   

endmodule