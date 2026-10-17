`timescale 1ns/1ps

module psmac_top_tb;

    reg        clk, rst, psmac_en;
    reg  [1:0] mode;
    reg        sx, sy;
    reg  [7:0] vec_len;
    reg        we_w, we_x;
    reg  [7:0] w_addr, w_data;
    reg  [7:0] x_addr, x_data;

    wire [31:0] result;
    wire        out_valid;

    integer errors, tests, i;

    psmac_top DUT(
        .clk(clk), .rst(rst),
        .psmac_en(psmac_en),
        .mode(mode), .sx(sx), .sy(sy),
        .vec_len(vec_len),
        .we_w(we_w), .w_addr(w_addr), .w_data(w_data),
        .we_x(we_x), .x_addr(x_addr), .x_data(x_data),
        .result(result), .out_valid(out_valid)
    );

    always #5 clk = ~clk;

    task tick;
        begin @(posedge clk); #1; end
    endtask

    task check_result;
        input signed [31:0] exp;
        input [31:0] tnum;
        begin
            tests = tests + 1;
            if ($signed(result) !== exp) begin
                $display("  FAIL test %0d: result got=%0d exp=%0d",
                    tnum, $signed(result), exp);
                errors = errors + 1;
            end
        end
    endtask

    task check_sig;
        input [63:0] got;
        input [63:0] exp;
        input [127:0] name;
        input [31:0] tnum;
        begin
            tests = tests + 1;
            if (got !== exp) begin
                $display("  FAIL test %0d: %s got=%0d exp=%0d",
                    tnum, name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    task write_pair;
        input [7:0] addr_in;
        input [7:0] xval, wval;
        begin
            we_x=1; x_addr=addr_in; x_data=xval;
            we_w=1; w_addr=addr_in; w_data=wval;
            tick;
            we_x=0; we_w=0;
        end
    endtask

    task run_and_wait;
        input [7:0] vl;
        input [1:0] md;
        integer timeout;
        begin
            vec_len  = vl;
            mode     = md;
            tick;            // settling tick for memory writes
            psmac_en = 1;
            tick;
            psmac_en = 0;
            // wait for out_valid to go low (new op started, old result cleared)
            timeout = 0;
            while (out_valid && timeout < 20) begin
                tick;
                timeout = timeout + 1;
            end
            // now wait for out_valid to go high (result ready)
            timeout = 0;
            while (!out_valid && timeout < 300) begin
                tick;
                timeout = timeout + 1;
            end
            // result is stable when out_valid goes high
        end
    endtask

    initial begin
        $dumpfile("psmac_top_tb.vcd");
        $dumpvars(0, psmac_top_tb);

        clk=0; rst=1; psmac_en=0;
        mode=2'b10; sx=1; sy=1;
        vec_len=8'd4;
        we_w=0; we_x=0;
        w_addr=0; w_data=0;
        x_addr=0; x_data=0;
        errors=0; tests=0;

        $display("==============================================");
        $display("psmac_top Integration Testbench");
        $display("==============================================");

        tick; tick;
        rst = 0;
        tick;

        // TEST 1: Reset
        $display("\n--- Test 1: Reset behavior ---");
        check_sig(out_valid, 0, "out_valid", 1);
        check_sig(result,    0, "result",    1);
        $display("  PASS: reset state clean");

        // TEST 2: INT8 vec_len=1
        $display("\n--- Test 2: INT8 vec_len=1 ---");
        write_pair(0, 8'd3, 8'd4);
        run_and_wait(8'd1, 2'b10);
        check_result(32'd12, 2);
        $display("  PASS: INT8 3*4=12");

        // TEST 3: INT8 vec_len=4
        $display("\n--- Test 3: INT8 vec_len=4 ---");
        write_pair(0, 8'd1, 8'd5);
        write_pair(1, 8'd2, 8'd6);
        write_pair(2, 8'd3, 8'd7);
        write_pair(3, 8'd4, 8'd8);
        run_and_wait(8'd4, 2'b10);
        check_result(32'd70, 3);
        $display("  PASS: INT8 dot([1,2,3,4],[5,6,7,8])=70");

        // TEST 4: INT8 vec_len=8 negative weights
        $display("\n--- Test 4: INT8 vec_len=8 negative weights ---");
        write_pair(0, 8'd1,  8'd1);
        write_pair(1, 8'd2,  8'hFF);
        write_pair(2, 8'd3,  8'd1);
        write_pair(3, 8'd4,  8'hFF);
        write_pair(4, 8'd5,  8'd1);
        write_pair(5, 8'd6,  8'hFF);
        write_pair(6, 8'd7,  8'd1);
        write_pair(7, 8'd8,  8'hFF);
        run_and_wait(8'd8, 2'b10);
        check_result(-32'd4, 4);
        $display("  PASS: INT8 alternating signs = -4");

        // TEST 5: INT8 all-zero
        $display("\n--- Test 5: INT8 all-zero ---");
        for (i=0; i<4; i=i+1) write_pair(i[7:0], 8'd0, 8'd0);
        run_and_wait(8'd4, 2'b10);
        check_result(32'd0, 5);
        $display("  PASS: INT8 all-zero = 0");

        // TEST 6: INT8 max positive
        $display("\n--- Test 6: INT8 max positive ---");
        write_pair(0, 8'd127, 8'd127);
        write_pair(1, 8'd127, 8'd127);
        run_and_wait(8'd2, 2'b10);
        check_result(32'd32258, 6);
        $display("  PASS: INT8 127*127*2=32258");

        // TEST 7: INT4 vec_len=4
        $display("\n--- Test 7: INT4 vec_len=4 ---");
        write_pair(0, 8'h21, 8'h21);
        write_pair(1, 8'h43, 8'h43);
        run_and_wait(8'd4, 2'b01);
        check_result(32'd30, 7);
        $display("  PASS: INT4 dot([1,2,3,4],[1,2,3,4])=30");

        // TEST 8: INT4 vec_len=8
        $display("\n--- Test 8: INT4 vec_len=8 ---");
        write_pair(0, 8'h11, 8'h22);
        write_pair(1, 8'h11, 8'h22);
        write_pair(2, 8'h11, 8'h22);
        write_pair(3, 8'h11, 8'h22);
        run_and_wait(8'd8, 2'b01);
        check_result(32'd16, 8);
        $display("  PASS: INT4 dot([1x8],[2x8])=16");

        // TEST 9: INT2 vec_len=16
        $display("\n--- Test 9: INT2 vec_len=16 ---");
        write_pair(0, 8'h55, 8'h55);
        write_pair(1, 8'h55, 8'h55);
        write_pair(2, 8'h55, 8'h55);
        write_pair(3, 8'h55, 8'h55);
        run_and_wait(8'd16, 2'b00);
        check_result(32'd16, 9);
        $display("  PASS: INT2 dot([1x16],[1x16])=16");

        // TEST 10: out_valid persists
        $display("\n--- Test 10: out_valid persists ---");
        check_sig(out_valid, 1, "out_valid", 10);
        tick; check_sig(out_valid, 1, "out_valid", 10);
        tick; check_sig(out_valid, 1, "out_valid", 10);
        $display("  PASS: out_valid stays high across 3 idle cycles");

        // TEST 11: Restart clears out_valid
        $display("\n--- Test 11: Restart clears out_valid ---");
        write_pair(0, 8'd2, 8'd3);
        run_and_wait(8'd1, 2'b10);
        check_result(32'd6, 11);
        $display("  PASS: restart result=6");

        // TEST 12: Back-to-back
        $display("\n--- Test 12: Back-to-back ---");
        write_pair(0, 8'd3, 8'd3);
        write_pair(1, 8'd4, 8'd4);
        run_and_wait(8'd2, 2'b10);
        check_result(32'd25, 12);
        $display("  PASS: first back-to-back=25");

        write_pair(0, 8'd1, 8'd2);
        write_pair(1, 8'd2, 8'd3);
        run_and_wait(8'd2, 2'b10);
        check_result(32'd8, 12);
        $display("  PASS: second back-to-back=8");

        // TEST 13: rst mid-operation
        $display("\n--- Test 13: Reset mid-operation ---");
        write_pair(0, 8'd10, 8'd10);
        write_pair(1, 8'd10, 8'd10);
        vec_len=8'd8; mode=2'b10;
        tick;
        psmac_en=1; tick; psmac_en=0;
        tick; tick;
        rst=1; tick; tick;
        check_sig(out_valid, 0, "out_valid_after_rst", 13);
        check_sig(result,    0, "result_after_rst",    13);
        rst=0;
        $display("  PASS: reset mid-operation clears state");

        // TEST 14: INT8 negative result
        $display("\n--- Test 14: INT8 negative result ---");
        write_pair(0, 8'd5, 8'hFD);
        run_and_wait(8'd1, 2'b10);
        check_result(-32'd15, 14);
        $display("  PASS: INT8 5*(-3)=-15");

        // TEST 15: INT4 mixed signs vec_len=4
        $display("\n--- Test 15: INT4 mixed signs vec_len=4 ---");
        write_pair(0, 8'hE3, 8'h42);
        write_pair(1, 8'h11, 8'h11);
        run_and_wait(8'd4, 2'b01);
        check_result(32'd0, 15);
        $display("  PASS: INT4 mixed signs = 0");

        $display("\n==============================================");
        if (errors == 0)
            $display("ALL %0d TESTS PASSED", tests);
        else
            $display("FAILED: %0d / %0d tests", errors, tests);
        $display("==============================================");

        $finish;
    end

endmodule
