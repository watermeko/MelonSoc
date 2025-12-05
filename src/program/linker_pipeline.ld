OUTPUT_ARCH(riscv)
ENTRY(_start) 

MEMORY {
  PROGROM (rx) : ORIGIN = 0x00000000, LENGTH = 0x10000  /* 64KB */
  DATARAM (rw) : ORIGIN = 0x00010000, LENGTH = 0x10000  /* 64KB */
}

SECTIONS {
  .text : {
    *(.text.init)    
    *(.text)
    *(.text.*)
    . = ALIGN(4);
  } > PROGROM

  .rodata : {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata.*)
    . = ALIGN(4);
  } > DATARAM

  .data : {
    . = ALIGN(4);
    _sdata = .;                /* 数据段在 DATARAM 中的起始地址 */
    *(.data)
    *(.data.*)
    . = ALIGN(4);
    _edata = .;
  } > DATARAM

  .bss : {
    . = ALIGN(4);
    _sbss = .;
    *(.bss)
    *(.bss.*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
  } > DATARAM

  PROVIDE(__global_pointer$ = _sdata + 0x800);

  /* 栈顶地址（DATARAM 顶端） */
  PROVIDE(_stack_top = ORIGIN(DATARAM) + LENGTH(DATARAM));  /* 0x20000 */
}
