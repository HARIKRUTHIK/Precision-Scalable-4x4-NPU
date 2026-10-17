module pipe_reg(
    input clk,rst,en,sx,sy,
    input [1:0]mode_in,
    input [79:0]rfu_out,
    output reg [79:0] data_out,
    output reg [1:0]mode_out,
    output reg sx_out, sy_out

);

always @(posedge clk) begin
    if (rst) begin
        data_out<=0;
        mode_out<=0;
        sx_out<=0;
        sy_out<=0;
    end

    else if (en) begin
        data_out<=rfu_out;
        mode_out<=mode_in;
        sx_out<=sx;
        sy_out<=sy;
    end
    
end

endmodule