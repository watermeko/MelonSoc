`timescale 1ns/1ps

module uart_tx_tb;
    localparam integer CLK_FREQ = 9_000_000;
    localparam integer UART_BAUD = 115_200;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [7:0] tx_data = 8'd0;
    logic tx_valid = 1'b0;
    logic tx_ready;
    logic txd;
    logic [7:0] rx_data;
    logic rx_valid;
    logic rx_ready = 1'b0;
    logic rx_overrun;
    logic rx_frame_err;

    always #5 clk = ~clk;

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .UART_BAUD(UART_BAUD)
    ) u_tx (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .txd(txd)
    );

    uart_rx_simple #(
        .CLK_FREQ(CLK_FREQ),
        .UART_BAUD(UART_BAUD)
    ) u_rx (
        .clk(clk),
        .rst_n(rst_n),
        .rxd(txd),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),
        .clear_overrun(1'b0),
        .clear_frame_err(1'b0),
        .rx_overrun(rx_overrun),
        .rx_frame_err(rx_frame_err)
    );

    task automatic send_and_check(input logic [7:0] value);
        begin
            while (rx_valid)
                @(posedge clk);
            while (!tx_ready)
                @(posedge clk);

            @(negedge clk);
            tx_data  = value;
            tx_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            tx_valid = 1'b0;

            while (!rx_valid)
                @(posedge clk);
            #1;
            if (rx_frame_err || rx_data !== value)
                $fatal(1, "UART mismatch: sent=%02x got=%02x frame_err=%0d",
                       value, rx_data, rx_frame_err);

            @(negedge clk);
            rx_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rx_ready = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        send_and_check(8'h42);
        send_and_check(8'h50);
        send_and_check(8'h55);
        send_and_check(8'haa);

        $display("UART TX loopback PASSED");
        $finish;
    end

    initial begin
        repeat (10000) @(posedge clk);
        $fatal(1, "UART TX loopback timeout");
    end
endmodule
