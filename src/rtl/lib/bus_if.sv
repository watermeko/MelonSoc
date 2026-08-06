`ifndef MELONSOC_BUS_IF_SV
`define MELONSOC_BUS_IF_SV

        interface imem_if #(
                parameter int unsigned ADDR_W = 32,
                parameter int unsigned DATA_W = 32
            );
            logic [ADDR_W-1:0] addr;
            logic              ren;
            logic              flush;
            logic [DATA_W-1:0] rdata;
            logic              stall;

            modport master (output addr, ren, flush, input rdata, stall);
            modport slave  (input addr, ren, flush, output rdata, stall);
        endinterface

        interface wb_if #(
                parameter int unsigned ADDR_W = 32,
                parameter int unsigned DATA_W = 32,
                parameter int unsigned SEL_W = (DATA_W / 8)
            );
            logic [ADDR_W-1:0] adr;
            logic [DATA_W-1:0] dat_w;
            logic [DATA_W-1:0] dat_r;
            logic [SEL_W-1:0]  sel;
             logic              we;
             logic              cyc;
             logic              stb;
             logic              lock;
             logic              ack;
             logic              stall;

             modport master (output adr, dat_w, sel, we, cyc, stb, lock,
                             input dat_r, ack, stall);
             modport slave  (input adr, dat_w, sel, we, cyc, stb, lock,
                            output dat_r, ack, stall);
        endinterface

`endif
