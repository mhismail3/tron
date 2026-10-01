// One retained session leader (PTY or piped process). Never exec user code here: its live SID prevents reuse
// while ordinary job-control groups are enumerated and signalled by audit token.
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define TERM_GRACE_MS 500
#define FORCE_WINDOW_MS 2000
#define SCAN_BYTES_MAX (4 * 1024 * 1024)
static volatile sig_atomic_t interrupted;
static void interrupt_owner(int sig) { (void)sig; interrupted = 1; }
static void child_changed(int sig) { (void)sig; }
static long long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static bool audit_identity(pid_t pid, audit_token_t *token) {
    mach_port_t task = MACH_PORT_NULL;
    if (task_name_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return false;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t result = task_info(task, TASK_AUDIT_TOKEN, (task_info_t)token, &count);
    mach_port_deallocate(mach_task_self(), task);
    return result == KERN_SUCCESS && token->val[5] == (unsigned)pid;
}

// Enumeration is discovery, never signal authority. Bracket membership/state
// with the kernel identity; exec/exit races are retried within ONE total window.
// A live retained SID cannot be reallocated to an unrelated session on XNU.
static bool sweep(pid_t sid, int sig, long long deadline) {
    int needed = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (needed <= 0 || needed > SCAN_BYTES_MAX - 4096) return false;
    int capacity = needed + 4096;
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids) return false;
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, capacity);
    bool empty = bytes > 0 && bytes < capacity;
    for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
        if (now_ms() >= deadline) { empty = false; break; }
        pid_t pid = pids[i];
        if (pid <= 0 || pid == sid || getsid(pid) != sid) continue;
        audit_token_t before, after;
        struct proc_bsdinfo info;
        if (!audit_identity(pid, &before) ||
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
            getsid(pid) != sid || !audit_identity(pid, &after) ||
            memcmp(&before, &after, sizeof(before)) != 0) {
            empty = false;
            continue;
        }
        // Zombies cannot fork or execute; their reaping belongs to their parent.
        if (info.pbi_status == SZOMB) continue;
        empty = false;
        if (sig) (void)proc_signal_with_audittoken(&after, sig);
    }
    free(pids);
    return empty;
}

#define MAX_DESCENDANTS 4096
struct descendant { audit_token_t identity; size_t parent; bool exempt; };
static struct descendant descendants[MAX_DESCENDANTS];
static size_t descendant_count;
static char owner_executable[PROC_PIDPATHINFO_MAXSIZE];

static bool independent_owner(pid_t pid) {
    char executable[PROC_PIDPATHINFO_MAXSIZE];
    return getsid(pid) == pid && proc_pidpath(pid, executable, sizeof(executable)) > 0 &&
        !strcmp(executable, owner_executable);
}

// Capture a live PPID edge while both kernel identities still match. This
// extends the retained SID to ordinary children that made their own session
// (e.g. test diagnostics), without recovering authority from an orphan PID.
// Registered native owners are separate origin leases: do not enter or kill
// their subtrees when their immediate launcher finishes.
static bool discover_descendants(long long deadline) {
    pid_t children[MAX_DESCENDANTS];
    for (size_t i = 0; i < descendant_count; i++) {
        if (now_ms() >= deadline) return false;
        struct descendant *parent = &descendants[i];
        pid_t parent_pid = (pid_t)parent->identity.val[5];
        if (i && (descendants[parent->parent].exempt || independent_owner(parent_pid))) parent->exempt = true;
        if (parent->exempt) continue;
        audit_token_t current;
        if (!audit_identity(parent_pid, &current) || memcmp(&current, &parent->identity, sizeof(current))) continue;
        // Unlike proc_listpids, this API returns a PID count, not byte count.
        int count = proc_listchildpids(parent_pid, children, sizeof(children));
        if (count < 0 || count >= MAX_DESCENDANTS) return false;
        for (int c = 0; c < count; c++) {
            if (now_ms() >= deadline) return false;
            audit_token_t before, after, parent_after;
            struct proc_bsdinfo info;
            pid_t pid = children[c];
            if (pid <= 1 || independent_owner(pid)) continue;
            if (!audit_identity(pid, &before) ||
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
                info.pbi_ppid != (unsigned)parent_pid || !audit_identity(pid, &after) ||
                memcmp(&before, &after, sizeof(before)) || !audit_identity(parent_pid, &parent_after) ||
                memcmp(&parent_after, &parent->identity, sizeof(parent_after))) return false;
            size_t existing = 0;
            while (existing < descendant_count && memcmp(&descendants[existing].identity, &after, sizeof(after))) existing++;
            if (existing < descendant_count) continue;
            if (descendant_count == MAX_DESCENDANTS) return false;
            descendants[descendant_count++] = (struct descendant){ .identity = after, .parent = i };
        }
    }
    return true;
}

