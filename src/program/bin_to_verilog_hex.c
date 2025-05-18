#include <stdio.h>
#include <stdlib.h>
#include <stdint.h> // 用于 uint32_t
#include <string.h> // 用于 memset (如果需要)

void convert_bin_to_verilog_hex(const char *binary_filename) {
    FILE *f_bin = fopen(binary_filename, "rb");
    if (f_bin == NULL) {
        fprintf(stderr, "错误: 二进制文件 '%s' 未找到。\n", binary_filename);
        exit(1);
    }

    unsigned char byte_buffer[4];
    size_t bytes_read;
    // int count = 0; // 对应Python脚本中注释掉的计数器

    while (1) {
        // 一次读取4个字节
        bytes_read = fread(byte_buffer, 1, 4, f_bin);

        if (bytes_read == 0) {
            if (feof(f_bin)) {
                break; // 到达文件末尾
            } else {
                // fread 发生错误
                fprintf(stderr, "读取文件 '%s' 时发生错误。\n", binary_filename);
                fclose(f_bin);
                exit(1);
            }
        }

        // 如果读取的字节数少于4 (通常在文件末尾且文件大小不是4的倍数时发生)
        if (bytes_read < 4) {
            // 用零填充以构成一个完整的字
            for (size_t i = bytes_read; i < 4; ++i) {
                byte_buffer[i] = 0x00;
            }
        }

        // 将4个字节（小端序）解包为一个无符号32位整数
        uint32_t word_int = (uint32_t)byte_buffer[0] |
                            ((uint32_t)byte_buffer[1] << 8) |
                            ((uint32_t)byte_buffer[2] << 16) |
                            ((uint32_t)byte_buffer[3] << 24);

        // 以8位大写十六进制格式打印，不足则前面补零
        printf("%08X\n", word_int);
        // count++;
    }

    fclose(f_bin);
    // fprintf(stderr, "总共转换了 %d 个32位字。\n", count); // 对应Python脚本中注释掉的打印
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "用法: %s <输入二进制文件名>\n", argv[0]);
        return 1;
    }

    const char *input_file = argv[1];
    convert_bin_to_verilog_hex(input_file);

    return 0;
}