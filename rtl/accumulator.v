module accumulator(
    input             clk, rst,
    input      [79:0] data_out,
    input      [1:0]  mode_out,
    input             acc_en,
    input      [31:0] psum_in,
    output reg [31:0] psum_out
);

    // INT8
    wire signed [31:0] int8_sum = {{13{data_out[18]}}, data_out[18:0]};

   //INT4
    wire signed [31:0] int4_p0  = {{21{data_out[10]}}, data_out[10:0]};
    wire signed [31:0] int4_p3  = {{21{data_out[43]}}, data_out[43:33]};
    wire signed [31:0] int4_sum = int4_p0 + int4_p3;

   //INT2
    wire signed [31:0] int2_p0  = {{27{data_out[4]}},  data_out[4:0]};
    wire signed [31:0] int2_p1  = {{27{data_out[19]}}, data_out[19:15]};
    wire signed [31:0] int2_p2  = {{27{data_out[64]}}, data_out[64:60]};
    wire signed [31:0] int2_p3  = {{27{data_out[79]}}, data_out[79:75]};
    wire signed [31:0] int2_sum = int2_p0 + int2_p1 + int2_p2 + int2_p3;

    wire signed [31:0] tree_out = (mode_out == 2'b10) ? int8_sum :
                                   (mode_out == 2'b01) ? int4_sum :
                                                         int2_sum;

    always @(posedge clk) begin
        if (rst) begin
            psum_out <= 32'b0;
        end else if (acc_en) begin
            psum_out <= psum_in + tree_out;
        end else begin
            psum_out <= 32'b0; // Clear when inactive to prevent stale data
        end
    end

endmodule