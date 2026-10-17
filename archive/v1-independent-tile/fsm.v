module fsm(
    input            clk, rst,
    input            psmac_en,
    input      [1:0] mode,
    input      [7:0] vec_len,
    output reg       clear, acc_en, pipe_en, out_valid,
    output reg [7:0] addr
);

    parameter IDLE  = 2'b00;
    parameter CLEAR = 2'b01;
    parameter RUN   = 2'b10;
    parameter DONE  = 2'b11;

    reg [1:0] state, next_state;
    reg [7:0] counter;
    reg [7:0] run_target;

    always @(*) begin
        case(mode)
            2'b10:   run_target = vec_len;
            2'b01:   run_target = vec_len >> 1;
            2'b00:   run_target = vec_len >> 2;
            default: run_target = vec_len;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            state   <= IDLE;
            counter <= 8'b0;
        end else begin
            state <= next_state;
            case(state)
                IDLE:  counter <= 8'b0;
                CLEAR: counter <= 8'b0;
                RUN:   counter <= counter + 1;
                default: counter <= 8'b0;
            endcase
        end
    end

    always @(*) begin
        case(state)
            IDLE:    next_state = psmac_en ? CLEAR : IDLE;
            CLEAR:   next_state = RUN;
            RUN:     next_state = (counter == run_target - 1) ? DONE : RUN;
            DONE:    next_state = IDLE;
            default: next_state = IDLE;
        endcase
    end

    always @(*) begin
        clear   = 1'b0;
        acc_en  = 1'b0;
        pipe_en = 1'b0;
        addr    = 8'b0;
        case(state)
            IDLE:  begin end
            CLEAR: begin clear = 1'b1; end
            RUN:   begin acc_en=1'b1; pipe_en=1'b1; addr=counter; end
            DONE:  begin pipe_en=1'b1; end
        endcase
    end

    always @(posedge clk) begin
        if (rst)
            out_valid <= 1'b0;
        else if (state == DONE)
            out_valid <= 1'b1;
        else if (state == IDLE && psmac_en)
            out_valid <= 1'b0;
    end

endmodule