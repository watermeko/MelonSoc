`ifndef MELONSOC_RVC_SV
`define MELONSOC_RVC_SV
package  rvc;
// ---------------------- RVC decompress helpers ----------------------
typedef struct packed {
  logic        illegal;
  logic [31:0] insn;
} rvc_exp_t;

function automatic logic [31:0] rv_enc_i(
  input logic [11:0] imm12,
  input logic [4:0]  rs1,
  input logic [2:0]  funct3,
  input logic [4:0]  rd,
  input logic [6:0]  opcode
);
  return {imm12, rs1, funct3, rd, opcode};
endfunction

function automatic logic [31:0] rv_enc_r(
  input logic [6:0] funct7,
  input logic [4:0] rs2,
  input logic [4:0] rs1,
  input logic [2:0] funct3,
  input logic [4:0] rd,
  input logic [6:0] opcode
);
  return {funct7, rs2, rs1, funct3, rd, opcode};
endfunction

function automatic logic [31:0] rv_enc_s(
  input logic [11:0] imm12,
  input logic [4:0]  rs2,
  input logic [4:0]  rs1,
  input logic [2:0]  funct3,
  input logic [6:0]  opcode
);
  return {imm12[11:5], rs2, rs1, funct3, imm12[4:0], opcode};
endfunction

function automatic logic [31:0] rv_enc_u(
  input logic [31:12] imm20,
  input logic [4:0]   rd,
  input logic [6:0]   opcode
);
  return {imm20, rd, opcode};
endfunction

function automatic logic [31:0] rv_enc_b(
  input logic [12:0] imm13,
  input logic [4:0]  rs2,
  input logic [4:0]  rs1,
  input logic [2:0]  funct3,
  input logic [6:0]  opcode
);
  return {imm13[12], imm13[10:5], rs2, rs1, funct3, imm13[4:1], imm13[11], opcode};
endfunction

function automatic logic [31:0] rv_enc_j(
  input logic [20:0] imm21,
  input logic [4:0]  rd,
  input logic [6:0]  opcode
);
  return {imm21[20], imm21[10:1], imm21[11], imm21[19:12], rd, opcode};
endfunction

