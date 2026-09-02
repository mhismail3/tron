#include <ctype.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <CommonCrypto/CommonDigest.h>

#define MAX_MANIFEST_BYTES (64 * 1024)
#define MAX_PUSH_CONFIG_BYTES (4 * 1024)
#define MAX_COMPONENT_BYTES 128
#define TRON_GATEWAY_PROTOCOL_VERSION "4"
#define TRON_GATEWAY_MIN_PROTOCOL_VERSION "4"

typedef struct {
    char channel[MAX_COMPONENT_BYTES];
    char version[MAX_COMPONENT_BYTES];
    char gatewayVersion[MAX_COMPONENT_BYTES];
    char fingerprint[65];
    char sourceRevision[256];
    char runtimeEpoch[MAX_COMPONENT_BYTES];
    char nodeVersion[MAX_COMPONENT_BYTES];
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

static int json_key_count(const char *json, const char *key) {
    char needle[96];
    int length = snprintf(needle, sizeof(needle), "\"%s\"", key);
    if (length <= 0 || (size_t)length >= sizeof(needle)) return -1;
    int count = 0;
    const char *cursor = json;
    while ((cursor = strstr(cursor, needle)) != NULL) {
        if (++count > 1) return count;
        cursor += length;
    }
    return count;
}

static int json_manifest_exact(const char *json) {
    const char *keys[] = {"schema", "kind", "gatewayVersion", "protocolVersion", "minProtocolVersion", "nodeVersion", "sourceRevision", "runtimeEpoch", "channel", "version", "payloadFingerprint", "dependencyTreeCoverage"};
    int seen[12] = {0};
    const char *cursor = skip_space(json);
    if (*cursor++ != '{') return -1;
    for (;;) {
        cursor = skip_space(cursor);
        if (*cursor == '}') {
            cursor = skip_space(cursor + 1);
            if (*cursor != '\0') return -1;
            for (size_t index = 0; index < 12; ++index) if (!seen[index]) return -1;
            return 0;
        }
        if (*cursor++ != '"') return -1;
        const char *start = cursor;
        while (*cursor != '\0' && *cursor != '"') {
            if (*cursor == '\\' || (unsigned char)*cursor < 0x20) return -1;
            cursor++;
        }
        if (*cursor++ != '"') return -1;
        size_t length = (size_t)(cursor - start - 1);
        int found = -1;
        for (size_t index = 0; index < 12; ++index) {
            if (strlen(keys[index]) == length && strncmp(start, keys[index], length) == 0) { found = (int)index; break; }
        }
        if (found < 0 || seen[found]++) return -1;
        cursor = skip_space(cursor);
        if (*cursor++ != ':') return -1;
        cursor = skip_space(cursor);
        if (found == 0) {
            if (*cursor++ != '1' || (*cursor >= '0' && *cursor <= '9')) return -1;
        } else {
            if (*cursor++ != '"') return -1;
            while (*cursor != '\0' && *cursor != '"') {
                if (*cursor == '\\' || (unsigned char)*cursor < 0x20) return -1;
                cursor++;
            }
            if (*cursor++ != '"') return -1;
        }
        cursor = skip_space(cursor);
        if (*cursor == ',') { cursor++; continue; }
        if (*cursor == '}') continue;
        return -1;
    }
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

static int valid_revision(const char *value) {
    if (strlen(value) != 40) return 0;
    for (size_t index = 0; index < 40; ++index) {
        char character = value[index];
        if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))) return 0;
    }
    return 1;
}

static int valid_uuid(const char *value) {
    if (strlen(value) != 36) return 0;
    for (size_t index = 0; index < 36; ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) { if (value[index] != '-') return 0; continue; }
        char character = value[index];
        if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))) return 0;
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

static int regular_directory_path(const char *path) {
    struct stat info;
    return lstat(path, &info) == 0 && S_ISDIR(info.st_mode) && !S_ISLNK(info.st_mode);
}

static int path_is_under(const char *root, const char *candidate) {
    size_t length = strlen(root);
    return strncmp(root, candidate, length) == 0 && (candidate[length] == '\0' || candidate[length] == '/');
}

static int path_is_fingerprint_covered(const char *root, const char *candidate) {
    char app[PATH_MAX], runtime[PATH_MAX];
    if (snprintf(app, sizeof(app), "%s/app", root) >= (int)sizeof(app)
        || snprintf(runtime, sizeof(runtime), "%s/runtime", root) >= (int)sizeof(runtime)) return 0;
    return path_is_under(app, candidate) || path_is_under(runtime, candidate);
}

/* The launcher recomputes the same deterministic dependency-tree fingerprint
 * as deployment and the Swift validator. Internal links are permitted only
 * when they resolve to a regular file inside app/ or runtime/. */
static int immutable_tree(const char *path, const char *root) {
    struct stat info;
    if (lstat(path, &info) != 0) return -1;
    if (S_ISLNK(info.st_mode)) {
        char resolved[PATH_MAX];
        struct stat target;
        if (realpath(path, resolved) == NULL || !path_is_under(root, resolved)
            || !path_is_fingerprint_covered(root, resolved)
            || stat(resolved, &target) != 0 || !S_ISREG(target.st_mode)) return -1;
        return 0;
    }
    if ((info.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) != 0) return -1;
    if (!S_ISDIR(info.st_mode)) return S_ISREG(info.st_mode) ? 0 : -1;
    DIR *directory = opendir(path);
    if (directory == NULL) return -1;
    struct dirent *entry;
    char child[PATH_MAX];
    int result = 0;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (snprintf(child, sizeof(child), "%s/%s", path, entry->d_name) >= (int)sizeof(child)
            || immutable_tree(child, root) != 0) { result = -1; break; }
    }
    closedir(directory);
    return result;
}

