#include <fcntl.h>
#include <mach-o/dyld.h>
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_MANIFEST_BYTES (64 * 1024)
#define MAX_COMPONENT_BYTES 128

typedef struct {
    char channel[MAX_COMPONENT_BYTES];
    char version[MAX_COMPONENT_BYTES];
    char fingerprint[65];
    char sourceRevision[256];
    char runtimeEpoch[MAX_COMPONENT_BYTES];
} PayloadIdentity;

static int executable_path(char *output, size_t capacity) {
    uint32_t size = (uint32_t)capacity;
    char unresolved[PATH_MAX];
    if (_NSGetExecutablePath(unresolved, &size) != 0) return -1;
    return realpath(unresolved, output) == NULL ? -1 : 0;
}

static int bounded_file(const char *path, char *output, size_t capacity) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
        (off_t)info.st_size >= (off_t)capacity || info.st_size > MAX_MANIFEST_BYTES) {
        close(fd);
        return -1;
    }
    size_t expected = (size_t)info.st_size;
    size_t offset = 0;
    while (offset < expected) {
        ssize_t count = read(fd, output + offset, expected - offset);
        if (count <= 0) {
            close(fd);
            return -1;
        }
        offset += (size_t)count;
    }
    close(fd);
    output[offset] = '\0';
    return 0;
}

static const char *skip_space(const char *cursor) {
    while (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n') cursor++;
    return cursor;
}

/* Payload manifests intentionally contain only bounded, unescaped identity
 * strings. Rejecting escapes keeps this tiny launcher parser unambiguous. */
static int json_string(const char *json, const char *key, char *output, size_t capacity) {
    char needle[96];
    int length = snprintf(needle, sizeof(needle), "\"%s\"", key);
    if (length <= 0 || (size_t)length >= sizeof(needle)) return -1;
    const char *cursor = json;
    while ((cursor = strstr(cursor, needle)) != NULL) {
        cursor += length;
        cursor = skip_space(cursor);
        if (*cursor++ != ':') continue;
        cursor = skip_space(cursor);
        if (*cursor++ != '\"') continue;
        const char *start = cursor;
        while (*cursor != '\0' && *cursor != '\"') {
            if (*cursor == '\\' || (unsigned char)*cursor < 0x20) return -1;
            cursor++;
        }
        if (*cursor != '\"' || (size_t)(cursor - start) >= capacity) return -1;
        memcpy(output, start, (size_t)(cursor - start));
        output[cursor - start] = '\0';
        return 0;
    }
    return -1;
}

static int json_schema_one(const char *json) {
    const char *cursor = strstr(json, "\"schema\"");
    if (cursor == NULL) return -1;
    cursor += strlen("\"schema\"");
    cursor = skip_space(cursor);
    if (*cursor++ != ':') return -1;
    cursor = skip_space(cursor);
    return (*cursor == '1' && (cursor[1] < '0' || cursor[1] > '9')) ? 0 : -1;
}

static int valid_component(const char *value, size_t maxLength) {
    size_t length = strlen(value);
    if (length == 0 || length > maxLength || strcmp(value, ".") == 0 || strcmp(value, "..") == 0) return 0;
    for (size_t index = 0; index < length; ++index) {
        unsigned char character = (unsigned char)value[index];
        if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') || character == '.' || character == '-' || character == '_')) {
            return 0;
        }
    }
    return 1;
}

static int valid_fingerprint(const char *value) {
    if (strlen(value) != 64) return 0;
    for (size_t index = 0; index < 64; ++index) {
        char character = value[index];
        if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))) return 0;
    }
    return 1;
}

static int path_is_under(const char *root, const char *candidate) {
    size_t length = strlen(root);
    return strncmp(root, candidate, length) == 0 && (candidate[length] == '\0' || candidate[length] == '/');
}

/* The launcher deliberately does not claim to hash the full dependency tree.
 * Deployment and the Swift validator perform the deterministic fingerprint.
 * Here, externally staged version directories must be immutable and contain no
 * symlinks, so a normal launcher run cannot silently consume edited files. */
static int immutable_tree(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0 || (info.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) != 0) return -1;
    if (S_ISLNK(info.st_mode)) return -1;
    if (!S_ISDIR(info.st_mode)) return S_ISREG(info.st_mode) ? 0 : -1;
    DIR *directory = opendir(path);
    if (directory == NULL) return -1;
    struct dirent *entry;
    char child[PATH_MAX];
    int result = 0;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (snprintf(child, sizeof(child), "%s/%s", path, entry->d_name) >= (int)sizeof(child)
            || immutable_tree(child) != 0) { result = -1; break; }
    }
    closedir(directory);
    return result;
}

