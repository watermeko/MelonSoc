#include "fatboot.h"
#include "boot_image.h"
#include "print.h"
#include "sdcard.h"

static uint16_t rd16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int looks_like_fat32_bpb(const uint8_t *p) {
    return rd16(&p[11]) == 512 &&
           p[13] != 0 &&
           rd16(&p[14]) != 0 &&
           p[16] != 0 &&
           rd32(&p[36]) != 0 &&
           rd32(&p[44]) >= 2;
}

static int name_match(const uint8_t *p) {
    return p[0] == 'B' && p[1] == 'O' && p[2] == 'O' && p[3] == 'T' &&
           p[4] == ' ' && p[5] == ' ' && p[6] == ' ' && p[7] == ' ' &&
           p[8] == 'B' && p[9] == 'I' && p[10] == 'N';
}

static void copy_payload(uint8_t **dst_io, const uint8_t *src, uint32_t count) {
    volatile uint32_t *dst_words = (volatile uint32_t *)(*dst_io);
    const uint32_t *src_words = (const uint32_t *)src;

    while (count >= 4u) {
        *dst_words++ = *src_words++;
        count -= 4u;
    }

    volatile uint8_t *dst_bytes = (volatile uint8_t *)dst_words;
    const uint8_t *src_bytes = (const uint8_t *)src_words;
    while (count--) {
        *dst_bytes++ = *src_bytes++;
    }
    *dst_io = (uint8_t *)dst_bytes;
}

int fatboot_load(uint32_t dst, uint32_t *size_out) {
    /*
     * The ROM shell has a small SRAM stack.  Keep the sector workspace in
     * static storage: the boot path is single-threaded, and this also avoids
     * placing a full sector immediately below the top of DATARAM.
     */
    static uint32_t sector_words[128];
    uint8_t *sector = (uint8_t *)sector_words;
    uint32_t part_lba = 0;
    if (sdcard_read_block(0, sector) != 0)
        return -1;
    if (!looks_like_fat32_bpb(sector) &&
        sector[510] == 0x55 && sector[511] == 0xAA &&
        sector[0x1BE + 4] != 0)
        part_lba = rd32(&sector[0x1BE + 8]);

    if (sdcard_read_block(part_lba, sector) != 0)
        return -1;

    uint16_t bytes_per_sec = rd16(&sector[11]);
    uint8_t sec_per_clus = sector[13];
    uint16_t reserved = rd16(&sector[14]);
    uint8_t fats = sector[16];
    uint32_t fat_size = rd32(&sector[36]);
    uint32_t root_cluster = rd32(&sector[44]);
    if (bytes_per_sec != 512) {
        printf("Bootloader: FAT BPB diag lba=%x b0=%x b11=%x b12=%x b13=%x bps=%x\n",
               (unsigned)part_lba, (unsigned)sector[0],
               (unsigned)sector[11], (unsigned)sector[12],
               (unsigned)sector[13], (unsigned)bytes_per_sec);
        return -2;
    }

    uint32_t fat_lba = part_lba + reserved;
    uint32_t data_lba = fat_lba + (uint32_t)fats * fat_size;
    uint32_t cluster = root_cluster;
    uint32_t file_cluster = 0;
    uint32_t file_size = 0;

    while (cluster < 0x0FFFFFF8u) {
        uint32_t first = data_lba + (cluster - 2u) * sec_per_clus;
        for (uint32_t s = 0; s < sec_per_clus; ++s) {
            if (sdcard_read_block(first + s, sector) != 0)
                return -1;
            for (int off = 0; off < 512; off += 32) {
                if (sector[off] == 0)
                    continue;
                if (sector[off] == 0xE5 || sector[off + 11] == 0x0F)
                    continue;
                if (name_match(&sector[off])) {
                    file_cluster = ((uint32_t)rd16(&sector[off + 20]) << 16) | rd16(&sector[off + 26]);
                    file_size = rd32(&sector[off + 28]);
                    cluster = 0x0FFFFFFFu;
                    break;
                }
            }
            if (file_cluster)
                break;
        }
        if (file_cluster)
            break;
        uint32_t fat_sector = fat_lba + (cluster * 4u) / 512u;
        uint32_t fat_off = (cluster * 4u) & 511u;
        if (sdcard_read_block(fat_sector, sector) != 0)
            return -1;
        cluster = rd32(&sector[fat_off]) & 0x0FFFFFFFu;
    }

    if (!file_cluster)
        return -3;

    if (file_size < BOOT_IMAGE_HEADER_SIZE)
        return -5;

    uint8_t header[BOOT_IMAGE_HEADER_SIZE];
    uint8_t *payload_out = (uint8_t *)dst;
    uint32_t file_off = 0;
    uint32_t text_size = 0;
    uint32_t data_size = 0;
    uint32_t remaining = file_size;
    cluster = file_cluster;
    while (remaining && cluster < 0x0FFFFFF8u) {
        uint32_t first = data_lba + (cluster - 2u) * sec_per_clus;
        for (uint32_t s = 0; s < sec_per_clus && remaining; ++s) {
            if (sdcard_read_block(first + s, sector) != 0)
                return -1;
            uint32_t n = remaining < 512u ? remaining : 512u;
            uint32_t payload_off = 0;

            if (file_off == 0u) {
                for (uint32_t i = 0; i < BOOT_IMAGE_HEADER_SIZE; ++i)
                    header[i] = sector[i];

                uint32_t payload_size;
                int image_rc = boot_image_parse_header(
                    header, dst, &text_size, &data_size, &payload_size);
                if (image_rc != BOOT_IMAGE_OK)
                    return -5;
                if (boot_image_validate_file_size(file_size, text_size,
                                                  data_size) != BOOT_IMAGE_OK)
                    return -6;
                (void)payload_size;
                payload_off = BOOT_IMAGE_HEADER_SIZE;
            }

            copy_payload(&payload_out, &sector[payload_off], n - payload_off);
            file_off += n;
            remaining -= n;
        }
        if (remaining) {
            uint32_t fat_sector = fat_lba + (cluster * 4u) / 512u;
            uint32_t fat_off = (cluster * 4u) & 511u;
            if (sdcard_read_block(fat_sector, sector) != 0)
                return -1;
            cluster = rd32(&sector[fat_off]) & 0x0FFFFFFFu;
        }
    }

    *size_out = text_size + data_size;
    return remaining == 0 ? 0 : -4;
}
