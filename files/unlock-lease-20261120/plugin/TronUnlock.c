#include <CoreFoundation/CoreFoundation.h>
#include <Security/AuthorizationPlugin.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <os/log.h>
#include <poll.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include "requirement.h"

#define SOCKET_PATH "/tmp/com.tron.unlock/plugin.sock"
#define DEADLINE_MS 1000

typedef struct { const AuthorizationCallbacks *callbacks; } Plugin;
typedef struct { Plugin *plugin; AuthorizationEngineRef engine; } Mechanism;

static os_log_t logger(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.tron.unlock", "plugin"); });
    return log;
}

static long long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000LL + t.tv_nsec / 1000000;
}

static bool wait_readable(int fd, long long deadline) {
    for (;;) {
        long long left = deadline - now_ms();
        if (left <= 0) return false;
        struct pollfd p = { fd, POLLIN, 0 };
        int r = poll(&p, 1, (int)left);
        if (r > 0) return true;
        if (r == 0 || errno != EINTR) return false;
    }
}

static bool peer_is_broker(int fd) {
    audit_token_t token;
    socklen_t length = sizeof token;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) != 0) return false;
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
    const void *keys[] = { kSecGuestAttributeAudit };
    const void *values[] = { data };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus guest = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    OSStatus parsed = guest ? guest : SecRequirementCreateWithString(CFSTR(BROKER_REQUIREMENT), kSecCSDefaultFlags, &requirement);
    OSStatus valid = parsed ? parsed : SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    bool ok = valid == errSecSuccess;
    if (!ok) os_log(logger(), "TronUnlock peer check guest=%d requirement=%d validity=%d", (int)guest, (int)parsed, (int)valid);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    CFRelease(attributes);
    CFRelease(data);
    return ok;
}

static const char *ask_broker(void) {
    long long deadline = now_ms() + DEADLINE_MS;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return "socket";
    const char *verdict = "connect";
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, SOCKET_PATH, sizeof address.sun_path);
    char reply[16];
    size_t n = 0;
    if (connect(fd, (struct sockaddr *)&address, sizeof address) != 0) goto done;
    verdict = "signature";
    if (!peer_is_broker(fd)) goto done;
    verdict = "write";
    if (write(fd, "UNLOCK\n", 7) != 7) goto done;
    verdict = "timeout";
    while (n < sizeof reply && wait_readable(fd, deadline)) {
        ssize_t r = read(fd, reply + n, sizeof reply - n);
        if (r <= 0) { verdict = "closed"; break; }
        n += (size_t)r;
        if (memchr(reply, '\n', n)) { verdict = "reply"; break; }
    }
    if (n == 6 && memcmp(reply, "ALLOW\n", 6) == 0) verdict = "allow";
    else if (strcmp(verdict, "reply") == 0) verdict = "deny";
done:
    close(fd);
    return verdict;
}

static OSStatus PluginDestroy(AuthorizationPluginRef plugin) {
    free(plugin);
    return errSecSuccess;
}

static OSStatus MechanismCreate(AuthorizationPluginRef plugin, AuthorizationEngineRef engine, AuthorizationMechanismId mechanismId, AuthorizationMechanismRef *out) {
    Mechanism *mechanism = calloc(1, sizeof *mechanism);
    if (!mechanism) return errSecAllocate;
    mechanism->plugin = plugin;
    mechanism->engine = engine;
    *out = mechanism;
    return errSecSuccess;
}

static OSStatus MechanismInvoke(AuthorizationMechanismRef ref) {
    Mechanism *mechanism = ref;
    long long started = now_ms();
    const char *verdict = ask_broker();
    bool allow = strcmp(verdict, "allow") == 0;
    os_log(logger(), "TronUnlock verdict=%{public}s result=%{public}s ms=%lld", verdict, allow ? "ALLOW" : "DENY", now_ms() - started);
    return mechanism->plugin->callbacks->SetResult(mechanism->engine, allow ? kAuthorizationResultAllow : kAuthorizationResultDeny);
}

static OSStatus MechanismDeactivate(AuthorizationMechanismRef ref) {
    Mechanism *mechanism = ref;
    return mechanism->plugin->callbacks->DidDeactivate(mechanism->engine);
}

static OSStatus MechanismDestroy(AuthorizationMechanismRef ref) {
    free(ref);
    return errSecSuccess;
}

static const AuthorizationPluginInterface interface = {
    kAuthorizationPluginInterfaceVersion, PluginDestroy, MechanismCreate, MechanismInvoke, MechanismDeactivate, MechanismDestroy,
};

OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks, AuthorizationPluginRef *outPlugin, const AuthorizationPluginInterface **outInterface) {
    Plugin *plugin = calloc(1, sizeof *plugin);
    if (!plugin) return errSecAllocate;
    plugin->callbacks = callbacks;
    *outPlugin = plugin;
    *outInterface = &interface;
    return errSecSuccess;
}
