#pragma once
#include <node_api.h>

// Publishes a private staged directory into a pinned destination parent, or
// replaces only app.json from a private stage into a pinned entry directory.
// Neither provides conditional directory removal/replacement/restore authority.
napi_value publishDirectoryExclusive(napi_env env, napi_callback_info info);
napi_value replaceAppManifest(napi_env env, napi_callback_info info);
