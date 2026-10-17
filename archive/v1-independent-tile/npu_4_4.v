module npu_4_4 #(
    parameter ROWS  = 4,
    parameter COLS  = 4,
    parameter DEPTH = 256
)(
    input              clk,
    input              rst,
    input              npu_en,
    input  [1:0]       mode,
    input  [7:0]       vec_len,
    input              sx, sy,
    input              we_w,
    input  [3:0]       tile_sel,
    input  [7:0]       w_addr,
    input  [7:0]       w_data,
    input              we_x,
    input  [1:0]       col_sel,
    input  [7:0]       x_addr,
    input  [7:0]       x_data,
    input  [3:0]       result_sel,
    output reg [31:0]  result_out,
    output             out_valid
);

wire        psmac_en;
wire [31:0] result_w [0:15];
wire [15:0] ov_bus;


wire [2:0] state_dbg;
wire       npu_valid;
wire       ctrl_we_w_unused;   
wire       ctrl_we_x_unused;
wire [7:0] ctrl_load_addr_unused;
    ₹
genvar r, c;
generate
    for (r = 0; r < ROWS; r = r+1) begin : row
        for (c = 0; c < COLS; c = c+1) begin : col

            localparam IDX = r*COLS + c;

            
            wire we_w_gated = we_w & (tile_sel == IDX);
            wire we_x_gated = we_x & (col_sel  == c  );

            psmac_top tile (
                .clk      (clk),
                .rst      (rst),
                .psmac_en (psmac_en),
                .mode     (mode),
                .sx       (sx),
                .sy       (sy),
                .vec_len  (vec_len),
                .we_w     (we_w_gated),
                .w_addr   (w_addr),
                .w_data   (w_data),
                .we_x     (we_x_gated),
                .x_addr   (x_addr),
                .x_data   (x_data),
                .result   (result_w[IDX]),
                .out_valid(ov_bus[IDX])
            );

        end
    end
endgenerate
assign out_valid = &ov_bus;

always @(*) begin
    result_out = result_w[result_sel];
end

npu_ctrl CTRL (
    .clk         (clk),
    .rst         (rst),
    .npu_en      (npu_en),
    .mode        (mode),
    .vec_len     (vec_len),
    .all_valid   (out_valid),
    .psmac_en_out(psmac_en),
    .tile_sel    (tile_sel),
    .col_sel     (col_sel),
    .we_w_out    (ctrl_we_w_unused),
    .we_x_out    (ctrl_we_x_unused),
    .load_addr   (ctrl_load_addr_unused),
    .load_data   (8'd0),
    .npu_valid   (npu_valid),
    .state_dbg   (state_dbg)
);



endmodule