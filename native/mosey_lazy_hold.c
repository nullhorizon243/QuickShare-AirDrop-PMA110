/*
 * LD_PRELOAD shim for mosey_server.
 *
 * On stock global builds, mosey_server is managed by init as a lazy AIDL
 * service (disabled + oneshot in mosey.rc) and is auto-restarted on demand.
 * Because this runtime loader does not modify init rc files, this shim keeps
 * the registered lazy service persistent while the session is active by
 * calling AServiceManager_forceLazyServicesPersist(true) and ignoring
 * requests to disable persistence.
 */
#include <stdbool.h>
#include <stddef.h>

typedef int (*RegisterLazyService)(void *, const char *);
typedef void (*ForcePersist)(bool);
extern void *dlsym(void *, const char *);
#ifndef RTLD_NEXT
#define RTLD_NEXT ((void *)-1)
#endif

__attribute__((visibility("default")))
int AServiceManager_registerLazyService(void *binder, const char *name) {
    ForcePersist force_persist =
        (ForcePersist)dlsym(RTLD_NEXT, "AServiceManager_forceLazyServicesPersist");
    RegisterLazyService register_lazy =
        (RegisterLazyService)dlsym(RTLD_NEXT, "AServiceManager_registerLazyService");
    if (force_persist == NULL || register_lazy == NULL) {
        return -38;
    }
    force_persist(true);
    return register_lazy(binder, name);
}

__attribute__((visibility("default")))
void AServiceManager_forceLazyServicesPersist(bool persist) {
    ForcePersist force_persist =
        (ForcePersist)dlsym(RTLD_NEXT, "AServiceManager_forceLazyServicesPersist");
    if (persist && force_persist != NULL) {
        force_persist(true);
    }
}
