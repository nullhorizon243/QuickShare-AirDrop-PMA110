#include <stdbool.h>
#include <stddef.h>

#ifdef USE_NOSTDLIB_ENTRY
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern const char *dlerror(void);
extern int printf(const char *, ...);
extern int fflush(void *);
extern void _exit(int) __attribute__((noreturn));

__asm__(".text\n.global _start\n_start:\n ldr x0, [sp]\n add x1, sp, #8\n b query\n");

void query(int argc, char **argv) {
    if (argc != 2) _exit(2);
    void *library = dlopen("libbinder_ndk.so", 2);
    if (!library) {
        printf("Loading libbinder_ndk failed: %s\n", dlerror());
        fflush(0);
        _exit(2);
    }
    bool (*is_declared)(const char *) = (bool (*)(const char *))dlsym(library, "AServiceManager_isDeclared");
    if (!is_declared) _exit(2);
    printf("Live service declaration present=%d\n", is_declared(argv[1]));
    fflush(0);
    _exit(0);
}
#else
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen("libbinder_ndk.so", RTLD_NOW);
    if (!library) {
        printf("Loading libbinder_ndk failed: %s\n", dlerror());
        fflush(stdout);
        return 2;
    }
    bool (*is_declared)(const char *) = (bool (*)(const char *))dlsym(library, "AServiceManager_isDeclared");
    if (!is_declared) return 2;
    printf("Live service declaration present=%d\n", is_declared(argv[1]));
    fflush(stdout);
    return 0;
}
#endif
