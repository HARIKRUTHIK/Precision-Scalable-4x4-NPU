

module sbb (
    input  [2:0] x,      
    input  [2:0] y,
    input        sx,     
    input        sy,     
    output signed [4:0] p
);



wire x2 = x[2] & sx;
wire y2 = y[2] & sy;


wire x0y0 = x[0] & y[0];
wire x0y1 = x[0] & y[1];
wire x0y2 = ~(x[0] & y2);   
wire x1y0 = x[1] & y[0];
wire x1y1 = x[1] & y[1];
wire x1y2 = ~(x[1] & y2);   
wire x2y0 = ~(x2   & y[0]); 
wire x2y1 = ~(x2   & y[1]); 
wire x2y2 =   x2   & y2;    


assign p[0] = x0y0;


wire c1;
ha HA1 (
    .a(x0y1), .b(x1y0),
    .s(p[1]), .c(c1)
);


wire s_fa1, c2, c3;
fa FA1 (
    .a(x1y1), .b(x2y0), .cin(c1),
    .s(s_fa1), .cout(c2)
);
ha HA2 (
    .a(s_fa1), .b(x0y2),
    .s(p[2]), .c(c3)
);


wire s_fa2, c4;
fa FA2 (
    .a(1'b1), .b(x2y1), .cin(c2),
    .s(s_fa2), .cout(c4)
);

wire s_fa3, c5;
fa FA3 (
    .a(s_fa2), .b(x1y2), .cin(c3),
    .s(p[3]), .cout(c5)
);



assign p[4] = (x2 ^ y2) & (x[1] | x[0]) & (y[1] | y[0]);



endmodule

// =============================================================
// Half Adder
// =============================================================
module ha (
    input  a, b,
    output s, c
);
    assign s = a ^ b;
    assign c = a & b;
endmodule

// =============================================================
// Full Adder (built from two HAs)
// =============================================================
module fa (
    input  a, b, cin,
    output s, cout
);
    wire s1, c1, c2;
    ha ha1 (.a(a),  .b(b),   .s(s1), .c(c1));
    ha ha2 (.a(s1), .b(cin), .s(s),  .c(c2));
    assign cout = c1 | c2;
endmodule