static int required_path(const char *root, const char *relative, char *resolved, size_t capacity,
                         int executable, off_t minimumBytes, int directory) {
    char candidate[PATH_MAX];
    if (snprintf(candidate, sizeof(candidate), "%s/%s", root, relative) >= (int)sizeof(candidate) ||
        realpath(candidate, resolved) == NULL || !path_is_under(root, resolved)) return -1;
    struct stat info;
    if (stat(resolved, &info) != 0) return -1;
    if (directory ? !S_ISDIR(info.st_mode) : !S_ISREG(info.st_mode)) return -1;
    if (!directory && info.st_size < minimumBytes) return -1;
    if (executable && access(resolved, X_OK) != 0) return -1;
    (void)capacity;
    return 0;
}

static int read_payload_manifest(const char *root, PayloadIdentity *identity) {
    char path[PATH_MAX];
    char json[MAX_MANIFEST_BYTES + 1];
    if (snprintf(path, sizeof(path), "%s/manifest.json", root) >= (int)sizeof(path) ||
        bounded_file(path, json, sizeof(json)) != 0 || json_schema_one(json) != 0) return -1;
    char kind[64], gatewayVersion[128], nodeVersion[128];
    if (json_string(json, "kind", kind, sizeof(kind)) != 0 || strcmp(kind, "tron-gateway-payload") != 0 ||
        json_string(json, "gatewayVersion", gatewayVersion, sizeof(gatewayVersion)) != 0 || gatewayVersion[0] == '\0' ||
        json_string(json, "nodeVersion", nodeVersion, sizeof(nodeVersion)) != 0 || nodeVersion[0] == '\0' ||
        json_string(json, "sourceRevision", identity->sourceRevision, sizeof(identity->sourceRevision)) != 0 || identity->sourceRevision[0] == '\0' ||
        json_string(json, "runtimeEpoch", identity->runtimeEpoch, sizeof(identity->runtimeEpoch)) != 0 || !valid_component(identity->runtimeEpoch, MAX_COMPONENT_BYTES - 1) ||
        json_string(json, "channel", identity->channel, sizeof(identity->channel)) != 0 ||
        json_string(json, "version", identity->version, sizeof(identity->version)) != 0 ||
        json_string(json, "payloadFingerprint", identity->fingerprint, sizeof(identity->fingerprint)) != 0 ||
        !valid_component(identity->channel, 64) || !valid_component(identity->version, 128) ||
        !valid_fingerprint(identity->fingerprint)) return -1;
    return 0;
}

static int validate_payload(const char *payload, const char *expectedChannel, const char *expectedVersion,
                            const char *expectedFingerprint, char *node, char *entrypoint, char *helper,
                            PayloadIdentity *selectedIdentity) {
    char root[PATH_MAX];
    PayloadIdentity identity;
    if (realpath(payload, root) == NULL || immutable_tree(root) != 0 || read_payload_manifest(root, &identity) != 0) return -1;
    if ((expectedChannel != NULL && strcmp(expectedChannel, identity.channel) != 0) ||
        (expectedVersion != NULL && strcmp(expectedVersion, identity.version) != 0) ||
        (expectedFingerprint != NULL && strcmp(expectedFingerprint, identity.fingerprint) != 0)) return -1;
    if (required_path(root, "app/dist/index.js", entrypoint, PATH_MAX, 0, 1024, 0) != 0 ||
        required_path(root, "app/package.json", node, PATH_MAX, 0, 1, 0) != 0 ||
        required_path(root, "app/package-lock.json", node, PATH_MAX, 0, 1, 0) != 0 ||
        required_path(root, "app/scripts/ensure-node-pty-helper.mjs", node, PATH_MAX, 0, 1, 0) != 0 ||
        required_path(root, "app/scripts/gateway-payload-deploy.mjs", helper, PATH_MAX, 0, 1, 0) != 0 ||
        required_path(root, "app/node_modules", node, PATH_MAX, 0, 0, 1) != 0) return -1;
#if defined(__arm64__)
    const char *runtimeName = "node-arm64";
#elif defined(__x86_64__)
    const char *runtimeName = "node-x64";
#else
#error Unsupported macOS architecture
#endif
    char runtimeRelative[64];
    const char *architectures[] = {"arm64", "x64"};
    for (size_t index = 0; index < sizeof(architectures) / sizeof(architectures[0]); ++index) {
        char requiredRuntime[64];
        if (snprintf(requiredRuntime, sizeof(requiredRuntime), "runtime/node-%s", architectures[index]) >= (int)sizeof(requiredRuntime) ||
            required_path(root, requiredRuntime, node, PATH_MAX, 1, 1024 * 1024, 0) != 0) return -1;
    }
    if (snprintf(runtimeRelative, sizeof(runtimeRelative), "runtime/%s", runtimeName) >= (int)sizeof(runtimeRelative)) return -1;
    if (selectedIdentity != NULL) *selectedIdentity = identity;
    /* Re-resolve the two paths after every validation step. They are absolute
     * realpaths, never paths assembled from an untrusted manifest. */
    if (required_path(root, "app/dist/index.js", entrypoint, PATH_MAX, 0, 1024, 0) != 0 ||
        required_path(root, runtimeRelative, node, PATH_MAX, 1, 1024 * 1024, 0) != 0) return -1;
    return 0;
}

