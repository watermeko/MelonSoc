OUTPUT_ARCH(riscv)
ENTRY(_start) /* 与 .s 文件中的标签对应 */

MEMORY {
  /* 定义您的指令存储器区域，起始地址和大小应与Verilog中的MEM对应 */
  /* 将其标记为 rwx，因为 .data, .bss 和堆栈将位于此处 */
  IMEM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x5ff0 /* 确保 LENGTH 足够大 */
}

SECTIONS {
  .text : {
    *(.text.init) /* 确保 .text.init 段在最前面 */
    *(.text)
    *(.text.*)
  } > IMEM

  .rodata : {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata.*)
  } > IMEM

  /* 已初始化数据段 */
  .data : {
    . = ALIGN(4);
    _sdata = .; /* 已初始化数据的开始 */
    *(.data)
    *(.data.*)
    _edata = .; /* 已初始化数据的结束 */
  } > IMEM

  /* 未初始化数据段 */
  /* 这部分内存只是被保留，不会自动清零 (除非您的启动代码处理它) */
  .bss : {
    . = ALIGN(4);
    _sbss = .; /* BSS 段的开始 */
    *(.bss)
    *(.bss.*)
    *(COMMON)
    _ebss = .; /* BSS 段的结束 */
  } > IMEM

  /* 定义一个符号，表示 IMEM 的顶部，可用于堆栈指针初始化 */
  /* 您的 program.s 中的堆栈指针初始化应使用此符号或 IMEM 的结束地址 */
  /* 如果 program.s 中 sp 初始化为 0x1800，并且 LENGTH 也是 0x1800，则它们是对齐的 */
  PROVIDE(_stack_top = ORIGIN(IMEM) + LENGTH(IMEM));

  /* 确保所有内容都已放置，并且不会超出 IMEM 范围 */
  /* 如果链接时出现空间不足的错误，您需要增加 IMEM 的 LENGTH */
}