static bool sweep_descendants(int sig, long long deadline) {
    bool empty = true;
    for (size_t i = 1; i < descendant_count; i++) {
        if (now_ms() >= deadline) return false;
        struct descendant *owned = &descendants[i];
        pid_t pid = (pid_t)owned->identity.val[5];
        if (descendants[owned->parent].exempt || independent_owner(pid)) owned->exempt = true;
        if (owned->exempt) continue;
        audit_token_t current;
        struct proc_bsdinfo info;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) {
            if (errno != ESRCH) empty = false;
            continue;
        }
        if (info.pbi_status == SZOMB) continue;
        if (!audit_identity(pid, &current)) { empty = false; continue; }
        if (memcmp(&current, &owned->identity, sizeof(current))) continue; // The old incarnation is gone.
        empty = false;
        if (sig) (void)proc_signal_with_audittoken(&owned->identity, sig);
    }
    return empty;
}

// The parent grants this single fresh rendezvous at launch. Retire it even if
// that parent dies before accepting; never scan/recover paths from old sessions.
static void retire_control_path(const char *path) {
    char directory[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if (strlcpy(directory, path, sizeof(directory)) >= sizeof(directory)) return;
    char *name = strrchr(directory, '/');
    if (!name || name == directory) return;
    *name++ = '\0';
    int fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) return;
    struct stat owner, endpoint;
    if (fstat(fd, &owner) == 0 && owner.st_uid == getuid() && (owner.st_mode & 0777) == 0700 &&
        fstatat(fd, name, &endpoint, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISSOCK(endpoint.st_mode) && endpoint.st_uid == getuid()) {
        (void)unlinkat(fd, name, 0);
        (void)rmdir(directory); // Only an empty, per-terminal directory can retire.
    }
    close(fd);
}

static int connect_control(const char *path, pid_t parent) {
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(address.sun_path)) return -1;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    // node-pty closes non-stdio descriptors at spawn, so establish the private
    // control channel before forking. No shell/descendant ever inherits it.
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd); return -1;
    }
    pid_t peer = 0;
    socklen_t length = sizeof(peer);
    if (parent <= 1 || getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) != 0 || peer != parent) {
        close(fd); return -1;
    }
    return fd;
}

