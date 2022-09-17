#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include <sys/stat.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "embed.h"

#ifdef _MSC_VER
#define stat _stat64
#define fstat _fstat
#define fileno _fileno

#define LUA_EXPORT __declspec(dllexport)
#else
#define LUA_EXPORT
#endif

enum {
    TEMPORARY_BUFFER_SIZE = 2 * 1024 * 1024
};
static char* temporary_buffer;
static int is_optimized;

static uint64_t get_nanos(void) {
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

LUA_EXPORT int truct__is_optimized(void) {
    return is_optimized;
}

LUA_EXPORT uint64_t truct__get_file_write_time(const char* filename) {
    #ifdef _WIN32
    uint64_t time = 0;

    HANDLE file = CreateFileA(filename, 0, FILE_SHARE_READ, 0, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
    if (file != INVALID_HANDLE_VALUE) {
        FILETIME last_write;
        if (GetFileTime(file, NULL, NULL, &last_write)) {
            // convert into a 64bit number
            ULARGE_INTEGER t = { .LowPart = last_write.dwLowDateTime, .HighPart = last_write.dwHighDateTime };
            time = t.QuadPart;
        } else {
            fprintf(stderr, "Cannot get file time from: %s", filename);
        }

        CloseHandle(file);
    } else {
        fprintf(stderr, "Cannot get file! %s", filename);
    }

    return time;
    #else
    struct stat s;
    stat(filename, &s);
    return ((uint64_t)s.st_mtim.tv_sec * 1000000000ULL) + (uint64_t)s.st_mtim.tv_nsec;
    #endif
}

LUA_EXPORT uint32_t truct__hash_file(const char* filename) {
    // actual file reading
    FILE* file = fopen(filename, "r");
    if (!file) {
        fprintf(stderr, "Could not read file: %s\n", filename);
        return 0;
    }

    int descriptor = fileno(file);
    struct stat file_stats;
    if (fstat(descriptor, &file_stats) == -1) {
        fprintf(stderr, "Could not figure out file size: %s\n", filename);
        return 0;
    }

    size_t done = 0;
    size_t length = file_stats.st_size;
    uint32_t hash = 0x811C9DC5;
    while (done < length) {
        // chunk off some juicy bits
        size_t amount = length - done;
        if (amount > TEMPORARY_BUFFER_SIZE) amount = TEMPORARY_BUFFER_SIZE;

        fread(temporary_buffer, 1, amount, file);
        done += amount;

        // FNV1A
        for (size_t i = 0; i < amount; i++) {
            hash = (temporary_buffer[i] ^ hash) * 0x01000193;
        }
    }

    return hash;
}

LUA_EXPORT void truct__embed_file(const char* input, const char* output) {
    FILE* fp = fopen(input, "rb");
    if (fp == NULL) {
        fprintf(stderr, "Error opening file: %s\n", input);
        return;
    }

    fseek(fp, 0, SEEK_END);
    const int fsize = ftell(fp);

    fseek(fp, 0, SEEK_SET);
    unsigned char *b = malloc(fsize);

    fread(b, fsize, 1, fp);
    fclose(fp);

    FILE* out = fopen(output, "wb");
    fprintf(out, "enum { FILE_SIZE = %d };\n", fsize);
    fprintf(out, "static const unsigned char FILE_DATA[] = {\n");
    for (int i = 0; i < fsize; ++i) {
        fprintf(out, "0x%02x%s", b[i],
            i == fsize-1 ? "" : ((i+1) % 16 == 0 ? ",\n" : ",")
        );
    }
    fprintf(out, "\n};\n");
    fclose(out);
}

int main(int argc, char** argv) {
    // handle dependencies
    temporary_buffer = malloc(TEMPORARY_BUFFER_SIZE);
    if (temporary_buffer == NULL) {
        fprintf(stderr, "No memory?\n");
        return 1;
    }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-O") == 0) {
            is_optimized = 1;
            continue;
        }
    }

    printf("~~~~~~~~\n");
    uint64_t start = get_nanos();

    lua_State* L = lua_open();
    luaL_openlibs(L);

    int ret = luaL_loadbuffer(L, (const char*) FILE_DATA, FILE_SIZE, "embed.lua");
    //int ret = luaL_loadfile(L, "W:\\External\\truct\\embed.lua");
    if (ret != 0) {
        fprintf(stderr, "Lua runtime exited with %d\n", ret);

        const char* str = lua_tostring(L, -1);
        luaL_traceback(L,  L, str, 4);
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }

    // it gets all the C functions from LUA_EXPORTs
    ret = lua_pcall(L, 0, 0, 0);
    if (ret != 0) {
        fprintf(stderr, "Lua runtime exited with %d\n", ret);

        const char* str = lua_tostring(L, -1);
        luaL_traceback(L,  L, str, 4);
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }

    ret = luaL_dofile(L, "build.lua");
    if(ret != 0) {
        fprintf(stderr, "Lua runtime exited with %d\n", ret);

        const char* str = lua_tostring(L, -1);
        luaL_traceback(L, L, str, 4);
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }

    lua_close(L);

    uint64_t end = get_nanos();
    printf("> Compiled in %f seconds\n", (end - start) / 1000000000.0);
    return 0;
}
