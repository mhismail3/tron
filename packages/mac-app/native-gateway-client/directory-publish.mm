#include "directory-publish.h"
#include <sys/stat.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <cerrno>
#include <cstring>
#include <cmath>
#include <climits>
#include <memory>
#include <stdexcept>
#include <string>

namespace {
void check(napi_status status) { if (status != napi_ok) throw std::runtime_error("Directory publication Node-API failure"); }
struct Publication {
    int source = -1, destination = -1, error = 0;
    std::string sourceName, destinationName;
    napi_ref callback = nullptr;
    napi_async_work work = nullptr;
    ~Publication() { if (source >= 0) close(source); if (destination >= 0) close(destination); }
};
int pin(napi_env env, napi_value value) {
    double descriptor;
    check(napi_get_value_double(env, value, &descriptor));
    if (!std::isfinite(descriptor) || descriptor < 0 || descriptor > INT_MAX || std::trunc(descriptor) != descriptor)
        throw std::runtime_error("Publication requires directory descriptors");
    int pinned = fcntl(static_cast<int>(descriptor), F_DUPFD_CLOEXEC, 0);
    if (pinned < 0) throw std::runtime_error("Could not pin publication directory");
    struct stat info;
    if (fstat(pinned, &info) || !S_ISDIR(info.st_mode)) {
        close(pinned); throw std::runtime_error("Publication parent is not a directory");
    }
    return pinned;
}
std::string leaf(napi_env env, napi_value value) {
    size_t length = 0;
    check(napi_get_value_string_utf8(env, value, nullptr, 0, &length));
    if (!length || length > 255) throw std::runtime_error("Publication requires bounded leaf names");
    char bytes[256]; size_t read = 0;
    check(napi_get_value_string_utf8(env, value, bytes, sizeof(bytes), &read));
    std::string result(bytes, read);
    if (read != length || result.find('\0') != std::string::npos || result.find('/') != std::string::npos || result == "." || result == "..")
        throw std::runtime_error("Publication requires leaf names, not paths");
    return result;
}
void execute(napi_env, void *data) {
    auto &operation = *static_cast<Publication *>(data);
    struct stat info;
    if (fstatat(operation.source, operation.sourceName.c_str(), &info, AT_SYMLINK_NOFOLLOW)) { operation.error = errno; return; }
    // The caller owns the private staging namespace. This is deliberately not
    // an expected-inode move of an externally editable directory (see #2109).
    if (!S_ISDIR(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 0777) != 0700) { operation.error = EINVAL; return; }
    if (renameatx_np(operation.source, operation.sourceName.c_str(), operation.destination, operation.destinationName.c_str(), RENAME_EXCL))
        operation.error = errno;
}
void complete(napi_env env, napi_status status, void *data) {
    std::unique_ptr<Publication> operation(static_cast<Publication *>(data));
    napi_value callback, receiver, args[2];
    if (status != napi_ok && !operation->error) operation->error = ECANCELED;
    if (napi_get_reference_value(env, operation->callback, &callback) == napi_ok && napi_get_undefined(env, &receiver) == napi_ok) {
        const bool exists = operation->error == EEXIST || operation->error == ENOTEMPTY;
        bool ready;
        if (!operation->error || exists) {
            ready = napi_get_null(env, &args[0]) == napi_ok && napi_get_boolean(env, !exists, &args[1]) == napi_ok;
        } else {
            napi_value message, code;
            ready = napi_create_string_utf8(env, strerror(operation->error), NAPI_AUTO_LENGTH, &message) == napi_ok
                && napi_create_error(env, nullptr, message, &args[0]) == napi_ok
                && napi_create_int32(env, operation->error, &code) == napi_ok
                && napi_set_named_property(env, args[0], "errno", code) == napi_ok
                && napi_get_undefined(env, &args[1]) == napi_ok;
        }
        // Allocation refusal or environment teardown must not pass uninitialized
        // handles to JS. Native resources still retire on every completion path.
        if (ready) { napi_value ignored; (void)napi_call_function(env, receiver, callback, 2, args, &ignored); }
    }
    (void)napi_delete_reference(env, operation->callback);
    (void)napi_delete_async_work(env, operation->work);
}
}

napi_value publishDirectoryExclusive(napi_env env, napi_callback_info info) {
    std::unique_ptr<Publication> operation;
    try {
        operation = std::make_unique<Publication>();
        napi_value args[6], receiver; size_t count = 6;
        check(napi_get_cb_info(env, info, &count, args, &receiver, nullptr));
        if (count != 5) throw std::runtime_error("Publication requires two parent descriptors, two leaf names and a callback");
        operation->source = pin(env, args[0]); operation->sourceName = leaf(env, args[1]);
        operation->destination = pin(env, args[2]); operation->destinationName = leaf(env, args[3]);
        napi_valuetype type; check(napi_typeof(env, args[4], &type));
        if (type != napi_function) throw std::runtime_error("Publication requires a callback");
        check(napi_create_reference(env, args[4], 1, &operation->callback));
        napi_value name; check(napi_create_string_utf8(env, "tron.directory.publish", NAPI_AUTO_LENGTH, &name));
        check(napi_create_async_work(env, nullptr, name, execute, complete, operation.get(), &operation->work));
        check(napi_queue_async_work(env, operation->work));
        operation.release(); napi_value result; check(napi_get_undefined(env, &result)); return result;
    } catch (const std::exception &error) {
        if (operation) {
            if (operation->callback) (void)napi_delete_reference(env, operation->callback);
            if (operation->work) (void)napi_delete_async_work(env, operation->work);
        }
        bool pending = false; (void)napi_is_exception_pending(env, &pending);
        if (!pending) (void)napi_throw_error(env, nullptr, error.what());
        return nullptr;
    }
}