static int required_path(const char *root, const char *relative, char *resolved, size_t capacity,
                         int executable, off_t minimumBytes, int directory) {
    char candidate[PATH_MAX];
    if (snprintf(candidate, sizeof(candidate), "%s/%s", root, relative) >= (int)sizeof(candidate) ||
        realpath(candidate, resolved) == NULL || !path_is_under(root, resolved)) return -1;
    struct stat linkInfo;
    if (lstat(candidate, &linkInfo) != 0 || S_ISLNK(linkInfo.st_mode)) return -1;
    struct stat info;
    if (stat(resolved, &info) != 0) return -1;
    if (directory ? !S_ISDIR(info.st_mode) : !S_ISREG(info.st_mode)) return -1;
    if (!directory && info.st_size < minimumBytes) return -1;
    if (executable && access(resolved, X_OK) != 0) return -1;
    (void)capacity;
    return 0;
}

/* Required runtime aliases are the one intentional executable-symlink contract.
 * Their exact relative text is fingerprinted, and both the textual target and
 * resolved file must match the already-required architecture runtime. */
static int required_runtime_alias(const char *root, const char *architecture) {
    char directory[PATH_MAX], alias[PATH_MAX], runtime[PATH_MAX];
    char aliasResolved[PATH_MAX], runtimeResolved[PATH_MAX], target[PATH_MAX], expectedTarget[PATH_MAX];
    struct stat directoryInfo, aliasInfo, targetInfo;
    if (snprintf(directory, sizeof(directory), "%s/runtime/bin-%s", root, architecture) >= (int)sizeof(directory) ||
        snprintf(alias, sizeof(alias), "%s/node", directory) >= (int)sizeof(alias) ||
        snprintf(runtime, sizeof(runtime), "%s/runtime/node-%s", root, architecture) >= (int)sizeof(runtime) ||
        snprintf(expectedTarget, sizeof(expectedTarget), "../node-%s", architecture) >= (int)sizeof(expectedTarget) ||
        lstat(directory, &directoryInfo) != 0 || !S_ISDIR(directoryInfo.st_mode) || S_ISLNK(directoryInfo.st_mode) ||
        lstat(alias, &aliasInfo) != 0 || !S_ISLNK(aliasInfo.st_mode)) return -1;
    ssize_t length = readlink(alias, target, sizeof(target) - 1);
    if (length <= 0 || length >= (ssize_t)sizeof(target) - 1) return -1;
    target[length] = '\0';
    if (strcmp(target, expectedTarget) != 0 || realpath(alias, aliasResolved) == NULL ||
        realpath(runtime, runtimeResolved) == NULL || strcmp(aliasResolved, runtimeResolved) != 0 ||
        !path_is_under(root, aliasResolved) || stat(aliasResolved, &targetInfo) != 0 ||
        !S_ISREG(targetInfo.st_mode) || access(aliasResolved, X_OK) != 0) return -1;
    return 0;
}

static int required_pi_alias(const char *root, const char *architecture) {
    const char *expectedTarget = "../../app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js";
    char directory[PATH_MAX], alias[PATH_MAX], cli[PATH_MAX];
    char aliasResolved[PATH_MAX], cliResolved[PATH_MAX], target[PATH_MAX];
    struct stat directoryInfo, aliasInfo, cliInfo, targetInfo;
    if (snprintf(directory, sizeof(directory), "%s/runtime/bin-%s", root, architecture) >= (int)sizeof(directory) ||
        snprintf(alias, sizeof(alias), "%s/pi", directory) >= (int)sizeof(alias) ||
        snprintf(cli, sizeof(cli), "%s/app/node_modules/@earendil-works/pi-coding-agent/dist/cli.js", root) >= (int)sizeof(cli) ||
        lstat(directory, &directoryInfo) != 0 || !S_ISDIR(directoryInfo.st_mode) || S_ISLNK(directoryInfo.st_mode) ||
        lstat(cli, &cliInfo) != 0 || !S_ISREG(cliInfo.st_mode) || S_ISLNK(cliInfo.st_mode) ||
        lstat(alias, &aliasInfo) != 0 || !S_ISLNK(aliasInfo.st_mode)) return -1;
    ssize_t length = readlink(alias, target, sizeof(target) - 1);
    if (length <= 0 || length >= (ssize_t)sizeof(target) - 1) return -1;
    target[length] = '\0';
    if (strcmp(target, expectedTarget) != 0 || realpath(alias, aliasResolved) == NULL ||
        realpath(cli, cliResolved) == NULL || strcmp(aliasResolved, cliResolved) != 0 ||
        !path_is_under(root, aliasResolved) || stat(aliasResolved, &targetInfo) != 0 ||
        !S_ISREG(targetInfo.st_mode) || access(aliasResolved, X_OK) != 0) return -1;
    return 0;
}

typedef struct {
    char path[PATH_MAX];
    char target[PATH_MAX];
    int symlink;
} FingerEntry;

static int safe_name(const char *name) {
    for (const unsigned char *cursor = (const unsigned char *)name; *cursor != '\0'; ++cursor) {
        if (*cursor < 0x20 || *cursor == 0x7f) return 0;
    }
    return 1;
}

