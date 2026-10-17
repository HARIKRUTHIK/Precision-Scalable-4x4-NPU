module npu_ctrl (
    input        clk,
    input        rst,
    input        npu_en,
    input  [7:0] vec_len,
    input        pause_stream,

    // Signals to Global Buffer
    output reg   load_w_en,
    output reg   stream_x_en,

    // Status
    output reg   npu_valid,
    output [2:0] state_dbg
);

    // ========================================================
    // State Machine
    // ========================================================
    // IDLE     -> Wait for npu_en pulse from host
    // LOAD_W   -> Pulse load_w_en for 1 cycle to trigger weight streaming
    // WAIT_W   -> Wait for weights to propagate through the 4x4 mesh (4 cycles)
    // STREAM_X -> Pulse stream_x_en for 1 cycle to trigger skewed X streaming
    // WAIT_X   -> Wait for the entire systolic wavefront to complete
    // DONE     -> Signal npu_valid to host, return to IDLE

    localparam IDLE     = 3'd0;
    localparam LOAD_W   = 3'd1;
    localparam WAIT_W   = 3'd2;
    localparam STREAM_X = 3'd3;
    localparam WAIT_X   = 3'd4;
    localparam DONE     = 3'd5;

    reg [2:0] state, next_state;
    reg [8:0] wait_cnt;

    // The weight loading takes 4 cycles from the Global Buffer (addresses 0..3),
    // plus 3 more cycles for the last weight to shift across 4 columns.
    // Total weight settling time = vec_len + 3 cycles.
    // But the Global Buffer's w_valid auto-runs for 4 cycles (addresses 0..3).
    // After that, we need 3 more cycles for the rightmost column to latch.
    // So WAIT_W needs to count: 4 (GB streaming) + 3 (shift) = 7 cycles.

    // The X streaming takes vec_len cycles from the Global Buffer,
    // plus 3 cycles of skew delay (Row 3 starts 3 cycles late),
    // plus 3 cycles for horizontal propagation to col 3,
    // plus 2 cycles for the pipeline inside each tile (pipe_reg + accumulator).
    // Total: vec_len + 3 (skew) + 3 (horizontal) + 2 (pipeline) = vec_len + 8 cycles.

    always @(posedge clk) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end

    always @(*) begin
        case (state)
            IDLE:     next_state = npu_en ? LOAD_W : IDLE;
            LOAD_W:   next_state = WAIT_W;  // Single-cycle pulse
            WAIT_W:   next_state = (wait_cnt == 9'd6) ? STREAM_X : WAIT_W; // 7 cycles (0..6)
            STREAM_X: next_state = WAIT_X;  // Single-cycle pulse
            WAIT_X:   next_state = (wait_cnt == {1'b0, vec_len} + 9'd8) ? DONE : WAIT_X;
            DONE:     next_state = IDLE;
            default:  next_state = IDLE;
        endcase
    end

    // Wait counter
    always @(posedge clk) begin
        if (rst) begin
            wait_cnt <= 9'd0;
        end else begin
            case (state)
                WAIT_W: wait_cnt <= wait_cnt + 9'd1;
                WAIT_X: if (!pause_stream) wait_cnt <= wait_cnt + 9'd1;
                default: wait_cnt <= 9'd0;
            endcase
        end
    end

    // Output signals
    always @(*) begin
        load_w_en   = (state == LOAD_W);
        stream_x_en = (state == STREAM_X);
    end

    // npu_valid: Goes high for 1 cycle when computation is complete
    always @(posedge clk) begin
        if (rst)
            npu_valid <= 1'b0;
        else if (state == DONE)
            npu_valid <= 1'b1;
        else
            npu_valid <= 1'b0;
    end

    assign state_dbg = state;

endmodule