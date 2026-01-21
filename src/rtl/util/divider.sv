// 需要 32 个时钟周期完成一次除法
module divider (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,          
    input  logic        flush,          
    input  logic [31:0] dividend,      
    input  logic [31:0] divisor,      
    input  logic        is_signed,   
    input  logic        is_rem,     

    output logic        busy,      
    output logic        result_valid,
    output logic [31:0] quotient,   
    output logic [31:0] remainder  
);

    logic [31:0] div_dividend;
    logic [62:0] div_divisor;
    logic [31:0] div_quotient;
    logic [31:0] div_quotient_msk;
    logic        div_sign;
    logic        div_busy;
    logic [31:0] div_result_q;
    logic [31:0] div_result_r;
    logic        div_result_valid;

    wire div_step_do = (div_divisor <= {31'b0, div_dividend});

    assign busy         = div_busy;
    assign result_valid = div_result_valid;
    assign quotient     = div_result_q;
    assign remainder    = div_result_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_dividend     <= 32'b0;
            div_divisor      <= 63'b0;
            div_quotient     <= 32'b0;
            div_quotient_msk <= 32'b0;
            div_sign         <= 1'b0;
            div_busy         <= 1'b0;
            div_result_q     <= 32'b0;
            div_result_r     <= 32'b0;
            div_result_valid <= 1'b0;
        end
        else begin
            if (flush) begin
                div_busy         <= 1'b0;
                div_result_valid <= 1'b0;
            end
            else if (div_result_valid && !start) begin
                div_result_valid <= 1'b0;
            end

            if (!div_busy) begin
                if (start && !div_result_valid) begin
                    if (divisor == 32'b0) begin
                        div_result_q     <= 32'hFFFFFFFF;
                        div_result_r     <= dividend;
                        div_result_valid <= 1'b1;
                        div_busy         <= 1'b0;
                    end
                    else begin
                        div_quotient_msk <= 1 << 31;
                        div_busy         <= 1'b1;
                        div_dividend     <= (is_signed & dividend[31]) ? -$signed(dividend) : dividend;
                        div_divisor      <= {(is_signed & divisor[31]) ? -$signed(divisor) : divisor, 31'b0};
                        div_quotient     <= 32'b0;
                        div_sign         <= is_signed & (is_rem ? dividend[31] :
                                                         (dividend[31] != divisor[31]) & |divisor);
                    end
                end
            end
            else begin
                div_dividend     <= div_step_do ? div_dividend - div_divisor[31:0] : div_dividend;
                div_divisor      <= div_divisor >> 1;
                div_quotient     <= div_step_do ? div_quotient | div_quotient_msk : div_quotient;
                div_quotient_msk <= div_quotient_msk >> 1;

                if (div_quotient_msk[0]) begin
                    div_busy         <= 1'b0;
                    div_result_valid <= 1'b1;
                    div_result_q <= div_sign ?
                                 -(div_step_do ? (div_quotient | 32'd1) : div_quotient) :
                                 (div_step_do ? (div_quotient | 32'd1) : div_quotient);
                    div_result_r <= div_sign ?
                                 -(div_step_do ? (div_dividend - div_divisor[31:0]) : div_dividend) :
                                 (div_step_do ? (div_dividend - div_divisor[31:0]) : div_dividend);
                end
            end
        end
    end

endmodule