static int append_finger_entry(FingerEntry **entries, size_t *count, size_t *capacity,
                               const char *path, const char *target, int symlink) {
    if (*count == *capacity) {
        size_t next = *capacity == 0 ? 64 : *capacity * 2;
        FingerEntry *grown = realloc(*entries, next * sizeof(FingerEntry));
        if (grown == NULL) return -1;
        *entries = grown;
        *capacity = next;
    }
    if (snprintf((*entries)[*count].path, PATH_MAX, "%s", path) >= PATH_MAX) return -1;
    if (target != NULL && snprintf((*entries)[*count].target, PATH_MAX, "%s", target) >= PATH_MAX) return -1;
    (*entries)[*count].symlink = symlink;
    (*count)++;
    return 0;
}

static int collect_finger_entries(const char *directory, const char *root,
                                  const char *relative, FingerEntry **entries,
                                  size_t *count, size_t *capacity) {
    DIR *handle = opendir(directory);
    if (handle == NULL) return -1;
    struct dirent *entry;
    int result = 0;
    while ((entry = readdir(handle)) != NULL) {
        /* readdir always returns these directory entries; skip them before
         * applying the payload-name safety policy. */
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (!safe_name(entry->d_name)) { result = -1; break; }
        char child[PATH_MAX], childRelative[PATH_MAX];
        if (snprintf(child, sizeof(child), "%s/%s", directory, entry->d_name) >= (int)sizeof(child) ||
            snprintf(childRelative, sizeof(childRelative), "%s/%s", relative, entry->d_name) >= (int)sizeof(childRelative)) { result = -1; break; }
        struct stat info;
        if (lstat(child, &info) != 0) { result = -1; break; }
        if (S_ISDIR(info.st_mode)) {
            if (collect_finger_entries(child, root, childRelative, entries, count, capacity) != 0) { result = -1; break; }
        } else if (S_ISREG(info.st_mode)) {
            if (append_finger_entry(entries, count, capacity, childRelative, NULL, 0) != 0) { result = -1; break; }
        } else if (S_ISLNK(info.st_mode)) {
            char target[PATH_MAX], resolved[PATH_MAX];
            ssize_t length = readlink(child, target, sizeof(target) - 1);
            struct stat targetInfo;
                    if (length <= 0 || length >= (ssize_t)sizeof(target) - 1) { result = -1; break; }
            // readlink(2) does not append a terminator; validate only after
            // explicitly terminating the bounded result.
            target[length] = '\0';
            if (!safe_name(target)) { result = -1; break; }
            if (realpath(child, resolved) == NULL || !path_is_under(root, resolved)
                || !path_is_fingerprint_covered(root, resolved) || stat(resolved, &targetInfo) != 0 ||
                !S_ISREG(targetInfo.st_mode) ||
                append_finger_entry(entries, count, capacity, childRelative, target, 1) != 0) { result = -1; break; }
        } else { result = -1; break; }
    }
    closedir(handle);
    return result;
}

static int finger_compare(const void *left, const void *right) {
    return strcmp(((const FingerEntry *)left)->path, ((const FingerEntry *)right)->path);
}

static int hash_file(const char *path, unsigned char digest[CC_SHA256_DIGEST_LENGTH]) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[64 * 1024];
    ssize_t length;
    while ((length = read(fd, buffer, sizeof(buffer))) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)length);
    int result = length < 0 ? -1 : (CC_SHA256_Final(digest, &context) == 1 ? 0 : -1);
    close(fd);
    return result;
}

static void digest_hex(const unsigned char *digest, char *output) {
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) snprintf(output + index * 2, 3, "%02x", digest[index]);
    output[CC_SHA256_DIGEST_LENGTH * 2] = '\0';
}

static int payload_fingerprint(const char *root, char output[65]) {
    FingerEntry *entries = NULL;
    size_t count = 0, capacity = 0;
    char app[PATH_MAX], runtime[PATH_MAX];
    if (snprintf(app, sizeof(app), "%s/app", root) >= (int)sizeof(app) || snprintf(runtime, sizeof(runtime), "%s/runtime", root) >= (int)sizeof(runtime) ||
        collect_finger_entries(app, root, "app", &entries, &count, &capacity) != 0 || collect_finger_entries(runtime, root, "runtime", &entries, &count, &capacity) != 0) { free(entries); return -1; }
    qsort(entries, count, sizeof(FingerEntry), finger_compare);
    CC_SHA256_CTX complete;
    CC_SHA256_Init(&complete);
    char line[PATH_MAX + 160];
    for (size_t index = 0; index < count; ++index) {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        char hex[65];
        if (entries[index].symlink) {
            CC_SHA256_CTX targetContext;
            CC_SHA256_Init(&targetContext);
            CC_SHA256_Update(&targetContext, entries[index].target, (CC_LONG)strlen(entries[index].target));
            CC_SHA256_Update(&targetContext, "\n", 1);
            CC_SHA256_Final(digest, &targetContext);
            digest_hex(digest, hex);
            if (snprintf(line, sizeof(line), "symlink:%s  %s\n", hex, entries[index].path) >= (int)sizeof(line)) { free(entries); return -1; }
        } else {
            char absolute[PATH_MAX];
            if (snprintf(absolute, sizeof(absolute), "%s/%s", root, entries[index].path) >= (int)sizeof(absolute) || hash_file(absolute, digest) != 0) { free(entries); return -1; }
            digest_hex(digest, hex);
            if (snprintf(line, sizeof(line), "%s  %s\n", hex, entries[index].path) >= (int)sizeof(line)) { free(entries); return -1; }
        }
        CC_SHA256_Update(&complete, line, (CC_LONG)strlen(line));
    }
    unsigned char completeDigest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(completeDigest, &complete);
    digest_hex(completeDigest, output);
    free(entries);
    return 0;
}

