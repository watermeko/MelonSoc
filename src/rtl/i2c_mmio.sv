`include "lib/soc_pkg.sv"
`include "lib/bus_if.sv"

module i2c_mmio #(
  parameter int unsigned CLK_FREQ_HZ = soc_pkg::CLK_FREQ_HZ,
  parameter int unsigned I2C_DEFAULT_HZ = 100_000
) (
  input  logic clk,
  input  logic rst_n,
  simple_bus_if.slave bus,

  output logic i2c_scl_drive_low,
  output logic i2c_sda_drive_low,
  input  logic i2c_sda_in
);
  import soc_pkg::*;

  // ---------------- Register map ----------------
  // TXRX   @ IO_I2C_TXRX_ADDR   [7:0]  write: TX byte, read: RX byte
  // CMD    @ IO_I2C_CMD_ADDR:
  //   [0] START, [1] STOP, [2] WRITE, [3] READ, [4] ACK (for READ: 1=ACK, 0=NACK)
  // STATUS @ IO_I2C_STATUS_ADDR:
  //   [0] BUSY, [1] DONE (sticky), [2] NACK (sticky for last WRITE)
  // DIV    @ IO_I2C_DIV_ADDR    half-period divider in clk cycles (>=1)

  logic sel_txrx, sel_cmd, sel_status, sel_div;
  always_comb begin
    sel_txrx   = (align_word(bus.addr) == IO_I2C_TXRX_ADDR);
    sel_cmd    = (align_word(bus.addr) == IO_I2C_CMD_ADDR);
    sel_status = (align_word(bus.addr) == IO_I2C_STATUS_ADDR);
    sel_div    = (align_word(bus.addr) == IO_I2C_DIV_ADDR);
  end

  // ---------------- MMIO registers ----------------
  logic [7:0]  tx_reg;
  logic [7:0]  rx_reg;
  logic [15:0] div_reg;

  logic cmd_start, cmd_stop, cmd_write, cmd_read, cmd_ack;

  logic busy;
  logic done;
  logic nack;

  localparam int unsigned DEFAULT_DIV =
      (CLK_FREQ_HZ / (2 * I2C_DEFAULT_HZ)) > 0 ? (CLK_FREQ_HZ / (2 * I2C_DEFAULT_HZ)) : 1;

  // Divider effective value (avoid zero).
  logic [15:0] div_eff;
  always_comb begin
    div_eff = (div_reg == 16'd0) ? 16'd1 : div_reg;
  end

  // ---------------- I2C engine ----------------
  typedef enum logic [4:0] {
    ST_IDLE              = 5'd0,
    ST_START0            = 5'd1,
    ST_START1            = 5'd2,
    ST_START2            = 5'd3,

    ST_WRITE_SETUP       = 5'd4,
    ST_WRITE_SCL_HIGH    = 5'd5,
    ST_WRITE_SCL_LOW     = 5'd6,
    ST_WRITE_ACK_SETUP   = 5'd7,
    ST_WRITE_ACK_HIGH    = 5'd8,
    ST_WRITE_ACK_LOW     = 5'd9,

    ST_READ_SETUP        = 5'd10,
    ST_READ_SCL_HIGH     = 5'd11,
    ST_READ_SCL_LOW      = 5'd12,
    ST_READ_ACK_SETUP    = 5'd13,
    ST_READ_ACK_HIGH     = 5'd14,
    ST_READ_ACK_LOW      = 5'd15,

    ST_STOP0             = 5'd16,
    ST_STOP1             = 5'd17,
    ST_STOP2             = 5'd18,
    ST_FINISH            = 5'd19
  } state_t;

  state_t state;
  logic [15:0] div_cnt;
  logic [7:0]  shift_reg;
  logic [2:0]  bit_idx;

  logic need_start, need_stop;
  logic op_write, op_read;

  logic tick;
  always_comb begin
    tick = (div_cnt == 16'd0);
  end

  // Command latch and registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_reg <= 8'h00;
      div_reg <= DEFAULT_DIV[15:0];
    end else begin
      if (bus.wen && sel_txrx && (|bus.wstrb)) begin
        tx_reg <= bus.wdata[7:0];
      end
      if (bus.wen && sel_div && (|bus.wstrb)) begin
        div_reg <= bus.wdata[15:0];
      end
    end
  end

  // Engine control + status
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      done <= 1'b0;
      nack <= 1'b0;

      cmd_start <= 1'b0;
      cmd_stop  <= 1'b0;
      cmd_write <= 1'b0;
      cmd_read  <= 1'b0;
      cmd_ack   <= 1'b0;

      need_start <= 1'b0;
      need_stop  <= 1'b0;
      op_write   <= 1'b0;
      op_read    <= 1'b0;

      state <= ST_IDLE;
      div_cnt <= 16'd0;
      shift_reg <= 8'h00;
      rx_reg <= 8'h00;
      bit_idx <= 3'd0;

      i2c_scl_drive_low <= 1'b0;
      i2c_sda_drive_low <= 1'b0;
    end else begin
      // Default divider countdown while active.
      if (busy) begin
        if (div_cnt != 16'd0) begin
          div_cnt <= div_cnt - 16'd1;
        end
      end

      // Start a new command when idle.
      if (bus.wen && sel_cmd && (|bus.wstrb) && !busy) begin
        cmd_start <= bus.wdata[0];
        cmd_stop  <= bus.wdata[1];
        cmd_write <= bus.wdata[2];
        cmd_read  <= bus.wdata[3];
        cmd_ack   <= bus.wdata[4];

        need_start <= bus.wdata[0];
        need_stop  <= bus.wdata[1];
        op_write   <= bus.wdata[2] & ~bus.wdata[3];
        op_read    <= bus.wdata[3];

        // Clear sticky flags on a new command.
        done <= 1'b0;
        nack <= 1'b0;

        busy <= 1'b1;
        state <= bus.wdata[0] ? ST_START0 :
                 (bus.wdata[2] ? ST_WRITE_SETUP :
                  bus.wdata[3] ? ST_READ_SETUP  :
                  bus.wdata[1] ? ST_STOP0       : ST_FINISH);

        // Prepare for operation.
        shift_reg <= tx_reg;
        bit_idx <= 3'd7;

        // Ensure bus released initially; start sequence will assert SDA.
        i2c_scl_drive_low <= 1'b0;
        i2c_sda_drive_low <= 1'b0;
        div_cnt <= div_eff;
      end

      // FSM
      if (busy && tick) begin
        unique case (state)
          ST_IDLE: begin
            // Should not happen while busy.
            state <= ST_FINISH;
            div_cnt <= div_eff;
          end

          // START condition:
          //  - ensure released high
          //  - pull SDA low while SCL high
          //  - pull SCL low
          ST_START0: begin
            i2c_scl_drive_low <= 1'b0; // release high
            i2c_sda_drive_low <= 1'b0; // release high
            state <= ST_START1;
            div_cnt <= div_eff;
          end
          ST_START1: begin
            i2c_scl_drive_low <= 1'b0; // keep SCL high
            i2c_sda_drive_low <= 1'b1; // SDA low
            state <= ST_START2;
            div_cnt <= div_eff;
          end
          ST_START2: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            i2c_sda_drive_low <= 1'b1; // keep SDA low
            state <= op_write ? ST_WRITE_SETUP :
                     op_read  ? ST_READ_SETUP  :
                     need_stop ? ST_STOP0      : ST_FINISH;
            div_cnt <= div_eff;
          end

          // WRITE byte
          ST_WRITE_SETUP: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            i2c_sda_drive_low <= ~shift_reg[bit_idx]; // drive low for 0, release for 1
            state <= ST_WRITE_SCL_HIGH;
            div_cnt <= div_eff;
          end
          ST_WRITE_SCL_HIGH: begin
            i2c_scl_drive_low <= 1'b0; // SCL high
            state <= ST_WRITE_SCL_LOW;
            div_cnt <= div_eff;
          end
          ST_WRITE_SCL_LOW: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            if (bit_idx == 3'd0) begin
              state <= ST_WRITE_ACK_SETUP;
            end else begin
              bit_idx <= bit_idx - 3'd1;
              state <= ST_WRITE_SETUP;
            end
            div_cnt <= div_eff;
          end
          ST_WRITE_ACK_SETUP: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            i2c_sda_drive_low <= 1'b0; // release SDA for ACK bit
            state <= ST_WRITE_ACK_HIGH;
            div_cnt <= div_eff;
          end
          ST_WRITE_ACK_HIGH: begin
            i2c_scl_drive_low <= 1'b0; // SCL high
            // Sample ACK during SCL high period: ACK=0, NACK=1.
            nack <= i2c_sda_in;
            state <= ST_WRITE_ACK_LOW;
            div_cnt <= div_eff;
          end
          ST_WRITE_ACK_LOW: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            state <= need_stop ? ST_STOP0 : ST_FINISH;
            div_cnt <= div_eff;
          end

          // READ byte
          ST_READ_SETUP: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            i2c_sda_drive_low <= 1'b0; // release SDA
            state <= ST_READ_SCL_HIGH;
            div_cnt <= div_eff;
          end
          ST_READ_SCL_HIGH: begin
            i2c_scl_drive_low <= 1'b0; // SCL high
            shift_reg[bit_idx] <= i2c_sda_in;
            state <= ST_READ_SCL_LOW;
            div_cnt <= div_eff;
          end
          ST_READ_SCL_LOW: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            if (bit_idx == 3'd0) begin
              state <= ST_READ_ACK_SETUP;
            end else begin
              bit_idx <= bit_idx - 3'd1;
              state <= ST_READ_SCL_HIGH;
            end
            div_cnt <= div_eff;
          end
          ST_READ_ACK_SETUP: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            // cmd_ack==1 => ACK (drive low), cmd_ack==0 => NACK (release)
            i2c_sda_drive_low <= cmd_ack;
            state <= ST_READ_ACK_HIGH;
            div_cnt <= div_eff;
          end
          ST_READ_ACK_HIGH: begin
            i2c_scl_drive_low <= 1'b0; // SCL high
            state <= ST_READ_ACK_LOW;
            div_cnt <= div_eff;
          end
          ST_READ_ACK_LOW: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            i2c_sda_drive_low <= 1'b0; // release SDA after ACK/NACK
            rx_reg <= shift_reg;
            state <= need_stop ? ST_STOP0 : ST_FINISH;
            div_cnt <= div_eff;
          end

          // STOP condition:
          //  - ensure SDA low with SCL low
          //  - release SCL high
          //  - release SDA high
          ST_STOP0: begin
            i2c_scl_drive_low <= 1'b1; // SCL low
            i2c_sda_drive_low <= 1'b1; // SDA low
            state <= ST_STOP1;
            div_cnt <= div_eff;
          end
          ST_STOP1: begin
            i2c_scl_drive_low <= 1'b0; // SCL high
            i2c_sda_drive_low <= 1'b1; // keep SDA low
            state <= ST_STOP2;
            div_cnt <= div_eff;
          end
          ST_STOP2: begin
            i2c_scl_drive_low <= 1'b0; // keep SCL high
            i2c_sda_drive_low <= 1'b0; // SDA high (release)
            state <= ST_FINISH;
            div_cnt <= div_eff;
          end

          ST_FINISH: begin
            i2c_scl_drive_low <= 1'b0;
            i2c_sda_drive_low <= 1'b0;
            busy <= 1'b0;
            done <= 1'b1;
            state <= ST_IDLE;
            div_cnt <= 16'd0;
          end

          default: begin
            state <= ST_FINISH;
            div_cnt <= div_eff;
          end
        endcase
      end
    end
  end

  // ---------------- MMIO readback ----------------
  logic [31:0] status_rdata;
  always_comb begin
    status_rdata = 32'b0;
    status_rdata[0] = busy;
    status_rdata[1] = done;
    status_rdata[2] = nack;
  end

  always_comb begin
    if (sel_txrx) begin
      bus.rdata = {24'b0, rx_reg};
    end else if (sel_status) begin
      bus.rdata = status_rdata;
    end else if (sel_div) begin
      bus.rdata = {16'b0, div_reg};
    end else begin
      bus.rdata = 32'b0;
    end
  end
endmodule