// This mode captures only its actual live parent, before acknowledging readiness.
// It never accepts a historical PID or launches a replacement Gateway.
#define MAX_LEASES 4096
static int watchdog(const char *path, const char *nonce, const char *lease_nonce) {
    audit_token_t parent;
    pid_t pid = getppid();
    if (pid <= 1 || !audit_identity(pid, &parent) || getppid() != pid) return 125;
    signal(SIGPIPE, SIG_IGN);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlcpy(address.sun_path, path, sizeof(address.sun_path)) >= sizeof(address.sun_path)) return 125;
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 8)) return 125;
    if (write(3, "R", 1) != 1) { retire_control_path(path); return 125; }
    struct pollfd startup = { .fd = 3, .events = POLLIN };
    char proceed;
    if (poll(&startup, 1, 2000) <= 0 || read(3, &proceed, 1) != 1 || proceed != 'P') { retire_control_path(path); return 125; }
    close(3);
    long long deadline = 0, accepted_wall = 0;
    int leases[MAX_LEASES];
    size_t lease_count = 0;
    bool termed = false, frozen = false;
    for (;;) {
        // These are live control endpoints, never persisted process identities.
        // Freeze and interrupt them BEFORE replacing the origin, even when its
        // JS loop cannot process cancellation or a receipt.
        for (size_t i = 0; i < lease_count;) {
            char proof[32];
            ssize_t count = read(leases[i], proof, sizeof(proof));
            if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) {
                close(leases[i]);
                leases[i] = leases[--lease_count];
            } else i++;
        }
        // The guardian remains the origin's actual child. Reparenting proves
        // origin loss without mistaking a transient task-info failure for death.
        // Signals still use the startup audit token, never this numeric PID.
        if (getppid() != pid) break;
        long long now = now_ms();
        if (deadline && now >= deadline - 3000) {
            (void)proc_signal_with_audittoken(&parent, SIGKILL);
            break;
        }
        if (deadline && !termed && now >= deadline - 3500) {
            (void)proc_signal_with_audittoken(&parent, SIGTERM);
            termed = true;
        }
        struct pollfd endpoint = { .fd = listener, .events = POLLIN };
        if (poll(&endpoint, 1, 20) <= 0) continue;
        int client = accept(listener, NULL, NULL);
        if (client < 0) continue;
        // This private capability is given to the Gateway and its updater only.
        // A bounded partial request cannot extend an already accepted deadline.
        char request[160] = {0};
        size_t used = 0;
        long long request_deadline = now_ms() + 100;
        while (used < sizeof(request) - 1 && now_ms() < request_deadline) {
            struct pollfd input = { .fd = client, .events = POLLIN };
            if (poll(&input, 1, 5) <= 0) continue;
            ssize_t count = read(client, request + used, sizeof(request) - 1 - used);
            if (count <= 0) break;
            used += (size_t)count;
            if (strchr(request, '\n')) break;
        }
        char supplied[80] = {0};
        long long requested = 0;
        if (!frozen && lease_count < MAX_LEASES && request[0] == 'L' &&
            used == strlen(lease_nonce) + 2 && !strncmp(request + 1, lease_nonce, strlen(lease_nonce)) && request[used - 1] == '\n') {
            // Permission and registration are one native-loop operation. A late
            // launch can never slip through a blocked JS admission callback.
            fcntl(client, F_SETFL, O_NONBLOCK);
            if (write(client, "S", 1) == 1) { leases[lease_count++] = client; continue; }
        } else if (strchr(request, '\n') && sscanf(request, "%79s %lld", supplied, &requested) == 2 && !strcmp(supplied, nonce)) {
            struct timespec wall;
            clock_gettime(CLOCK_REALTIME, &wall);
            long long remaining = requested - ((long long)wall.tv_sec * 1000 + wall.tv_nsec / 1000000);
            if (!deadline && remaining > 3500 && remaining <= 15000) {
                deadline = now_ms() + remaining;
                accepted_wall = requested;
                frozen = true;
                for (size_t i = 0; i < lease_count; i++) (void)write(leases[i], "T", 1);
            }
            if (deadline) dprintf(client, "R%lld\n", accepted_wall);
        }
        close(client);
    }
    for (size_t i = 0; i < lease_count; i++) close(leases[i]);
    close(listener);
    retire_control_path(path);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 5 && strcmp(argv[1], "--watchdog") == 0) return watchdog(argv[2], argv[3], argv[4]);
    const char *guardian_path = NULL, *guardian_nonce = NULL;
    pid_t guardian_pid = 0;
    if (argc > 5 && strcmp(argv[1], "--guardian") == 0) {
        guardian_path = argv[2]; guardian_nonce = argv[3]; guardian_pid = (pid_t)atoi(argv[4]);
        argv += 4; argc -= 4;
    }
    bool piped = argc >= 6 && strcmp(argv[1], "--process") == 0;
    bool synchronous = argc >= 3 && strcmp(argv[1], "--sync") == 0;
    bool headless = piped || synchronous;
    if ((synchronous && !guardian_path) || (!headless && (argc < 5 || !isatty(STDIN_FILENO))) || getsid(0) != getpid()) return 125;
    const char *path = synchronous ? guardian_path : argv[piped ? 2 : 1];
    const char *nonce = synchronous ? guardian_nonce : argv[piped ? 3 : 2];
    int executable_index = synchronous ? 2 : piped ? 5 : 3;
    pid_t sid = getpid();
    if (!audit_identity(sid, &descendants[0].identity) || proc_pidpath(sid, owner_executable, sizeof(owner_executable)) <= 0) return 125;
    descendant_count = 1;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);
    signal(SIGTTIN, SIG_IGN);
    signal(SIGTSTP, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    signal(SIGQUIT, SIG_IGN);
    signal(SIGHUP, interrupt_owner);
    signal(SIGTERM, interrupt_owner);
    signal(SIGCHLD, child_changed);
    int control = connect_control(path, synchronous ? guardian_pid : piped ? (pid_t)atoi(argv[4]) : getppid());
    if (!headless) retire_control_path(path);
    if (control < 0) return 125; // No user process exists yet.
    dprintf(control, synchronous ? "L%s\n" : "%s\n", nonce);
    struct pollfd channel = { .fd = control, .events = POLLIN };
    char command = 0;
    int ready = poll(&channel, 1, 2000);
    if (ready <= 0 || read(control, &command, 1) != 1 || command != 'S' || interrupted) {
        if (!headless) dprintf(control, "E0\n");
        return headless ? 125 : 0;
    }

    int guardian = -1;
    if (guardian_path && !synchronous) {
        guardian = connect_control(guardian_path, guardian_pid);
        if (guardian >= 0) {
            dprintf(guardian, "L%s\n", guardian_nonce);
            struct pollfd admission = { .fd = guardian, .events = POLLIN };
            if (poll(&admission, 1, 2000) <= 0 || read(guardian, &command, 1) != 1 || command != 'S') {
                close(guardian); guardian = -1;
            }
        }
        if (guardian < 0) { dprintf(control, "E125\n"); if (piped) dprintf(3, "E125\n"); return 125; }
        fcntl(guardian, F_SETFL, O_NONBLOCK);
    }
    if (piped) {
        fcntl(3, F_SETFD, FD_CLOEXEC);
        fcntl(3, F_SETFL, O_NONBLOCK);
        struct pollfd launcher = { .fd = 3, .events = POLLIN };
        int permission = poll(&launcher, 1, 2000);
        // The JS launcher releases its synchronous ownership/status callbacks
        // before granting P. An exception/cancel/exit cannot execute user code.
        if (permission <= 0 || read(3, &command, 1) != 1 || command != 'P') {
            dprintf(control, "E125\n");
            dprintf(3, "E125\n");
            return 125;
        }
        dprintf(3, "R\n");
    }
    // Recheck termination queued while waiting for the launcher's P handshake.
    struct pollfd before_start[2] = {{ .fd = control, .events = POLLIN }, { .fd = guardian, .events = POLLIN }};
    if (interrupted || poll(before_start, 2, 0) > 0) {
        dprintf(control, "E125\n"); if (piped) dprintf(3, "E125\n"); return 125;
    }
    int start[2];
    if (pipe(start) != 0) return 125;
    pid_t shell = fork();
    if (shell < 0) { close(start[0]); close(start[1]); return 125; }
    if (shell == 0) {
        close(control);
        if (guardian >= 0) close(guardian);
        if (piped) close(3);
        close(start[1]);
        for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
        if (setpgid(0, 0) != 0 || read(start[0], &command, 1) != 1) _exit(125);
        close(start[0]);
        execvp(argv[executable_index], &argv[executable_index]);
        perror("Tron owned process");
        _exit(127);
    }
    close(start[0]);
    bool start_failed = setpgid(shell, shell) != 0 || (!headless && tcsetpgrp(STDIN_FILENO, shell) != 0);
    if (!start_failed) (void)write(start[1], "S", 1);
    close(start[1]);
    fcntl(control, F_SETFL, O_NONBLOCK);
    bool stopping = start_failed, reaped = false, unknown = false, discovery_complete = true;
    int exit_code = 0;
    long long started = 0;
    for (;;) {
        int status;
        if (!reaped && waitpid(shell, &status, WNOHANG) == shell) {
            reaped = true;
            exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
            stopping = true;
        }
        if (interrupted) stopping = true;
        if (guardian >= 0 && !stopping) {
            ssize_t size = read(guardian, &command, 1);
            if (size == 0 || (size > 0 && command == 'T') || (size < 0 && errno != EAGAIN && errno != EINTR)) stopping = true;
        }
        if (piped && !stopping) {
            ssize_t size = read(3, &command, 1);
            // Immediate launcher exit is NOT origin Gateway lease loss. Detached
            // nested work may intentionally outlive that launcher.
            if (size > 0 && command == 'T') stopping = true;
            if (size > 0 && command == 'I') (void)sweep(sid, SIGINT, now_ms() + 100);
        }
        if (!stopping) {
            int result = poll(&channel, 1, 20);
            if (result > 0 && channel.revents) {
                ssize_t size = read(control, &command, 1);
                if (size == 0 && piped) retire_control_path(path);
                if (size == 0 || (size > 0 && command == 'T') ||
                    (size < 0 && errno != EAGAIN && errno != EINTR)) stopping = true;
            }
            continue;
        }
        long long now = now_ms();
        if (!started) started = now;
        long long deadline = started + TERM_GRACE_MS + FORCE_WINDOW_MS;
        if (!unknown && now >= deadline) {
            unknown = true;
            dprintf(control, "U\n");
            if (piped) dprintf(3, "U\n");
            close(control);
            control = -1;
            // Fail closed: retain the SID if the kernel cannot prove quiescence.
            // No repeated force windows, no numeric fallback, no successful Quit.
        }
        int sig = unknown ? 0 : (now < started + TERM_GRACE_MS ? SIGTERM : SIGKILL);
        // Discover BEFORE signalling: killing the parent first would sever the
        // only authoritative ancestry edge to a separately grouped child.
        if (!unknown && !discover_descendants(deadline)) discovery_complete = false;
        bool descendants_empty = sweep_descendants(sig, unknown ? now + 100 : deadline);
        // The shell can become a zombie after WNOHANG above. Empty membership
        // is not its exit status: reap it on the next bounded iteration first.
        if (sweep(sid, sig, unknown ? now + 100 : deadline) && descendants_empty &&
            (discovery_complete || unknown) && (reaped || unknown)) {
            if (!unknown) {
                dprintf(control, "E%d\n", exit_code);
                if (piped) dprintf(3, "E%d\n", exit_code);
            }
            if (control >= 0) close(control);
            return unknown ? 125 : exit_code;
        }
        struct timespec pause = { .tv_nsec = unknown ? 200000000 : 20000000 };
        nanosleep(&pause, NULL);
    }
}
