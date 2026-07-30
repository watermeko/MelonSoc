MEMORY {
   /* Keep the application below the LCD framebuffer. */
   DDR_APP (RWX) : ORIGIN = 0x80000000, LENGTH = 0x00100000
}

ENTRY(_start)

STACK_SIZE = 0x1000;

SECTIONS {
    .text : {
        . = ALIGN(4);
        build/ddr_app/start.o (.text)
        *(.text*)
        . = ALIGN(4);
    } > DDR_APP

    .ramdata : {
        . = ALIGN(4);
        __ramdata_start = .;
        *(.rodata*)
        *(.srodata*)
        *(.data*)
        *(.sdata*)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.init_array*)
        *(.gcc_except_table*)
        . = ALIGN(4);
        __ramdata_end = .;
    } > DDR_APP

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss*)
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DDR_APP
}

__stack_bottom = ALIGN(__bss_end, 16);
__stack_top = __stack_bottom + STACK_SIZE;

PROVIDE(__global_pointer$ = __ramdata_start + 0x800);
ASSERT(__stack_top <= ORIGIN(DDR_APP) + LENGTH(DDR_APP),
       "DDR application overlaps LCD framebuffer")
