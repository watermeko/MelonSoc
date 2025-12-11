MEMORY {
   PROGROM (RX) : ORIGIN = 0x00000, LENGTH = 0x10000  /* 64kB ROM */
   DATARAM (RW) : ORIGIN = 0x10000, LENGTH = 0x10000  /* 64kB RAM */   
}

ENTRY(_start)

SECTIONS {

    .text : {
        . = ALIGN(4);
	build/program.o (.text)
        *(.text*)
    } > PROGROM

    .rodata : {
        . = ALIGN(4);
        *(.rodata*)
        *(.srodata*)
    } > DATARAM

    .data : {
	. = ALIGN(4);
        *(.data*)
        *(.sdata*)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.init_array*)
        *(.gcc_except_table*)
    } > DATARAM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > DATARAM
}

PROVIDE(__global_pointer$ = ORIGIN(DATARAM) + 0x800);