function automatic rvc_exp_t rvc_expand(input logic [15:0] c);
  rvc_exp_t r;
  logic [1:0] op;
  logic [2:0] funct3;
  logic [4:0] rd, rs1, rs2;
  logic [4:0] rdp, rs1p, rs2p;
  logic [11:0] imm12;
  logic signed [31:0] simm;
  logic [12:0] bimm13;
  logic [20:0] jimm21;

  op     = c[1:0];
  funct3 = c[15:13];

  rd   = c[11:7];
  rs1  = c[11:7];
  rs2  = c[6:2];
  rdp  = {2'b01, c[4:2]};   // x8-x15
  rs1p = {2'b01, c[9:7]};   // x8-x15
  rs2p = {2'b01, c[4:2]};   // x8-x15

  r.illegal = 1'b0;
  r.insn    = 32'h0000_0013; // NOP

  unique case (op)
    2'b00: begin
      unique case (funct3)
        3'b000: begin // C.ADDI4SPN
          imm12 = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00};
          if (imm12 == 12'b0) begin
            r.illegal = 1'b1;
            r.insn    = 32'h0000_0013;
          end else begin
            r.insn = rv_enc_i(imm12, 5'd2, 3'b000, rdp, 7'b0010011); // addi rd', x2, imm
          end
        end
        3'b010: begin // C.LW
          imm12 = {5'b0, c[5], c[12:10], c[6], 2'b00};
          r.insn = rv_enc_i(imm12, rs1p, 3'b010, rdp, 7'b0000011);
        end
        3'b110: begin // C.SW
          imm12 = {5'b0, c[5], c[12:10], c[6], 2'b00};
          r.insn = rv_enc_s(imm12, rs2p, rs1p, 3'b010, 7'b0100011);
        end
        default: begin
          r.illegal = 1'b1;
        end
      endcase
    end

    2'b01: begin
      unique case (funct3)
        3'b000: begin // C.ADDI / C.NOP
          imm12 = {{7{c[12]}}, c[6:2]};
          r.insn = rv_enc_i(imm12, rs1, 3'b000, rd, 7'b0010011);
        end
        3'b001: begin // C.JAL (RV32)
          logic [11:0] cj_imm;
          cj_imm = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
          simm  = $signed({{20{cj_imm[11]}}, cj_imm});
          jimm21 = simm[20:0];
          r.insn = rv_enc_j(jimm21, 5'd1, 7'b1101111);
        end
        3'b010: begin // C.LI
          imm12 = {{7{c[12]}}, c[6:2]};
          r.insn = rv_enc_i(imm12, 5'd0, 3'b000, rd, 7'b0010011);
        end
        3'b011: begin
          if (rd == 5'd2) begin // C.ADDI16SP
            imm12 = {{3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000};
            if (imm12 == 12'b0) begin
              r.illegal = 1'b1;
            end else begin
              r.insn = rv_enc_i(imm12, 5'd2, 3'b000, 5'd2, 7'b0010011);
            end
          end else if (rd != 5'd0) begin // C.LUI
            logic [31:12] uimm;
            uimm = {{15{c[12]}}, c[6:2]};
            if (uimm[17:12] == 6'b0) begin
              r.illegal = 1'b1;
            end else begin
              r.insn = rv_enc_u(uimm, rd, 7'b0110111);
            end
          end else begin
            r.illegal = 1'b1;
          end
        end
        3'b100: begin
          unique case (c[11:10])
            2'b00: begin // C.SRLI
              if (c[12]) r.illegal = 1'b1; // RV32 shamt[5] must be 0
              imm12 = {7'b0000000, c[6:2]}; // funct7 + shamt
              r.insn = rv_enc_i(imm12, rs1p, 3'b101, rs1p, 7'b0010011);
            end
            2'b01: begin // C.SRAI
              if (c[12]) r.illegal = 1'b1; // RV32 shamt[5] must be 0
              imm12 = {7'b0100000, c[6:2]}; // funct7 + shamt
              r.insn = rv_enc_i(imm12, rs1p, 3'b101, rs1p, 7'b0010011);
            end
            2'b10: begin // C.ANDI
              imm12 = {{7{c[12]}}, c[6:2]};
              r.insn = rv_enc_i(imm12, rs1p, 3'b111, rs1p, 7'b0010011);
            end
            2'b11: begin
              if (c[12]) begin
                r.illegal = 1'b1;
              end else begin
                unique case (c[6:5])
                  2'b00: r.insn = rv_enc_r(7'b0100000, rs2p, rs1p, 3'b000, rs1p, 7'b0110011); // SUB
                  2'b01: r.insn = rv_enc_r(7'b0000000, rs2p, rs1p, 3'b100, rs1p, 7'b0110011); // XOR
                  2'b10: r.insn = rv_enc_r(7'b0000000, rs2p, rs1p, 3'b110, rs1p, 7'b0110011); // OR
                  2'b11: r.insn = rv_enc_r(7'b0000000, rs2p, rs1p, 3'b111, rs1p, 7'b0110011); // AND
                  default: begin
                    r.illegal = 1'b1;
                  end
                endcase
              end
            end
            default: begin
              r.illegal = 1'b1;
            end
          endcase
        end
        3'b101: begin // C.J
          logic [11:0] cj_imm;
          cj_imm = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
          simm  = $signed({{20{cj_imm[11]}}, cj_imm});
          jimm21 = simm[20:0];
          r.insn = rv_enc_j(jimm21, 5'd0, 7'b1101111);
        end
        3'b110: begin // C.BEQZ
          logic [8:0] cb_imm;
          cb_imm = {c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
          simm   = $signed({{23{cb_imm[8]}}, cb_imm});
          bimm13 = simm[12:0];
          r.insn = rv_enc_b(bimm13, 5'd0, rs1p, 3'b000, 7'b1100011);
        end
        3'b111: begin // C.BNEZ
          logic [8:0] cb_imm;
          cb_imm = {c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
          simm   = $signed({{23{cb_imm[8]}}, cb_imm});
          bimm13 = simm[12:0];
          r.insn = rv_enc_b(bimm13, 5'd0, rs1p, 3'b001, 7'b1100011);
        end
        default: begin
          r.illegal = 1'b1;
        end
      endcase
    end

    2'b10: begin
      unique case (funct3)
        3'b000: begin // C.SLLI
          if (c[12]) r.illegal = 1'b1; // RV32 shamt[5] must be 0
          imm12 = {7'b0000000, c[6:2]};
          r.insn = rv_enc_i(imm12, rs1, 3'b001, rd, 7'b0010011);
        end
        3'b010: begin // C.LWSP
          if (rd == 5'd0) begin
            r.illegal = 1'b1;
          end else begin
            imm12 = {4'b0, c[3:2], c[12], c[6:4], 2'b00};
            r.insn = rv_enc_i(imm12, 5'd2, 3'b010, rd, 7'b0000011);
          end
        end
        3'b100: begin
          if (!c[12]) begin
            if (rs2 == 5'd0) begin // C.JR
              if (rs1 == 5'd0) begin
                r.illegal = 1'b1;
              end else begin
                r.insn = rv_enc_i(12'b0, rs1, 3'b000, 5'd0, 7'b1100111);
              end
            end else begin // C.MV
              r.insn = rv_enc_r(7'b0000000, rs2, 5'd0, 3'b000, rd, 7'b0110011);
            end
          end else begin
            if (rs2 == 5'd0) begin
              if (rd == 5'd0) begin // C.EBREAK
                r.insn = 32'h0010_0073;
              end else begin // C.JALR
                if (rs1 == 5'd0) begin
                  r.illegal = 1'b1;
                end else begin
                  r.insn = rv_enc_i(12'b0, rs1, 3'b000, 5'd1, 7'b1100111);
                end
              end
            end else begin // C.ADD
              r.insn = rv_enc_r(7'b0000000, rs2, rs1, 3'b000, rd, 7'b0110011);
            end
          end
        end
        3'b110: begin // C.SWSP
          imm12 = {4'b0, c[8:7], c[12:9], 2'b00};
          r.insn = rv_enc_s(imm12, rs2, 5'd2, 3'b010, 7'b0100011);
        end
        default: begin
          r.illegal = 1'b1;
        end
      endcase
    end
    default: begin
      r.illegal = 1'b1;
    end
  endcase

  if (r.illegal) begin
    r.insn = 32'h0000_0013;
  end
  return r;
endfunction
endpackage;
`endif