static int read_payload_manifest(const char *root, PayloadIdentity *identity) {
    char path[PATH_MAX];
    char json[MAX_MANIFEST_BYTES + 1];
    if (snprintf(path, sizeof(path), "%s/manifest.json", root) >= (int)sizeof(path) ||
        bounded_file(path, json, sizeof(json)) != 0 || json_manifest_exact(json) != 0) return -1;
    char kind[64], gatewayVersion[128], protocolVersion[16], minProtocolVersion[16], nodeVersion[128], coverage[128];
    if (json_string(json, "kind", kind, sizeof(kind)) != 0 || strcmp(kind, "tron-gateway-payload") != 0 ||
        json_string(json, "gatewayVersion", gatewayVersion, sizeof(gatewayVersion)) != 0 ||
        json_string(json, "protocolVersion", protocolVersion, sizeof(protocolVersion)) != 0 ||
        strcmp(protocolVersion, TRON_GATEWAY_PROTOCOL_VERSION) != 0 ||
        json_string(json, "minProtocolVersion", minProtocolVersion, sizeof(minProtocolVersion)) != 0 ||
        strcmp(minProtocolVersion, TRON_GATEWAY_MIN_PROTOCOL_VERSION) != 0 ||
        !valid_component(gatewayVersion, MAX_COMPONENT_BYTES - 1) ||
        snprintf(identity->gatewayVersion, sizeof(identity->gatewayVersion), "%s", gatewayVersion) >= (int)sizeof(identity->gatewayVersion) ||
        json_string(json, "dependencyTreeCoverage", coverage, sizeof(coverage)) != 0 ||
        strcmp(coverage, "app/** and runtime/** regular files") != 0 ||
        json_string(json, "nodeVersion", nodeVersion, sizeof(nodeVersion)) != 0 ||
        !valid_component(nodeVersion, MAX_COMPONENT_BYTES - 1) ||
        snprintf(identity->nodeVersion, sizeof(identity->nodeVersion), "%s", nodeVersion) >= (int)sizeof(identity->nodeVersion) ||
        json_string(json, "sourceRevision", identity->sourceRevision, sizeof(identity->sourceRevision)) != 0 ||
        !valid_revision(identity->sourceRevision) ||
        json_string(json, "runtimeEpoch", identity->runtimeEpoch, sizeof(identity->runtimeEpoch)) != 0 || !valid_uuid(identity->runtimeEpoch) ||
        json_string(json, "channel", identity->channel, sizeof(identity->channel)) != 0 ||
        json_string(json, "version", identity->version, sizeof(identity->version)) != 0 ||
        json_string(json, "payloadFingerprint", identity->fingerprint, sizeof(identity->fingerprint)) != 0 ||
        !valid_component(identity->channel, 64) || !valid_component(identity->version, 128) ||
        !valid_fingerprint(identity->fingerprint)) return -1;
    return 0;
}

