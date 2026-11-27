#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define LIMIT (4 * 1024 * 1024)
#define PROVIDER_FLAG UINT64_C(45704091)

typedef struct {
    const unsigned char *pos;
    const unsigned char *end;
} Reader;

typedef struct {
    unsigned char *pos;
    unsigned char *end;
} Writer;

static bool skip(Reader *in, uint64_t length) {
    if (length > (size_t)(in->end - in->pos)) return false;
    in->pos += (size_t)length;
    return true;
}

static bool read_uint(Reader *in, uint64_t *value) {
    *value = 0;
    for (unsigned shift = 0; shift < 64; shift += 7) {
        if (in->pos == in->end) return false;
        unsigned byte = *in->pos++;
        if (shift == 63 && byte > 1) return false;
        *value |= (uint64_t)(byte & 127) << shift;
        if (byte < 128) return true;
    }
    return false;
}

static bool write_uint(Writer *out, uint64_t value) {
    do {
        if (out->pos == out->end) return false;
        *out->pos++ = (unsigned char)((value & 127) | (value > 127 ? 128 : 0));
        value >>= 7;
    } while (value);
    return true;
}

static bool copy_bytes(Writer *out, const unsigned char *begin, size_t length) {
    if (length > (size_t)(out->end - out->pos)) return false;
    memcpy(out->pos, begin, length);
    out->pos += length;
    return true;
}

static bool skip_field(Reader *in, unsigned kind) {
    uint64_t length;
    switch (kind) {
        case 0:
        case 1: return true;
        case 2: return read_uint(in, &length);
        case 3: return skip(in, 8);
        case 4:
        case 5: return read_uint(in, &length) && skip(in, length);
        default: return false;
    }
}

static bool write_flag(Writer *out, uint64_t *previous, uint64_t id, unsigned kind) {
    uint64_t delta = id - *previous;
    if (id <= *previous || delta > (UINT64_MAX >> 3)) return false;
    *previous = id;
    return write_uint(out, (delta << 3) | kind);
}

static bool transform_flags(Reader in, Writer *out, bool insert, int *original_state) {
    uint64_t count;
    if (!read_uint(&in, &count) || count > (size_t)(in.end - in.pos)) return false;
    if (!write_uint(out, count + (insert && *original_state == -1))) return false;
    uint64_t last_read = 0;
    uint64_t last_written = 0;
    bool inserted = false;

    for (uint64_t row = 0; row < count; row++) {
        uint64_t tag;
        if (!read_uint(&in, &tag)) return false;
        uint64_t delta = tag >> 3;
        unsigned kind = (unsigned)(tag & 7);
        const unsigned char *contents = in.pos;
        if (delta == 0) {
            uint64_t name_length;
            if (!read_uint(&in, &name_length) || !skip(&in, name_length) || !skip_field(&in, kind)) return false;
            if (!write_uint(out, kind) || !copy_bytes(out, contents, (size_t)(in.pos - contents))) return false;
            continue;
        }

        if (delta > UINT64_MAX - last_read) return false;
        last_read += delta;
        if (!skip_field(&in, kind)) return false;
        if (last_read == PROVIDER_FLAG) {
            if (kind > 1) return false;
            *original_state = (int)kind;
            if (insert) kind = 1;
        }
        if (insert && !inserted && *original_state == -1 && last_read > PROVIDER_FLAG) {
            if (!write_flag(out, &last_written, PROVIDER_FLAG, 1)) return false;
            inserted = true;
        }
        if (!write_flag(out, &last_written, last_read, kind) ||
            !copy_bytes(out, contents, (size_t)(in.pos - contents))) return false;
    }

    if (insert && !inserted && *original_state == -1 &&
        !write_flag(out, &last_written, PROVIDER_FLAG, 1)) return false;
    return in.pos == in.end;
}

static bool contains_nearby(Reader metadata) {
    const char name[] = "com.google.android.gms.nearby";
    size_t length = sizeof(name) - 1;
    while ((size_t)(metadata.end - metadata.pos) >= length) {
        if (memcmp(metadata.pos++, name, length) == 0) return true;
    }
    return false;
}

static voidpf allocate(voidpf opaque, uInt count, uInt size) {
    (void)opaque;
    return calloc(count, size);
}

static void release(voidpf opaque, voidpf address) {
    (void)opaque;
    free(address);
}

