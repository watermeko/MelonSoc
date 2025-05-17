OUTPUT_ARCH(riscv)
ENTRY(_start) /* 与 .s 文件中的标签对应 */

MEMORY {
  /* 定义您的指令存储器区域，起始地址和大小应与Verilog中的MEM对应 */
  /* 例如，如果MEM是1KB (256 words * 4 bytes/word) */
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 1K
}

SECTIONS {
  .text : {
    *(.text.init) /* 确保 .text.init 段在最前面 */
    *(.text)
    *(.text.*)
  } > IMEM
}