static int valid_public_push_host(const char *host) {
    size_t length = strlen(host);
    if (length == 0 || length > 253 || host[0] == '.' || host[length - 1] == '.' || strchr(host, '.') == NULL || strstr(host, "..") != NULL) return 0;
    int onlyNumbersAndDots = 1;
    const char *label = host;
    for (size_t index = 0; index <= length; ++index) {
        unsigned char character = (unsigned char)host[index];
        if (character != '\0' && character != '.' && !((character >= 'a' && character <= 'z') ||
            (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '-')) return 0;
        if (character != '\0' && character != '.' && !(character >= '0' && character <= '9')) onlyNumbersAndDots = 0;
        if (character == '.' || character == '\0') {
            size_t labelLength = (size_t)(&host[index] - label);
            if (labelLength == 0 || labelLength > 63 || label[0] == '-' || label[labelLength - 1] == '-') return 0;
            label = &host[index + 1];
        }
    }
    if (onlyNumbersAndDots) return 0;
    char lower[254];
    for (size_t index = 0; index <= length; ++index) lower[index] = (char)tolower((unsigned char)host[index]);
    size_t lowerLength = strlen(lower);
    const char *blocked[] = {"localhost", ".localhost", ".local", ".internal"};
    if (strcmp(lower, blocked[0]) == 0) return 0;
    for (size_t index = 1; index < sizeof(blocked) / sizeof(blocked[0]); ++index) {
        size_t suffixLength = strlen(blocked[index]);
        if (lowerLength >= suffixLength && strcmp(lower + lowerLength - suffixLength, blocked[index]) == 0) return 0;
    }
    return 1;
}

static int validate_push_config(const char *root, const char *channel) {
    char path[PATH_MAX], text[MAX_PUSH_CONFIG_BYTES + 1];
    if (snprintf(path, sizeof(path), "%s/app/PushService.xcconfig", root) >= (int)sizeof(path) ||
        bounded_file(path, text, sizeof(text)) != 0) return -1;
    const char *key = "TRON_PUSH_SERVICE_ORIGIN";
    const size_t keyLength = strlen(key);
    char origin[512] = {0};
    int assignments = 0;
    char *cursor = text;
    while (*cursor != '\0') {
        char *end = strchr(cursor, '\n');
        if (end == NULL) end = cursor + strlen(cursor);
        char *start = cursor;
        while (start < end && (*start == ' ' || *start == '\t')) start++;
        if ((size_t)(end - start) >= keyLength && strncmp(start, key, keyLength) == 0) {
            char *value = start + keyLength;
            while (value < end && (*value == ' ' || *value == '\t')) value++;
            if (value < end && *value == '=') {
                value++;
                while (value < end && (*value == ' ' || *value == '\t')) value++;
                char *valueEnd = end;
                while (valueEnd > value && (valueEnd[-1] == ' ' || valueEnd[-1] == '\t' || valueEnd[-1] == '\r')) valueEnd--;
                size_t valueLength = (size_t)(valueEnd - value);
                if (++assignments > 1 || valueLength >= sizeof(origin)) return -1;
                memcpy(origin, value, valueLength);
                origin[valueLength] = '\0';
            }
        }
        cursor = *end == '\0' ? end : end + 1;
    }
    if (assignments != 1) return -1;
    if (origin[0] == '\0') return strcmp(channel, "dev") == 0 ? 0 : -1;
    const char *prefix = "https:/$()/";
    return strncmp(origin, prefix, strlen(prefix)) == 0 && valid_public_push_host(origin + strlen(prefix)) ? 0 : -1;
}

static int validate_payload(const char *payload, const char *expectedChannel, const char *expectedVersion,
                            const char *expectedFingerprint, char *node, char *entrypoint, char *helper,
                            PayloadIdentity *selectedIdentity) {
    char root[PATH_MAX];
    PayloadIdentity identity;
    struct stat payloadInfo;
    if (lstat(payload, &payloadInfo) != 0 || !S_ISDIR(payloadInfo.st_mode) ||
        realpath(payload, root) == NULL || immutable_tree(root, root) != 0 || read_payload_manifest(root, &identity) != 0) return -1;
    struct stat appRoot, runtimeRoot;
    char appPath[PATH_MAX], runtimePath[PATH_MAX];
    if (snprintf(appPath, sizeof(appPath), "%s/app", root) >= (int)sizeof(appPath) ||
        snprintf(runtimePath, sizeof(runtimePath), "%s/runtime", root) >= (int)sizeof(runtimePath) ||
        lstat(appPath, &appRoot) != 0 || !S_ISDIR(appRoot.st_mode) ||
        lstat(runtimePath, &runtimeRoot) != 0 || !S_ISDIR(runtimeRoot.st_mode)) return -1;
    if ((expectedChannel != NULL && strcmp(expectedChannel, identity.channel) != 0) ||
        (expectedVersion != NULL && strcmp(expectedVersion, identity.version) != 0) ||
        (expectedFingerprint != NULL && strcmp(expectedFingerprint, identity.fingerprint) != 0)) return -1;
    if (required_path(root, "app/dist/index.js", entrypoint, PATH_MAX, 0, 1024, 0) != 0 ||
        required_path(root, "app/package.json", node, PATH_MAX, 0, 1, 0) != 0 ||
        required_path(root, "app/package-lock.json", node, PATH_MAX, 0, 1, 0) != 0 ||
        required_path(root, "app/PushService.xcconfig", node, PATH_MAX, 0, 1, 0) != 0 ||
        validate_push_config(root, identity.channel) != 0 ||
        required_path(root, "app/scripts/ensure-node-pty-helper.mjs", node, PATH_MAX, 0, 1, 0) != 0 ||
        required_path(root, "app/scripts/gateway-payload-deploy.mjs", helper, PATH_MAX, 0, 1, 0) != 0 ||
        required_path(root, "app/node_modules", node, PATH_MAX, 0, 0, 1) != 0 ||
        required_path(root, "runtime/xcodegen/bin/xcodegen", node, PATH_MAX, 1, 1024 * 1024, 0) != 0 ||
        required_path(root, "runtime/xcodegen/share/xcodegen/SettingPresets/base.yml", node, PATH_MAX, 0, 1, 0) != 0) return -1;
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
            required_path(root, requiredRuntime, node, PATH_MAX, 1, 1024 * 1024, 0) != 0 ||
            required_runtime_alias(root, architectures[index]) != 0 ||
            required_pi_alias(root, architectures[index]) != 0) return -1;
    }
    if (snprintf(runtimeRelative, sizeof(runtimeRelative), "runtime/%s", runtimeName) >= (int)sizeof(runtimeRelative)) return -1;
    char actualFingerprint[65];
    if (payload_fingerprint(root, actualFingerprint) != 0 || strcmp(actualFingerprint, identity.fingerprint) != 0) return -1;
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

static int read_selection(const char *path, const char *channel, char *version, size_t versionCapacity,
                          char *fingerprint, size_t fingerprintCapacity) {
    char selection[MAX_MANIFEST_BYTES + 1], kind[64], selectedChannel[64];
    const char *keys[] = {"schema", "kind", "channel", "version", "payloadFingerprint"};
    if (bounded_file(path, selection, sizeof(selection)) != 0 || json_schema_one(selection) != 0) return -1;
    for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); ++index) {
        if (json_key_count(selection, keys[index]) != 1) return -1;
    }
    if (json_string(selection, "kind", kind, sizeof(kind)) != 0 || strcmp(kind, "tron-gateway-selection") != 0 ||
        json_string(selection, "channel", selectedChannel, sizeof(selectedChannel)) != 0 ||
        json_string(selection, "version", version, versionCapacity) != 0 ||
        json_string(selection, "payloadFingerprint", fingerprint, fingerprintCapacity) != 0 ||
        strcmp(selectedChannel, channel) != 0 || !valid_component(version, MAX_COMPONENT_BYTES) ||
        !valid_fingerprint(fingerprint)) return -1;
    return 0;
}

