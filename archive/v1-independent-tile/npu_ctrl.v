module npu_ctrl (
    input        clk,
    input        rst,
    input        npu_en,
    input  [1:0] mode,
    input  [7:0] vec_len,
    input        all_valid,
    input  [7:0]  load_data,

    output reg        psmac_en_out,
    output reg [3:0]  tile_sel,
    output reg [1:0]  col_sel,
    output reg        we_w_out,
    output reg        we_x_out,
    output reg [7:0]  load_addr,
    output reg        npu_valid,
    output reg [2:0]  state_dbg
);


    localparam IDLE    = 3'd0;
    localparam LOAD_W  = 3'd1;
    localparam LOAD_X  = 3'd2;
    localparam RUN     = 3'd3;
    localparam COLLECT = 3'd4;

    reg [2:0] state, next_state;

    reg [7:0] load_cnt;   
    reg [3:0] sel_cnt;    

   
    reg saw_low;          

    always @(posedge clk) begin
        if (rst)
            state <= IDLE;
        else
            state <= next_state;
    end


    always @(*) begin
        case (state)
            IDLE:    next_state = npu_en ? LOAD_W : IDLE;
            LOAD_W:  next_state = (sel_cnt == 4'd15 && load_cnt == vec_len - 8'd1) ? LOAD_X : LOAD_W;
            LOAD_X:  next_state = (sel_cnt == 4'd3  && load_cnt == vec_len - 8'd1) ? RUN    : LOAD_X;
            RUN:     next_state = COLLECT;          // unconditional — exactly 1 cycle
            COLLECT: next_state = (saw_low && all_valid) ? IDLE : COLLECT;
            default: next_state = IDLE;
        endcase
    end

   
    always @(posedge clk) begin
        if (rst) begin
            load_cnt <= 8'd0;
            sel_cnt  <= 4'd0;
            saw_low  <= 1'b0;
        end else begin
            case (state)
                LOAD_W, LOAD_X: begin
                    if (next_state != state) begin
                        
                        load_cnt <= 8'd0;
                        sel_cnt  <= 4'd0;
                    end else if (load_cnt == vec_len - 8'd1) begin
                        
                        load_cnt <= 8'd0;
                        sel_cnt  <= sel_cnt + 4'd1;
                    end else begin
                        load_cnt <= load_cnt + 8'd1;
                    end
                end
                COLLECT: begin
                   
                    if (!all_valid)
                        saw_low <= 1'b1;
                    
                    if (next_state == IDLE)
                        saw_low <= 1'b0;
                end
                default: begin
                    load_cnt <= 8'd0;
                    sel_cnt  <= 4'd0;
                    saw_low  <= 1'b0;
                end
            endcase
        end
    end

 
    always @(*) begin
        // Safe defaults — prevents latches
        we_w_out     = 1'b0;
        we_x_out     = 1'b0;
        psmac_en_out = 1'b0;
        tile_sel     = 4'd0;
        col_sel      = 2'd0;
        load_addr    = 8'd0;
        

        case (state)
            LOAD_W: begin
                we_w_out  = 1'b1;
                tile_sel  = sel_cnt;
                load_addr = load_cnt;
            end
            LOAD_X: begin
                we_x_out  = 1'b1;
                col_sel   = sel_cnt[1:0];
                load_addr = load_cnt;
            end
            RUN: begin
                psmac_en_out = 1'b1;   
            end
            default: ; 
        endcase
    end


 
    always @(posedge clk) begin
        if (rst)
            npu_valid <= 1'b0;
        else if (state == COLLECT && saw_low && all_valid)
            npu_valid <= 1'b1;
        else if (state == IDLE)         
            npu_valid <= 1'b0;
    end


    always @(*) begin
        state_dbg = state;
    end

endmodule