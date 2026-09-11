#define NAPI_VERSION 8
#include <node_api.h>
#include "transport.h"
#include <array>
#include <atomic>
#include <limits>
#include <mutex>
#include <stdexcept>

namespace capture {
constexpr size_t OrdinarySlots = 4, StopSlot = 4, SlotCount = 5, QueueCapacity = 6;
#ifdef TRON_CAPTURE_TEST
static std::atomic<unsigned> owners{0}, payloads{0}, hooks{0}, queues{0}, references{0};
#endif
static void check(napi_status s) { if (s != napi_ok) throw std::runtime_error("native capture Node-API failure"); }
static napi_value undef(napi_env e) { napi_value v; check(napi_get_undefined(e, &v)); return v; }
static napi_value nilValue(napi_env e) { napi_value v; check(napi_get_null(e, &v)); return v; }
static napi_ref retain(napi_env e, napi_value v) {
    napi_ref r; check(napi_create_reference(e, v, 1, &r));
#ifdef TRON_CAPTURE_TEST
    ++references;
#endif
    return r;
}
static void drop(napi_env e, napi_ref &r) {
    if (!r) return;
    auto old = r; r = nullptr;
    // Reference disposal does not execute JS and is valid during env cleanup.
    check(napi_delete_reference(e, old));
#ifdef TRON_CAPTURE_TEST
    --references;
#endif
}
static void throwCurrent(napi_env e, const std::exception &error) {
    bool pending = false;
    if (napi_is_exception_pending(e, &pending) == napi_ok && !pending)
        (void)napi_throw_error(e, nullptr, error.what());
}
struct State;
struct Environment { std::array<std::weak_ptr<State>, 4> clients; };
struct Slot { uint64_t ticket = 0; napi_ref callback = nullptr; bool queued = false, pull = false; };
struct Payload {
    std::shared_ptr<State> state;
    size_t slot;
    uint64_t ticket;
    NSData *control;
    NSData *jpeg;
    Payload(std::shared_ptr<State>, size_t, uint64_t, NSData *, NSData *);
    ~Payload();
};
struct State : std::enable_shared_from_this<State> {
    std::mutex mutex;
    std::array<Slot, SlotCount> slots{};
    std::shared_ptr<Transport> transport;
    napi_env env;
    napi_threadsafe_function queue = nullptr;
    napi_async_cleanup_hook_handle hook = nullptr;
    std::shared_ptr<State> *hookContext = nullptr;
    napi_ref object = nullptr, failure = nullptr, closed = nullptr;
    uint64_t nextTicket = 1;
    std::atomic<unsigned> payloadCount{0};
    bool sealed = false, terminalQueued = false, cleaning = false, finalizerPending = false;
    std::atomic<unsigned> fault{0};
    explicit State(napi_env e) : env(e) {
#ifdef TRON_CAPTURE_TEST
        ++owners;
#endif
    }
    ~State() {
#ifdef TRON_CAPTURE_TEST
        --owners;
#endif
    }
    bool inject(unsigned point) {
#ifdef TRON_CAPTURE_TEST
        unsigned expected = point;
        if (fault.compare_exchange_strong(expected, 0)) return true;
#else
        (void)point;
#endif
        return false;
    }
    napi_value failureValue() { napi_value v; check(napi_get_reference_value(env, failure, &v)); return v; }
    // Node-loop only. Accepted work, unlike idle catalogs, owns loop liveness.
    void referenceLoop(bool on) {
        napi_threadsafe_function q;
        { std::lock_guard lock(mutex); q = queue; }
        if (q) check(on ? napi_ref_threadsafe_function(env, q) : napi_unref_threadsafe_function(env, q));
    }
    void updateLiveness() {
        bool pending = false;
        { std::lock_guard lock(mutex); for (const auto &slot : slots) pending |= slot.callback != nullptr; }
        referenceLoop(pending || closed != nullptr);
    }
    void terminalLocked() {
        if (sealed || terminalQueued || !queue) return;
        terminalQueued = true;
        // NULL is the pre-reserved terminal notification: no Payload/NSData
        // allocation is needed when an ordinary native reply allocation fails.
        auto result = napi_call_threadsafe_function(queue, nullptr, napi_tsfn_nonblocking);
        if (result != napi_ok) {
            // A full queue already owns a delivery which will observe terminal.
            if (result == napi_closing) { queue = nullptr; sealed = true; }
            else if (result != napi_queue_full) std::terminate();
        }
    }
    void lost() { std::lock_guard lock(mutex); terminalLocked(); }
    void reply(size_t index, uint64_t ticket, NSData *control, NSData *jpeg) {
        @autoreleasepool { try {
            std::lock_guard lock(mutex);
            auto &slot = slots[index];
            if (sealed || terminalQueued || slot.ticket != ticket || slot.queued) return;
            if (![control isKindOfClass:NSData.class] || !control.length || control.length > ControlLimit ||
                (jpeg && (![jpeg isKindOfClass:NSData.class] || !jpeg.length || jpeg.length > JPEGLimit))) {
                terminalLocked(); return;
            }
            if (inject(2)) throw std::bad_alloc(); // actual native allocation edge
            auto p = std::make_unique<Payload>(shared_from_this(), index, ticket,
                [NSData dataWithBytes:control.bytes length:control.length],
                jpeg ? [NSData dataWithBytes:jpeg.bytes length:jpeg.length] : nil);
            slot.queued = true;
            auto result = napi_call_threadsafe_function(queue, p.get(), napi_tsfn_nonblocking);
            if (result == napi_ok) p.release();
            else {
                if (result == napi_closing) { queue = nullptr; sealed = true; }
                else terminalLocked();
            }
        } catch (...) {
            // Never unwind a C++ allocation failure into an NSXPC/GCD callback.
            std::lock_guard lock(mutex);
            terminalLocked();
        } }
    }
    void retire() {
        napi_threadsafe_function q;
        std::shared_ptr<Transport> peer;
        { std::lock_guard lock(mutex); sealed = true; q = queue; queue = nullptr; peer = std::move(transport); }
        if (peer) peer->invalidate();
        if (q) {
            // Ref BEFORE release: an unref'd async handle need not dispatch its
            // close/finalizer before Node decides that its loop is finished.
            if (!cleaning) check(napi_ref_threadsafe_function(env, q));
            check(napi_release_threadsafe_function(q, cleaning ? napi_tsfn_abort : napi_tsfn_release));
        }
    }
    napi_ref consume(size_t index) {
        std::lock_guard lock(mutex);
        auto cb = slots[index].callback; slots[index] = {}; return cb;
    }
    napi_status invoke(napi_ref &ref, napi_value error, napi_value value) {
        napi_value cb;
        auto s = napi_get_reference_value(env, ref, &cb);
        // The local handle, not an opaque deferred, keeps cb alive for this call.
        drop(env, ref);
        if (s != napi_ok) return s;
        napi_value args[] = {error, value}, ignored;
        return napi_call_function(env, undef(env), cb, 2, args, &ignored);
    }
    void discardReferences() {
        for (size_t i = 0; i < SlotCount; ++i) { auto cb = consume(i); drop(env, cb); }
        drop(env, closed); drop(env, failure); drop(env, object);
    }
    napi_value failPending() {
        if (!failure) return nullptr; // Already finalized: no callbacks remain.
        auto reason = failureValue();
        napi_value firstException = nullptr;
        for (size_t i = 0; i < SlotCount; ++i) {
            auto cb = consume(i);
            if (cb && invoke(cb, reason, undef(env)) != napi_ok) {
                bool pending = false;
                if (napi_is_exception_pending(env, &pending) == napi_ok && pending) {
                    napi_value thrown;
                    check(napi_get_and_clear_last_exception(env, &thrown));
                    if (!firstException) firstException = thrown;
                }
            }
        }
        return firstException;
    }
};
Payload::Payload(std::shared_ptr<State> s, size_t i, uint64_t t, NSData *c, NSData *j)
    : state(std::move(s)), slot(i), ticket(t), control(c), jpeg(j) {
    ++state->payloadCount;
#ifdef TRON_CAPTURE_TEST
    ++payloads;
#endif
}
Payload::~Payload() {
    --state->payloadCount;
#ifdef TRON_CAPTURE_TEST
    --payloads;
#endif
}
static void cleanup(napi_async_cleanup_hook_handle, void *data) {
    auto state = *static_cast<std::shared_ptr<State> *>(data);
    state->cleaning = true;
    state->retire();
    state->discardReferences();
}
static void finalized(napi_env env, void *data, void *) {
    std::unique_ptr<std::shared_ptr<State>> context(static_cast<std::shared_ptr<State> *>(data));
    auto state = *context;
    state->retire();
    state->finalizerPending = false;
#ifdef TRON_CAPTURE_TEST
    --queues;
#endif
    // Forced exit may finalize an already-closing handle BEFORE cleanup hooks.
    // A callback may be refused by Node; there is no opaque Promise handle to
    // leak/retry. Reference disposal remains valid without executing JavaScript.
    if (env && state->closed && !state->cleaning) {
        auto cb = state->closed; state->closed = nullptr;
        (void)state->invoke(cb, nilValue(env), undef(env));
    }
    state->discardReferences();
    if (state->hook) {
        auto hook = state->hook; state->hook = nullptr;
        check(napi_remove_async_cleanup_hook(hook));
        delete state->hookContext; state->hookContext = nullptr;
#ifdef TRON_CAPTURE_TEST
        --hooks;
#endif
    }
    // Node may drain aborted queued payloads after this finalizer with NULL env.
    // Those payloads own State themselves and never access this freed context.
}
static void callJS(napi_env env, napi_value, void *context, void *data) {
    std::unique_ptr<Payload> p(static_cast<Payload *>(data));
    if (!env) return; // Finalizer may already have freed context.
    auto state = p ? p->state : *static_cast<std::shared_ptr<State> *>(context);
    if (state->cleaning) return;
    try {
        bool terminal;
        { std::lock_guard lock(state->mutex); terminal = state->terminalQueued; }
        if (!p || terminal) {
            state->retire();
            if (auto error = state->failPending()) (void)napi_fatal_exception(env, error);
            return;
        }
        {
            std::lock_guard lock(state->mutex);
            if (state->sealed || state->slots[p->slot].ticket != p->ticket) return;
        }
        if (state->inject(1)) throw std::runtime_error("test result allocation failure");
        napi_value result, control, jpeg;
        check(napi_create_object(env, &result));
        check(napi_create_buffer_copy(env, p->control.length, p->control.bytes, nullptr, &control));
        if (p->jpeg) check(napi_create_buffer_copy(env, p->jpeg.length, p->jpeg.bytes, nullptr, &jpeg));
        else jpeg = nilValue(env);
        napi_property_descriptor props[] = {
            {"control", nullptr, nullptr, nullptr, nullptr, control, napi_enumerable, nullptr},
            {"jpeg", nullptr, nullptr, nullptr, nullptr, jpeg, napi_enumerable, nullptr},
            {"then", nullptr, nullptr, nullptr, nullptr, undef(env), napi_default, nullptr},
        };
        check(napi_define_properties(env, result, 3, props));
        auto cb = state->consume(p->slot);
        check(state->invoke(cb, nilValue(env), result));
        state->updateLiveness();
    } catch (...) {
        state->retire();
        bool pending = false;
        napi_value exception = nullptr;
        if (napi_is_exception_pending(env, &pending) == napi_ok && pending)
            (void)napi_get_and_clear_last_exception(env, &exception);
        auto rejectedException = state->failPending();
        if (!exception) exception = rejectedException;
        if (exception) (void)napi_fatal_exception(env, exception);
    }
}
struct Object { std::shared_ptr<State> state;
#ifdef TRON_CAPTURE_TEST
    std::shared_ptr<Transport> testPeer;
#endif
};
static Object *receiver(napi_env e, napi_callback_info info, size_t *argc, napi_value *argv) {
    napi_value self; check(napi_get_cb_info(e, info, argc, argv, &self, nullptr));
    void *v = nullptr; check(napi_unwrap(e, self, &v));
    if (!v) throw std::runtime_error("invalid native capture receiver");
    return static_cast<Object *>(v);
}
static NSData *buffer(napi_env e, napi_value v, size_t limit, bool nullable = false) {
    napi_valuetype type; check(napi_typeof(e, v, &type)); if (nullable && type == napi_null) return nil;
    bool valid = false; check(napi_is_buffer(e, v, &valid));
    if (!valid) throw std::runtime_error("native capture requires a bounded Buffer");
    void *bytes; size_t count; check(napi_get_buffer_info(e, v, &bytes, &count));
    if (!count || count > limit) throw std::runtime_error("native capture Buffer exceeds bounds");
    return [NSData dataWithBytes:bytes length:count];
}
static napi_ref callback(napi_env e, napi_value v) {
    napi_valuetype type; check(napi_typeof(e, v, &type));
    if (type != napi_function) throw std::runtime_error("native capture completion must be a function");
    return retain(e, v);
}
static napi_value request(napi_env e, napi_callback_info info) {
    try { @autoreleasepool {
        napi_value argv[3]; size_t argc = 3;
        auto state = receiver(e, info, &argc, argv)->state;
        if (argc != 2) throw std::runtime_error("request expects control Buffer and completion");
        NSData *control = buffer(e, argv[0], ControlLimit);
        id json = [NSJSONSerialization JSONObjectWithData:control options:0 error:nullptr];
        if (![json isKindOfClass:NSDictionary.class]) throw std::runtime_error("invalid capture control JSON");
        NSString *op = json[@"operation"];
        if (![op isKindOfClass:NSString.class] || ![@[@"hello", @"catalog", @"automationEndpoint", @"start", @"pull", @"suspend", @"stop"] containsObject:op])
            throw std::runtime_error("invalid capture operation");
        bool stop = [op isEqualToString:@"stop"] || [op isEqualToString:@"suspend"], pull = [op isEqualToString:@"pull"];
        size_t index = StopSlot; uint64_t ticket; std::shared_ptr<Transport> peer;
        {
            std::lock_guard lock(state->mutex);
            if (state->sealed || state->terminalQueued || !state->transport) throw std::runtime_error("native capture transport closed");
            for (const auto &s : state->slots) if (pull && s.ticket && s.pull) throw std::runtime_error("one native capture pull may be outstanding");
            if (!stop) for (index = 0; index < OrdinarySlots && state->slots[index].ticket; ++index) {}
            if (index == OrdinarySlots && !stop) throw std::runtime_error("native capture request capacity exhausted");
            if (state->slots[index].ticket) throw std::runtime_error("native capture request capacity exhausted");
            if (state->nextTicket == std::numeric_limits<uint64_t>::max()) throw std::runtime_error("native capture tickets exhausted");
            ticket = state->nextTicket++; peer = state->transport;
        }
        auto cb = callback(e, argv[1]);
        { std::lock_guard lock(state->mutex); state->slots[index] = {ticket, cb, false, pull}; }
        state->referenceLoop(true);
        std::weak_ptr<State> weak = state;
        try { peer->send(index, control, [weak, index, ticket](NSData *c, NSData *j) { if (auto s = weak.lock()) s->reply(index, ticket, c, j); }); }
        catch (...) { state->lost(); }
        return undef(e);
    }} catch (const std::exception &error) { throwCurrent(e, error); return nullptr; }
}
static napi_value closeLocal(napi_env e, napi_callback_info info) {
    std::shared_ptr<State> state;
    try {
        napi_value argv[2]; size_t argc = 2; state = receiver(e, info, &argc, argv)->state;
        if (argc != 1 || state->closed) throw std::runtime_error("closeLocal expects one completion and may not overlap");
        state->closed = callback(e, argv[0]);
        state->retire();
        const bool failed = state->inject(3);
        auto rejectedException = state->failPending();
        if (rejectedException) {
            check(napi_throw(e, rejectedException));
            return nullptr; // Native retirement/close callback remain owned.
        }
        if (failed) {
            auto cb = state->closed; state->closed = nullptr;
            (void)state->invoke(cb, state->failureValue(), undef(e));
        }
        if (!state->finalizerPending && state->closed) {
            auto cb = state->closed; state->closed = nullptr;
            (void)state->invoke(cb, nilValue(e), undef(e));
        }
        return undef(e);
    } catch (const std::exception &error) { if (state) state->retire(); throwCurrent(e, error); return nullptr; }
}
#ifdef TRON_CAPTURE_TEST
static napi_value testReply(napi_env e, napi_callback_info info) {
    try { @autoreleasepool {
        napi_value argv[4]; size_t argc = 4; auto *o = receiver(e, info, &argc, argv);
        if (argc != 4) throw std::runtime_error("testReply arguments");
        uint32_t slot; bool delayed; check(napi_get_value_uint32(e, argv[0], &slot)); check(napi_get_value_bool(e, argv[3], &delayed));
        o->testPeer->reply(slot, buffer(e, argv[1], ControlLimit + 1), buffer(e, argv[2], JPEGLimit + 1, true), delayed);
        return undef(e);
    }} catch (const std::exception &error) { throwCurrent(e, error); return nullptr; }
}
static napi_value testLose(napi_env e, napi_callback_info info) {
    try { size_t n = 0; receiver(e, info, &n, nullptr)->testPeer->lose(); return undef(e); }
    catch (const std::exception &error) { throwCurrent(e, error); return nullptr; }
}
static napi_value testFault(napi_env e, napi_callback_info info) {
    try { napi_value arg; size_t n = 1; auto s = receiver(e, info, &n, &arg)->state; uint32_t value; check(napi_get_value_uint32(e, arg, &value)); s->fault.store(value); return undef(e); }
    catch (const std::exception &error) { throwCurrent(e, error); return nullptr; }
}
static napi_value testDeliver(napi_env e, napi_callback_info) { deliverDelayedReply(); return undef(e); }
static napi_value stats(napi_env e, napi_callback_info) {
    napi_value v; check(napi_create_object(e, &v));
    for (auto p : {std::pair{"owners", owners.load()}, {"payloads", payloads.load()}, {"hooks", hooks.load()}, {"queues", queues.load()}, {"references", references.load()}, {"delayed", delayedReplyCount()}}) {
        napi_value n; check(napi_create_uint32(e, p.second, &n)); check(napi_set_named_property(e, v, p.first, n));
    }
    return v;
}
#endif
static napi_value open(napi_env e, napi_callback_info info) {
    std::shared_ptr<State> state;
    try { @autoreleasepool {
        napi_value argv[2]; size_t argc = 2; check(napi_get_cb_info(e, info, &argc, argv, nullptr, nullptr));
        uint32_t fault = 0; size_t capacity = QueueCapacity;
#ifdef TRON_CAPTURE_TEST
        if (argc == 1) { uint32_t v; check(napi_get_value_uint32(e, argv[0], &v)); if (v == 99) capacity = 1; else fault = v; }
        else if (argc) throw std::runtime_error("test open arguments");
#else
        if (argc) throw std::runtime_error("native capture open accepts no endpoint or credentials");
#endif
        Environment *registry; check(napi_get_instance_data(e, reinterpret_cast<void **>(&registry)));
        size_t i = 0;
        for (; i < registry->clients.size(); ++i) {
            auto s = registry->clients[i].lock();
            if (!s || (!s->finalizerPending && s->payloadCount == 0)) break;
        }
        if (i == registry->clients.size()) throw std::runtime_error("native capture connection capacity exhausted");
        state = std::make_shared<State>(e); registry->clients[i] = state;
        napi_value message, failure, name;
        check(napi_create_string_utf8(e, "native capture client failed or closed locally; remote retirement unconfirmed (transport lost)", NAPI_AUTO_LENGTH, &message));
        check(napi_create_error(e, nullptr, message, &failure)); state->failure = retain(e, failure);
        if (fault == 1) throw std::runtime_error("test initialization failure 1");
        check(napi_create_string_utf8(e, "Tron native capture", NAPI_AUTO_LENGTH, &name));
        auto context = std::make_unique<std::shared_ptr<State>>(state);
        check(napi_create_threadsafe_function(e, nullptr, nullptr, name, capacity, 1, context.get(), finalized, context.get(), callJS, &state->queue));
        context.release(); state->finalizerPending = true;
#ifdef TRON_CAPTURE_TEST
        ++queues;
#endif
        state->referenceLoop(false);
        if (fault == 2) throw std::runtime_error("test initialization failure 2");
        auto hook = std::make_unique<std::shared_ptr<State>>(state);
        check(napi_add_async_cleanup_hook(e, cleanup, hook.get(), &state->hook));
        state->hookContext = hook.release();
#ifdef TRON_CAPTURE_TEST
        ++hooks;
#endif
        if (fault == 3) throw std::runtime_error("test initialization failure 3");
        state->transport = makeTransport();
        if (fault == 4) throw std::runtime_error("test initialization failure 4");
        std::weak_ptr<State> weak = state;
        state->transport->open([weak] { if (auto s = weak.lock()) s->lost(); });
        if (fault == 5) throw std::runtime_error("test initialization failure 5");
        napi_value result; check(napi_create_object(e, &result));
        auto object = std::make_unique<Object>(); object->state = state;
#ifdef TRON_CAPTURE_TEST
        object->testPeer = state->transport;
#endif
        check(napi_wrap(e, result, object.get(), [](napi_env, void *p, void *) { delete static_cast<Object *>(p); }, nullptr, nullptr)); object.release();
        napi_property_descriptor methods[] = {
            {"request", nullptr, request, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"closeLocal", nullptr, closeLocal, nullptr, nullptr, nullptr, napi_default, nullptr},
#ifdef TRON_CAPTURE_TEST
            {"testReply", nullptr, testReply, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"testLose", nullptr, testLose, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"testFault", nullptr, testFault, nullptr, nullptr, nullptr, napi_default, nullptr},
#endif
        };
        check(napi_define_properties(e, result, sizeof(methods)/sizeof(methods[0]), methods));
        state->object = retain(e, result);
        return result;
    }} catch (const std::exception &error) {
        if (state) { state->retire(); if (!state->finalizerPending) state->discardReferences(); }
        throwCurrent(e, error); return nullptr;
    }
}
} // namespace capture
NAPI_MODULE_INIT() {
    using namespace capture;
    try {
        auto registry = std::make_unique<Environment>();
        check(napi_set_instance_data(env, registry.get(), [](napi_env, void *p, void *) { delete static_cast<Environment *>(p); }, nullptr)); registry.release();
        napi_property_descriptor methods[] = {{"open", nullptr, open, nullptr, nullptr, nullptr, napi_default, nullptr},
#ifdef TRON_CAPTURE_TEST
            {"testStats", nullptr, stats, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"testDeliverDelayed", nullptr, testDeliver, nullptr, nullptr, nullptr, napi_default, nullptr},
#endif
        };
        check(napi_define_properties(env, exports, sizeof(methods)/sizeof(methods[0]), methods));
        napi_value version; check(napi_create_uint32(env, 3, &version));
        napi_property_descriptor api = {"apiVersion", nullptr, nullptr, nullptr, nullptr, version, napi_enumerable, nullptr};
        check(napi_define_properties(env, exports, 1, &api));
        return exports;
    } catch (const std::exception &error) { throwCurrent(env, error); return nullptr; }
}
