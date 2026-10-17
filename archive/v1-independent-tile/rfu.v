module rfu(
    input  [7:0] x, y,
    input        sx, sy,
    input  [1:0] mode,
    output [79:0] out
);

    wire [3:0] xH = x[7:4];
    wire [3:0] xL = x[3:0];
    wire [3:0] yH = y[7:4];
    wire [3:0] yL = y[3:0];

    wire [19:0] p0, p1, p2, p3;

    BBU BBU0 (.x(xL), .y(yL), .sx(1'b0), .sy(1'b0), .mode(mode), .out(p0));
    BBU BBU1 (.x(xL), .y(yH), .sx(1'b0), .sy(sy),   .mode(mode), .out(p1));
    BBU BBU2 (.x(xH), .y(yL), .sx(sx),   .sy(1'b0), .mode(mode), .out(p2));
    BBU BBU3 (.x(xH), .y(yH), .sx(sx),   .sy(sy),   .mode(mode), .out(p3));
    
    wire signed [10:0] p0_11 = $signed(p0[10:0]);
    wire signed [10:0] p1_11 = $signed(p1[10:0]);
    wire signed [10:0] p2_11 = $signed(p2[10:0]);
    wire signed [10:0] p3_11 = $signed(p3[10:0]);


    wire signed [11:0] mid         = p1_11 + p2_11;
    wire signed [18:0] p3_shifted  = {p3_11, 8'b0};
    wire signed [18:0] mid_shifted = {{3{mid[11]}}, mid, 4'b0};
    wire signed [18:0] p0_ext      = {{8{p0_11[10]}}, p0_11};
    wire signed [18:0] fused_ext      = (p3_shifted + mid_shifted + p0_ext);
    wire signed [15:0] fused = fused_ext[15:0];


    assign out = (mode == 2'b00)
               ? {p3[19:0], p2[19:0], p1[19:0], p0[19:0]}        
               : (mode == 2'b01)
               ? {36'b0, p3[10:0], p2[10:0], p1[10:0], p0[10:0]} 
               : {64'b0, fused};                                   

endmodule