module weight_mem #(parameter DEPTH=256)(
    input             clk,
    input      [7:0]  addr,

    input             we_w,
    input      [7:0]  w_addr,
    input      [7:0]  w_data,

    input             we_x,
    input      [7:0]  x_addr,
    input      [7:0]  x_data,

    output     [7:0]  x_out,
    output     [7:0]  w_out
);

    reg [7:0] x_mem [0:DEPTH-1];
    reg [7:0] w_mem [0:DEPTH-1];

    // Asynchronous read -- x_out and w_out valid combinationally
    assign x_out = x_mem[addr];
    assign w_out = w_mem[addr];

    always @(posedge clk) begin
        if (we_w) w_mem[w_addr] <= w_data;
    end

    always @(posedge clk) begin
        if (we_x) x_mem[x_addr] <= x_data;
    end

endmodule