static int recover_pending_attempt_unlocked(const char *channelRoot, const char *channel) {
    char markerPath[PATH_MAX], marker[MAX_MANIFEST_BYTES + 1];
    if (snprintf(markerPath, sizeof(markerPath), "%s/pending-attempt.json", channelRoot) >= (int)sizeof(markerPath)) return -1;
    if (bounded_file(markerPath, marker, sizeof(marker)) != 0) {
        return access(markerPath, F_OK) != 0 && errno == ENOENT ? 0 : -1;
    }
    const char *keys[] = {"schema", "kind", "channel", "attempt", "version", "payloadFingerprint", "previousVersion", "previousFingerprint"};
    for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); ++index) {
        if (json_key_count(marker, keys[index]) != 1) return -1;
    }
    char kind[64], markerChannel[64], attempt[32], candidateVersion[MAX_COMPONENT_BYTES], candidateFingerprint[65];
    char previousVersion[MAX_COMPONENT_BYTES], previousFingerprint[65];
    if (json_schema_one(marker) != 0 || json_string(marker, "kind", kind, sizeof(kind)) != 0 ||
        strcmp(kind, "tron-gateway-pending-attempt") != 0 || json_string(marker, "channel", markerChannel, sizeof(markerChannel)) != 0 ||
        strcmp(markerChannel, channel) != 0 || json_string(marker, "attempt", attempt, sizeof(attempt)) != 0 ||
        (strcmp(attempt, "pending") != 0 && strcmp(attempt, "launched") != 0 && strcmp(attempt, "committed") != 0) ||
        json_string(marker, "version", candidateVersion, sizeof(candidateVersion)) != 0 ||
        json_string(marker, "payloadFingerprint", candidateFingerprint, sizeof(candidateFingerprint)) != 0 ||
        json_string(marker, "previousVersion", previousVersion, sizeof(previousVersion)) != 0 ||
        json_string(marker, "previousFingerprint", previousFingerprint, sizeof(previousFingerprint)) != 0 ||
        !valid_component(candidateVersion, MAX_COMPONENT_BYTES - 1) || !valid_component(previousVersion, MAX_COMPONENT_BYTES - 1) ||
        !valid_fingerprint(candidateFingerprint) || !valid_fingerprint(previousFingerprint)) return -1;
    char currentPath[PATH_MAX], currentVersion[MAX_COMPONENT_BYTES], currentFingerprint[65];
    if (snprintf(currentPath, sizeof(currentPath), "%s/current.json", channelRoot) >= (int)sizeof(currentPath)
        || read_selection(currentPath, channel, currentVersion, sizeof(currentVersion), currentFingerprint, sizeof(currentFingerprint)) != 0
        || strcmp(currentVersion, candidateVersion) != 0 || strcmp(currentFingerprint, candidateFingerprint) != 0) return -1;

    // A committed candidate was authenticated and selected by the helper.
    // Removing the marker under the shared lock makes relaunch idempotent.
    if (strcmp(attempt, "committed") == 0) {
        if (unlink(markerPath) != 0 && errno != ENOENT) return -1;
        return 0;
    }

    // The candidate gets exactly one launch. Atomically consume that attempt;
    // only a subsequent launcher invocation while the helper has not committed
    // the marker is evidence that startup failed and requires rollback.
    if (strcmp(attempt, "pending") == 0) {
        char temporary[PATH_MAX], launched[1024];
        if (snprintf(temporary, sizeof(temporary), "%s.tmp-attempt-%ld", markerPath, (long)getpid()) >= (int)sizeof(temporary)) return -1;
        int length = snprintf(launched, sizeof(launched),
            "{\"schema\":1,\"kind\":\"tron-gateway-pending-attempt\",\"channel\":\"%s\",\"attempt\":\"launched\",\"version\":\"%s\",\"payloadFingerprint\":\"%s\",\"previousVersion\":\"%s\",\"previousFingerprint\":\"%s\"}\n",
            channel, candidateVersion, candidateFingerprint, previousVersion, previousFingerprint);
        int fd = length > 0 && length < (int)sizeof(launched)
            ? open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) : -1;
        int written = fd >= 0 && write(fd, launched, (size_t)length) == length && fsync(fd) == 0;
        if (fd >= 0 && close(fd) != 0) written = 0;
        if (!written || rename(temporary, markerPath) != 0) { unlink(temporary); return -1; }
        return 0;
    }

    char previousPath[PATH_MAX], node[PATH_MAX], entrypoint[PATH_MAX], helper[PATH_MAX];
    PayloadIdentity previousIdentity;
    if (snprintf(previousPath, sizeof(previousPath), "%s/versions/%s", channelRoot, previousVersion) >= (int)sizeof(previousPath)
        || validate_payload(previousPath, channel, previousVersion, previousFingerprint, node, entrypoint, helper, &previousIdentity) != 0) return -1;
    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof(temporary), "%s.tmp-recovery-%ld", currentPath, (long)getpid()) >= (int)sizeof(temporary)) return -1;
    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    char selection[512];
    int length = snprintf(selection, sizeof(selection), "{\"schema\":1,\"kind\":\"tron-gateway-selection\",\"channel\":\"%s\",\"version\":\"%s\",\"payloadFingerprint\":\"%s\"}\n", channel, previousVersion, previousFingerprint);
    int result = length > 0 && length < (int)sizeof(selection) && write(fd, selection, (size_t)length) == length;
    if (close(fd) != 0) result = 0;
    if (!result || rename(temporary, currentPath) != 0) { unlink(temporary); return -1; }
    if (unlink(markerPath) != 0 && errno != ENOENT) return -1;
    return 1;
}

