# bin_to_verilog_hex.py
import sys
import struct

def convert_bin_to_verilog_hex(binary_filename):
    """
    将原始二进制文件（包含RISC-V机器码）转换为
    与Verilog $readmemh兼容的HEX文件。
    输出HEX文件中的每一行将是一个32位的十六进制指令，
    假设二进制文件中的字节序为小端序。
    """
    try:
        with open(binary_filename, 'rb') as f_bin:
            count = 0
            while True:
                # 一次读取4个字节 (32位)
                word_bytes = f_bin.read(4)

                if not word_bytes:
                    break # 到达文件末尾

                # 如果读取的字节数少于4 (通常在文件末尾且文件大小不是4的倍数时发生)
                if len(word_bytes) < 4:
                    # 用零填充以构成一个完整的字
                    # $readmemh 通常期望完整的字
                    word_bytes = word_bytes.ljust(4, b'\x00')
                    # 或者，您可以选择报错：
                    # print(f"警告: 二进制文件大小不是4字节的倍数。最后 {len(word_bytes)} 字节将被填充。", file=sys.stderr)

                # 将4个字节解包为一个无符号小端整数
                # '<I' 表示小端序 (little-endian) 无符号整数 (unsigned int)
                word_int = struct.unpack('<I', word_bytes)[0]

                # 以8位大写十六进制格式打印，不足则前面补零
                print(f"{word_int:08X}")
                count += 1
        # print(f"总共转换了 {count} 个32位字。", file=sys.stderr)

    except FileNotFoundError:
        print(f"错误: 二进制文件 '{binary_filename}' 未找到。", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"发生错误: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python bin_to_verilog_hex.py <输入二进制文件名>", file=sys.stderr)
        sys.exit(1)
    
    input_file = sys.argv[1]
    convert_bin_to_verilog_hex(input_file)
