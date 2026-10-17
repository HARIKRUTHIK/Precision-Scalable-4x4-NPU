module BBU(
    input  [3:0] x, y,
    input        sx, sy,
    input  [1:0] mode,
    output [19:0] out        
);

    wire [2:0] xH = {x[3], x[3:2]};
    wire [2:0] xL = {1'b0, x[1:0]};
    wire [2:0] yH = {y[3], y[3:2]};
    wire [2:0] yL = {1'b0, y[1:0]};

    wire signed [4:0] p00, p01, p10, p11;

    sbb SBB00 (.x(xL), .y(yL), .sx(1'b0), .sy(1'b0), .p(p00));
    sbb SBB01 (.x(xL), .y(yH), .sx(1'b0), .sy(sy),   .p(p01));
    sbb SBB10 (.x(xH), .y(yL), .sx(sx),   .sy(1'b0), .p(p10));
    sbb SBB11 (.x(xH), .y(yH), .sx(sx),   .sy(sy),   .p(p11));

    wire do_fuse = (mode != 2'b00);  // Fuse for INT8 and INT4, not INT2

    wire signed [4:0] g_p00 = do_fuse ? p00 : 5'sd0;
    wire signed [4:0] g_p01 = do_fuse ? p01 : 5'sd0;
    wire signed [4:0] g_p10 = do_fuse ? p10 : 5'sd0;
    wire signed [4:0] g_p11 = do_fuse ? p11 : 5'sd0;

    wire signed [5:0]  mid         = g_p01 + g_p10;
    wire signed [10:0] p11_shifted = {{2{g_p11[4]}}, g_p11, 4'b0000};
    wire signed [10:0] mid_shifted = {{3{mid[5]}},  mid, 2'b00};
    wire signed [10:0] p00_ext     = {{6{g_p00[4]}},  g_p00};

    wire signed [10:0] fused = p11_shifted + mid_shifted + p00_ext;


    wire [4:0] p00u = p00[4:0];
    wire [4:0] p01u = p01[4:0];
    wire [4:0] p10u = p10[4:0];
    wire [4:0] p11u = p11[4:0];

    assign out = (mode == 2'b00) ? {p11u, p10u, p01u, p00u}  
               : {{9{fused[10]}}, fused};                      

endmodule