static int recover_pending_attempt(const char *channelRoot, const char *channel) {
    char markerPath[PATH_MAX], lockPath[PATH_MAX];
    if (snprintf(markerPath, sizeof(markerPath), "%s/pending-attempt.json", channelRoot) >= (int)sizeof(markerPath)
        || access(markerPath, F_OK) != 0
        || snprintf(lockPath, sizeof(lockPath), "%s.lock", markerPath) >= (int)sizeof(lockPath)) return 0;
    int observedFreshLock = 0;
    for (int attempt = 0; attempt < 200; ++attempt) {
        if (mkdir(lockPath, 0700) == 0) {
            int result = recover_pending_attempt_unlocked(channelRoot, channel);
            (void)rmdir(lockPath);
            return result;
        }
        if (errno != EEXIST) return -1;
        struct stat info;
        if (stat(lockPath, &info) == 0) {
            if (!observedFreshLock && time(NULL) - info.st_mtime > 30) {
                (void)rmdir(lockPath);
                continue;
            }
            // A lock observed fresh on entry never becomes removable by this
            // waiter merely because a loaded host stretches the bounded loop.
            observedFreshLock = 1;
        }
        struct timespec delay = { .tv_sec = 0, .tv_nsec = 25000000 };
        (void)nanosleep(&delay, NULL);
    }
    // A pending candidate is not admissible without exclusive ownership of
    // its attempt marker. Exit and let the supervisor retry; a later launch
    // can remove a stale lock and run the existing rollback/commit recovery.
    return -1;
}

/* Return 1 only when the external store/channel is genuinely absent. Any
 * existing but symlinked or malformed root is unsafe and must not fall back. */
static int admit_channel_root(const char *home, const char *channel, char *admittedRoot) {
    char gatewayPath[PATH_MAX], payloadsPath[PATH_MAX], payloadsRoot[PATH_MAX], channelPath[PATH_MAX];
    if (!valid_component(channel, 64) ||
        snprintf(gatewayPath, sizeof(gatewayPath), "%s/gateway", home) >= (int)sizeof(gatewayPath) ||
        snprintf(payloadsPath, sizeof(payloadsPath), "%s/payloads", gatewayPath) >= (int)sizeof(payloadsPath)) return -1;
    struct stat info;
    if (lstat(gatewayPath, &info) != 0) return errno == ENOENT ? 1 : -1;
    if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode)) return -1;
    if (lstat(payloadsPath, &info) != 0) return errno == ENOENT ? 1 : -1;
    if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode) || realpath(payloadsPath, payloadsRoot) == NULL) return -1;
    if (snprintf(channelPath, sizeof(channelPath), "%s/%s", payloadsRoot, channel) >= (int)sizeof(channelPath)) return -1;
    if (lstat(channelPath, &info) != 0) return errno == ENOENT ? 1 : -1;
    if (!S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode) || realpath(channelPath, admittedRoot) == NULL ||
        !path_is_under(payloadsRoot, admittedRoot)) return -1;
    char versionsPath[PATH_MAX];
    if (snprintf(versionsPath, sizeof(versionsPath), "%s/versions", admittedRoot) >= (int)sizeof(versionsPath) ||
        !regular_directory_path(versionsPath)) return -1;
    return 0;
}

static int external_payload(const char *channelRoot, const char *channel, char *node, char *entrypoint, char *helper, char *selectedRoot, PayloadIdentity *selectedIdentity) {
    char versionsPath[PATH_MAX], versionsRoot[PATH_MAX], currentPath[PATH_MAX];
    char selection[MAX_MANIFEST_BYTES + 1], version[128], fingerprint[65], selectedChannel[64];
    if (snprintf(versionsPath, sizeof(versionsPath), "%s/versions", channelRoot) >= (int)sizeof(versionsPath) ||
        !regular_directory_path(versionsPath) || realpath(versionsPath, versionsRoot) == NULL || !path_is_under(channelRoot, versionsRoot) ||
        snprintf(currentPath, sizeof(currentPath), "%s/current.json", channelRoot) >= (int)sizeof(currentPath) ||
        bounded_file(currentPath, selection, sizeof(selection)) != 0 || json_schema_one(selection) != 0) return -1;
    const char *selectionKeys[] = {"schema", "kind", "channel", "version", "payloadFingerprint"};
    for (size_t index = 0; index < sizeof(selectionKeys) / sizeof(selectionKeys[0]); ++index) {
        if (json_key_count(selection, selectionKeys[index]) != 1) return -1;
    }
    char kind[64];
    if (json_string(selection, "kind", kind, sizeof(kind)) != 0 || strcmp(kind, "tron-gateway-selection") != 0 ||
        json_string(selection, "channel", selectedChannel, sizeof(selectedChannel)) != 0 ||
        json_string(selection, "version", version, sizeof(version)) != 0 ||
        json_string(selection, "payloadFingerprint", fingerprint, sizeof(fingerprint)) != 0 ||
        strcmp(selectedChannel, channel) != 0 || !valid_component(version, 128) || !valid_fingerprint(fingerprint)) return -1;
    char payload[PATH_MAX], payloadRoot[PATH_MAX];
    if (snprintf(payload, sizeof(payload), "%s/%s", versionsRoot, version) >= (int)sizeof(payload) ||
        realpath(payload, payloadRoot) == NULL || !path_is_under(versionsRoot, payloadRoot) ||
        snprintf(selectedRoot, PATH_MAX, "%s", payloadRoot) >= PATH_MAX) return -1;
    return validate_payload(payloadRoot, channel, version, fingerprint, node, entrypoint, helper, selectedIdentity);
}

