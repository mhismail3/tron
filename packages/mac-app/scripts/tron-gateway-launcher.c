#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int executable_path(char *output, size_t capacity) {
    uint32_t size = (uint32_t)capacity;
    char unresolved[PATH_MAX];
    if (_NSGetExecutablePath(unresolved, &size) != 0) return -1;
    return realpath(unresolved, output) == NULL ? -1 : 0;
}

int main(int argc, char **argv) {
    char executable[PATH_MAX];
    if (executable_path(executable, sizeof(executable)) != 0) {
        fputs("Tron could not resolve its gateway launcher path.\n", stderr);
        return 70;
    }

    char *macos = strrchr(executable, '/');
    if (macos == NULL) return 70;
    *macos = '\0';

    char resource_root[PATH_MAX];
    if (snprintf(resource_root, sizeof(resource_root),
                 "%s/../../../../../Resources/Gateway", executable) >= (int)sizeof(resource_root)) {
        return 70;
    }

#if defined(__arm64__)
    const char *runtime_name = "node-arm64";
#elif defined(__x86_64__)
    const char *runtime_name = "node-x64";
#else
#error Unsupported macOS architecture
#endif

    char node[PATH_MAX];
    char entrypoint[PATH_MAX];
    if (snprintf(node, sizeof(node), "%s/runtime/%s", resource_root, runtime_name) >= (int)sizeof(node) ||
        snprintf(entrypoint, sizeof(entrypoint), "%s/app/dist/index.js", resource_root) >= (int)sizeof(entrypoint)) {
        return 70;
    }

    if (access(node, X_OK) != 0 || access(entrypoint, R_OK) != 0) {
        fprintf(stderr, "Tron gateway payload is incomplete at %s. Reinstall Tron.\n", resource_root);
        return 78;
    }

    char **child_argv = calloc((size_t)argc + 2, sizeof(char *));
    if (child_argv == NULL) return 71;
    child_argv[0] = node;
    child_argv[1] = entrypoint;
    for (int index = 1; index < argc; ++index) child_argv[index + 1] = argv[index];
    child_argv[argc + 1] = NULL;

    execv(node, child_argv);
    perror("Tron could not start its gateway runtime");
    free(child_argv);
    return 71;
}
