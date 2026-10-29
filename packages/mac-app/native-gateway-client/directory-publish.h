#pragma once
#include <node_api.h>

// Only publishes a private staged directory into a pinned destination parent.
// This is NOT conditional removal, replacement or restore authority.
napi_value publishDirectoryExclusive(napi_env env, napi_callback_info info);