int main(int argc, char **argv) {
    // Build verification compiles this source afresh and uses this mode rather
    // than trusting the staged helper. It validates the bounded manifest,
    // immutable payload tree, required entries, and canonical fingerprint.
    if (argc == 7 && strcmp(argv[1], "--verify-payload") == 0 &&
        (strcmp(argv[3], "stable") == 0 || strcmp(argv[3], "dev") == 0)) {
        PayloadIdentity identity;
        char node[PATH_MAX], entrypoint[PATH_MAX], helper[PATH_MAX];
        if (validate_payload(argv[2], argv[3], NULL, NULL, node, entrypoint, helper, &identity) != 0 ||
            strcmp(identity.nodeVersion, argv[4]) != 0 || strcmp(identity.gatewayVersion, argv[5]) != 0 ||
            strcmp(identity.version, argv[5]) != 0 || strcmp(identity.sourceRevision, argv[6]) != 0) {
            fputs("Tron Gateway payload verification failed.\n", stderr);
            return 78;
        }
        return 0;
    }

    // Build and verification tooling may ask the already-built trusted helper
    // to hash an arbitrary payload. This avoids the process-per-file shell
    // implementation on large production dependency trees.
    if (argc == 3 && strcmp(argv[1], "--fingerprint") == 0) {
        struct stat rootInfo;
        char root[PATH_MAX], fingerprint[65];
        if (lstat(argv[2], &rootInfo) != 0 || !S_ISDIR(rootInfo.st_mode) || S_ISLNK(rootInfo.st_mode) ||
            realpath(argv[2], root) == NULL || payload_fingerprint(root, fingerprint) != 0) {
            fputs("Tron could not fingerprint the requested Gateway payload.\n", stderr);
            return 78;
        }
        printf("%s\n", fingerprint);
        return 0;
    }

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
    char selectedPayloadRoot[PATH_MAX];
    const char *channel = getenv("TRON_GATEWAY_CHANNEL");
    if (channel == NULL || channel[0] == '\0') channel = "stable";
    /* Only the two shipped channels are admitted. Validate before any
     * channel-derived marker, lock, or selection path is touched. */
    if (strcmp(channel, "stable") != 0 && strcmp(channel, "dev") != 0) {
        fprintf(stderr, "Invalid TRON_GATEWAY_CHANNEL.\n");
        return 78;
    }
    char admittedChannelRoot[PATH_MAX];
    int externalState = selected_home(home, sizeof(home)) == 0
        ? admit_channel_root(home, channel, admittedChannelRoot)
        : 1;
    if (externalState < 0) {
        fprintf(stderr, "Tron Gateway external payload store is unsafe or invalid.\n");
        return 78;
    }
    int external = 0;
    if (externalState == 0) {
        if (recover_pending_attempt(admittedChannelRoot, channel) < 0) {
            fprintf(stderr, "Tron Gateway candidate attempt is locked; retrying without launching an uncommitted payload.\n");
            return 75;
        }
        external = external_payload(admittedChannelRoot, channel, node, entrypoint, helper, selectedPayloadRoot, &selectedIdentity) == 0;
        if (!external) {
            // The external root was safely admitted, but its current selection
            // or payload no longer validates. Never execute it; retain the
            // trusted bundled payload as the bounded resilience fallback.
            fprintf(stderr, "Tron Gateway external payload selection is invalid; using bundled payload.\n");
        }
    }
    if (!external && snprintf(selectedPayloadRoot, sizeof(selectedPayloadRoot), "%s", bundledRoot) >= (int)sizeof(selectedPayloadRoot)) return 70;
    if (!external && validate_payload(bundledRoot, NULL, NULL, NULL, node, entrypoint, helper, &selectedIdentity) != 0) {
        fprintf(stderr, "Tron Gateway payload is incomplete or invalid at %s. Reinstall Tron.\n", bundledRoot);
        return 78;
    }
    if (setenv("TRON_GATEWAY_SOURCE_REVISION", selectedIdentity.sourceRevision, 1) != 0 ||
        setenv("TRON_GATEWAY_PAYLOAD_VERSION", selectedIdentity.version, 1) != 0 ||
        setenv("TRON_GATEWAY_BUILD_FINGERPRINT", selectedIdentity.fingerprint, 1) != 0 ||
        setenv("TRON_GATEWAY_RUNTIME_EPOCH", selectedIdentity.runtimeEpoch, 1) != 0 ||
        setenv("TRON_GATEWAY_PAYLOAD_ROOT", selectedPayloadRoot, 1) != 0 ||
        setenv("TRON_GATEWAY_BUNDLED_PAYLOAD_ROOT", bundledRoot, 1) != 0 ||
        setenv("TRON_GATEWAY_SUPERVISED", "1", 1) != 0 ||
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
