OUTPUT_ARCH(riscv)
ENTRY(_start) /* 与 .s 文件中的标签对应 */

MEMORY {
  /* 指令存储器：64KB 只读 */
  PROGROM (rx) : ORIGIN = 0x00000000, LENGTH = 0x10000  /* 64KB */

  /* 数据存储器：64KB 读写 */
  DATARAM (rw) : ORIGIN = 0x00010000, LENGTH = 0x10000  /* 64KB */
}

SECTIONS {
  /* 代码段 → PROGROM */
  .text : {
    *(.text.init)    /* 启动代码必须在最前面 */
    *(.text)
    *(.text.*)
    . = ALIGN(4);
  } > PROGROM

  /* 只读数据段 → DATARAM（因为需要通过 LOAD 指令访问）*/
  .rodata : {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata.*)
    . = ALIGN(4);
  } > DATARAM

  /* 已初始化数据段 → DATARAM */
  .data : {
    . = ALIGN(4);
    _sdata = .;                /* 数据段在 DATARAM 中的起始地址 */
    *(.data)
    *(.data.*)
    . = ALIGN(4);
    _edata = .;
  } > DATARAM

  /* 未初始化数据段 → DATARAM */
  .bss : {
    . = ALIGN(4);
    _sbss = .;
    *(.bss)
    *(.bss.*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } > DATARAM

  /* 栈顶地址（DATARAM 顶端） */
  PROVIDE(_stack_top = ORIGIN(DATARAM) + LENGTH(DATARAM));  /* 0x20000 */
}
