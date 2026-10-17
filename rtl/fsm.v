module fsm(
    input clk, rst,
    input x_valid_in,
    output reg x_valid_out,   // Passed to the next tile horizontally (1 cycle delay)
    output wire pipe_en,      // Enables the BBU pipeline register (combinational)
    output reg acc_en         // Enables the accumulator (delayed by 1 cycle)
);

    // 1. The RFU is combinational. When x_valid_in is high, RFU computes immediately.
    // We enable the pipeline register combinationally so it latches on the next clock edge.
    assign pipe_en = x_valid_in;

    always @(posedge clk) begin
        if (rst) begin
            x_valid_out <= 1'b0;
            acc_en      <= 1'b0;
        end else begin
            // 2. x_valid_out must be delayed by exactly 1 clock cycle to enforce 
            // the horizontal systolic heartbeat.
            x_valid_out <= x_valid_in;

            // 3. The accumulator needs to add the latched data. 
            // It operates 1 cycle AFTER the pipeline register latches.
            acc_en <= x_valid_in;
        end
    end

endmodule