static bool inflate_flags(Reader body, unsigned char *buffer, size_t *length) {
    z_stream stream = {.zalloc = allocate, .zfree = release};
    stream.next_in = (unsigned char *)body.pos;
    stream.avail_in = (unsigned)(body.end - body.pos);
    stream.next_out = buffer;
    stream.avail_out = LIMIT;
    if (inflateInit2(&stream, -15) != Z_OK) return false;
    int status = inflate(&stream, Z_FINISH);
    bool valid = status == Z_STREAM_END && stream.avail_in == 0;
    *length = stream.total_out;
    inflateEnd(&stream);
    return valid;
}

static bool deflate_flags(Reader flags, unsigned char *buffer, size_t *length) {
    z_stream stream = {.zalloc = allocate, .zfree = release};
    stream.next_in = (unsigned char *)flags.pos;
    stream.avail_in = (unsigned)(flags.end - flags.pos);
    stream.next_out = buffer;
    stream.avail_out = LIMIT;
    if (deflateInit2(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) return false;
    int status = deflate(&stream, Z_FINISH);
    *length = stream.total_out;
    deflateEnd(&stream);
    return status == Z_STREAM_END;
}

static bool write_result(const char *path, const unsigned char *header, size_t header_length,
                         const unsigned char *body, size_t body_length) {
    FILE *output = fopen(path, "wbx");
    if (!output) return false;
    bool success = fwrite(header, 1, header_length, output) == header_length &&
                   (body_length == 0 || fwrite(body, 1, body_length, output) == body_length);
    if (fclose(output) != 0) success = false;
    if (!success) remove(path);
    return success;
}

static bool process_snapshot(const char *input, const char *output) {
    unsigned char *memory = malloc(4 * LIMIT);
    if (!memory) return false;
    unsigned char *file = memory;
    unsigned char *raw = memory + LIMIT;
    unsigned char *written = memory + 2 * LIMIT;
    unsigned char *compressed = memory + 3 * LIMIT;
    bool success = false;

    FILE *source = fopen(input, "rb");
    if (!source) goto done;
    size_t length = fread(file, 1, LIMIT, source);
    bool complete = length < LIMIT && feof(source) && !ferror(source);
    fclose(source);

    static const unsigned char signature[] = {1, 0, 0, 0, 0, 0, 0, 0};
    if (!complete || length < sizeof(signature) || memcmp(file, signature, sizeof(signature)) != 0) goto done;
    Reader data = {file + sizeof(signature), file + length};
    uint64_t metadata_length;
    if (!read_uint(&data, &metadata_length)) goto done;
    const unsigned char *metadata_start = data.pos;
    if (!skip(&data, metadata_length) || !contains_nearby((Reader){metadata_start, data.pos})) goto done;
    size_t header_length = (size_t)(data.pos - file);
    uint64_t body_length;
    if (!read_uint(&data, &body_length) || body_length != (size_t)(data.end - data.pos)) goto done;

    size_t raw_length;
    if (!inflate_flags(data, raw, &raw_length)) goto done;
    Reader flags = {raw, raw + raw_length};
    Writer candidate = {written, written + LIMIT};
    int state = -1;
    if (!transform_flags(flags, &candidate, false, &state) ||
        (size_t)(candidate.pos - written) != raw_length ||
        memcmp(written, raw, raw_length) != 0) goto done;
    if (!output) {
        puts(state < 0 ? "absent" : state == 0 ? "disabled" : "enabled");
        success = true;
        goto done;
    }
    if (state == 1) {
        success = write_result(output, file, length, NULL, 0);
        goto done;
    }
    candidate.pos = written;
    if (!transform_flags(flags, &candidate, true, &state)) goto done;
    size_t new_body_length;
    if (!deflate_flags((Reader){written, candidate.pos}, compressed, &new_body_length)) goto done;
    Writer header = {file + header_length, file + LIMIT};
    if (!write_uint(&header, new_body_length)) goto done;
    success = write_result(output, file, (size_t)(header.pos - file), compressed, new_body_length);

done:
    free(memory);
    return success;
}

int main(int argc, char **argv) {
    if (argc == 3) {
        bool inspect = strcmp(argv[1], "--status") == 0;
        if (process_snapshot(inspect ? argv[2] : argv[1], inspect ? NULL : argv[2])) return 0;
    }
    fputs("Nearby 配置无法校验或重建。原文件尚未修改。\n", stderr);
    return 1;
}