static int selected_home(char *home, size_t capacity) {
    const char *override = getenv("TRON_DATA_DIR");
    if (override != NULL && override[0] == '/') {
        if (snprintf(home, capacity, "%s", override) >= (int)capacity) return -1;
        return 0;
    }
    const char *homeDirectory = getenv("HOME");
    if (homeDirectory == NULL || homeDirectory[0] != '/') return -1;
    const char *name = getenv("TRON_HOME_NAME");
    if (name == NULL || name[0] == '\0') name = ".tron";
    if (!valid_component(name, 64)) return -1;
    return snprintf(home, capacity, "%s/%s", homeDirectory, name) >= (int)capacity ? -1 : 0;
}

static int external_payload(const char *home, const char *channel, char *node, char *entrypoint, char *helper, PayloadIdentity *selectedIdentity) {
    char payloadsPath[PATH_MAX], payloadsRoot[PATH_MAX], channelRootPath[PATH_MAX], channelRoot[PATH_MAX];
    char versionsPath[PATH_MAX], versionsRoot[PATH_MAX], currentPath[PATH_MAX];
    char selection[MAX_MANIFEST_BYTES + 1], version[128], fingerprint[65], selectedChannel[64];
    if (!valid_component(channel, 64) ||
        snprintf(payloadsPath, sizeof(payloadsPath), "%s/gateway/payloads", home) >= (int)sizeof(payloadsPath) ||
        realpath(payloadsPath, payloadsRoot) == NULL ||
        snprintf(channelRootPath, sizeof(channelRootPath), "%s/%s", payloadsRoot, channel) >= (int)sizeof(channelRootPath) ||
        realpath(channelRootPath, channelRoot) == NULL || !path_is_under(payloadsRoot, channelRoot) ||
        snprintf(versionsPath, sizeof(versionsPath), "%s/versions", channelRoot) >= (int)sizeof(versionsPath) ||
        realpath(versionsPath, versionsRoot) == NULL || !path_is_under(channelRoot, versionsRoot) ||
        snprintf(currentPath, sizeof(currentPath), "%s/current.json", channelRoot) >= (int)sizeof(currentPath) ||
        bounded_file(currentPath, selection, sizeof(selection)) != 0 || json_schema_one(selection) != 0) return -1;
    char kind[64];
    if (json_string(selection, "kind", kind, sizeof(kind)) != 0 || strcmp(kind, "tron-gateway-selection") != 0 ||
        json_string(selection, "channel", selectedChannel, sizeof(selectedChannel)) != 0 ||
        json_string(selection, "version", version, sizeof(version)) != 0 ||
        json_string(selection, "payloadFingerprint", fingerprint, sizeof(fingerprint)) != 0 ||
        strcmp(selectedChannel, channel) != 0 || !valid_component(version, 128) || !valid_fingerprint(fingerprint)) return -1;
    char payload[PATH_MAX];
    if (snprintf(payload, sizeof(payload), "%s/%s", versionsRoot, version) >= (int)sizeof(payload)) return -1;
    char payloadRoot[PATH_MAX];
    if (realpath(payload, payloadRoot) == NULL || !path_is_under(versionsRoot, payloadRoot)) return -1;
    return validate_payload(payloadRoot, channel, version, fingerprint, node, entrypoint, helper, selectedIdentity);
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

    char bundledPath[PATH_MAX];
    if (snprintf(bundledPath, sizeof(bundledPath), "%s/../../../../../Resources/Gateway", executable) >= (int)sizeof(bundledPath)) return 70;
    char bundledRoot[PATH_MAX];
    if (realpath(bundledPath, bundledRoot) == NULL) {
        fputs("Tron bundled Gateway payload is missing. Reinstall Tron.\n", stderr);
        return 78;
    }

    char node[PATH_MAX], entrypoint[PATH_MAX], helper[PATH_MAX], home[PATH_MAX];
    PayloadIdentity selectedIdentity;
    const char *channel = getenv("TRON_GATEWAY_CHANNEL");
    if (channel == NULL || channel[0] == '\0') channel = "stable";
    int external = selected_home(home, sizeof(home)) == 0 && external_payload(home, channel, node, entrypoint, helper, &selectedIdentity) == 0;
    if (!external && validate_payload(bundledRoot, NULL, NULL, NULL, node, entrypoint, helper, &selectedIdentity) != 0) {
        fprintf(stderr, "Tron Gateway payload is incomplete or invalid at %s. Reinstall Tron.\n", bundledRoot);
        return 78;
    }
    if (setenv("TRON_GATEWAY_SOURCE_REVISION", selectedIdentity.sourceRevision, 1) != 0 ||
        setenv("TRON_GATEWAY_BUILD_FINGERPRINT", selectedIdentity.fingerprint, 1) != 0 ||
        setenv("TRON_GATEWAY_RUNTIME_EPOCH", selectedIdentity.runtimeEpoch, 1) != 0 ||
        setenv("TRON_GATEWAY_UPDATE_HELPER", helper, 1) != 0) {
        fputs("Tron could not export Gateway payload identity.\n", stderr);
        return 70;
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
