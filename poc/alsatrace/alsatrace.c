/* alsatrace: a log-only addin (LD_PRELOAD into MPC) that records how MPC opens and configures ALSA PCMs.
 *
 * Why: MPC refuses a 48 kHz-only USB device as its audio device ("44100 may not be a supported sample rate", EINVAL).
 * An addin that redirects such a device to alsa-lib's rate converter has to answer MPC's calls the way MPC expects,
 * so this probe records them first: snd_pcm_open (name, stream, mode), every hw/sw-params setter, getter and test with its
 * arguments and result, link/prepare/start/drop/recover/close, and, for the per-period calls (readi/writei/readn/
 * writen, avail, wait, poll, forward/rewind), the first few calls per PCM and every error, plus totals at close. It also logs MPC's
 * device enumeration (snd_card_next, snd_ctl_open/close, snd_ctl_pcm_next_device/pcm_info, snd_device_name_hint), so a trace shows
 * what MPC looked at between two opens.
 *
 * It changes nothing: each hook calls the next definition (dlsym(RTLD_NEXT), docs/ADDINS.md "Two addins that replace the
 * same function") with the same arguments and returns its result. Log: $ALSATRACE_LOG or /tmp/alsatrace.log, capped at
 * 2 MB. One line per call: ms since load, thread id, call, PCM handle, arguments, result. A call is logged after it returns,
 * so calls alsa-lib makes inside another one (snd_pcm_hw_params runs sw_params and prepare itself) appear just before it.
 * No ALSA headers needed: the prototypes are declared here (alsa-lib 1.2 ABI, opaque handles). */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define EXPORT __attribute__((visibility("default")))

typedef struct _snd_pcm snd_pcm_t;
typedef struct _snd_pcm_hw_params snd_pcm_hw_params_t;
typedef struct _snd_pcm_sw_params snd_pcm_sw_params_t;
typedef unsigned long snd_pcm_uframes_t;
typedef long snd_pcm_sframes_t;
struct pollfd;

/* ---- log ---- */
static int g_fd = -1;
static long g_bytes;
static struct timespec g_t0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
#define LOG_MAX (2L << 20)

__attribute__((constructor)) static void at_load(void) {
    clock_gettime(CLOCK_MONOTONIC, &g_t0);
    const char *p = getenv("ALSATRACE_LOG");
    g_fd = open(p && *p ? p : "/tmp/alsatrace.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
}

static void logf_(const char *fmt, ...) {
    if (g_fd < 0 || g_bytes > LOG_MAX) return;
    char line[512];
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    long ms = (t.tv_sec - g_t0.tv_sec) * 1000L + (t.tv_nsec - g_t0.tv_nsec) / 1000000L;
    int n = snprintf(line, sizeof line, "%8ld %5ld ", ms, (long)syscall(SYS_gettid));
    va_list ap;
    va_start(ap, fmt);
    n += vsnprintf(line + n, sizeof line - (size_t)n - 1, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof line - 2) n = (int)sizeof line - 2;
    line[n++] = '\n';
    pthread_mutex_lock(&g_lock);
    if (write(g_fd, line, (size_t)n) > 0) g_bytes += n;
    if (g_bytes > LOG_MAX) { static const char m[] = "-- log limit reached --\n"; (void)!write(g_fd, m, sizeof m - 1); }
    pthread_mutex_unlock(&g_lock);
}

/* ---- per-PCM counters for the per-period calls ---- */
#define NSLOT 16
#define FIRST 3   /* log the first FIRST calls of each kind per PCM */
enum { K_READI, K_WRITEI, K_READN, K_WRITEN, K_AVAIL, K_AVAILU, K_WAIT, K_POLL, K_POLLCNT, K_REVENTS, K_FWD, K_REW, K_N };
static const char *KNAME[K_N] = { "readi", "writei", "readn", "writen", "avail", "avail_update", "wait",
                                  "poll_descriptors", "poll_descriptors_count", "poll_descriptors_revents", "forward", "rewind" };
static struct slot { _Atomic(snd_pcm_t *) pcm; atomic_ulong calls[K_N], frames[K_N], errs[K_N]; } g_slot[NSLOT];

static struct slot *slot_of(snd_pcm_t *p) {
    for (int i = 0; i < NSLOT; i++) if (atomic_load(&g_slot[i].pcm) == p) return &g_slot[i];
    for (int i = 0; i < NSLOT; i++) {
        snd_pcm_t *z = NULL;
        if (atomic_compare_exchange_strong(&g_slot[i].pcm, &z, p)) return &g_slot[i];
    }
    return NULL;
}

/* count a per-period call; returns 1 if this one should be logged (first few, or an error) */
static int tick(snd_pcm_t *p, int k, long res, unsigned long frames) {
    struct slot *s = slot_of(p);
    if (!s) return res < 0;
    unsigned long c = atomic_fetch_add(&s->calls[k], 1);
    if (res > 0) atomic_fetch_add(&s->frames[k], frames ? frames : 0);
    if (res < 0) { unsigned long e = atomic_fetch_add(&s->errs[k], 1); return e < 20 || e % 1000 == 0; }
    return c < FIRST;
}

static void totals(snd_pcm_t *p) {
    struct slot *s = slot_of(p);
    if (!s) return;
    for (int k = 0; k < K_N; k++) {
        unsigned long c = atomic_exchange(&s->calls[k], 0), f = atomic_exchange(&s->frames[k], 0), e = atomic_exchange(&s->errs[k], 0);
        if (c) logf_("  totals %p %s: %lu calls, %lu frames, %lu errors", (void *)p, KNAME[k], c, f, e);
    }
    atomic_store(&s->pcm, NULL);
}

/* ---- hook helpers ---- */
#define REAL(ret, name, ...)                                                                  \
    static ret (*real)(__VA_ARGS__);                                                           \
    if (!real) *(void **)&real = dlsym(RTLD_NEXT, #name);                                      \
    if (!real) { logf_("%s: no next definition", #name); errno = ENOSYS; return (ret)-ENOSYS; }

static const char *stream_name(int s) { return s == 0 ? "PLAYBACK" : s == 1 ? "CAPTURE" : "?"; }
static const char *access_name(int a) {
    static const char *n[] = { "MMAP_INTERLEAVED", "MMAP_NONINTERLEAVED", "MMAP_COMPLEX", "RW_INTERLEAVED", "RW_NONINTERLEAVED" };
    return a >= 0 && a < 5 ? n[a] : "?";
}
static const char *format_name(int f) {   /* the common ones; others are logged as numbers */
    switch (f) {
    case 2: return "S16_LE"; case 6: return "S24_LE"; case 10: return "S32_LE"; case 14: return "FLOAT_LE";
    case 16: return "FLOAT64_LE"; case 32: return "S24_3LE"; default: return "?";
    }
}

/* ---- open / close / state ---- */
EXPORT int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode) {
    REAL(int, snd_pcm_open, snd_pcm_t **, const char *, int, int);
    int r = real(pcm, name, stream, mode);
    logf_("open \"%s\" %s mode=0x%x -> %d %p", name ? name : "(null)", stream_name(stream), mode, r, r == 0 && pcm ? (void *)*pcm : NULL);
    return r;
}
EXPORT int snd_pcm_close(snd_pcm_t *p) {
    REAL(int, snd_pcm_close, snd_pcm_t *);
    totals(p);
    int r = real(p);
    logf_("close %p -> %d", (void *)p, r);
    return r;
}
#define SIMPLE(name)                                                       \
    EXPORT int snd_pcm_##name(snd_pcm_t *p) {                              \
        REAL(int, snd_pcm_##name, snd_pcm_t *);                            \
        int r = real(p);                                                   \
        logf_(#name " %p -> %d", (void *)p, r);                            \
        return r;                                                          \
    }
SIMPLE(prepare)
SIMPLE(start)
SIMPLE(drop)
SIMPLE(drain)
SIMPLE(reset)
EXPORT int snd_pcm_link(snd_pcm_t *a, snd_pcm_t *b) {
    REAL(int, snd_pcm_link, snd_pcm_t *, snd_pcm_t *);
    int r = real(a, b);
    logf_("link %p %p -> %d", (void *)a, (void *)b, r);
    return r;
}
EXPORT int snd_pcm_recover(snd_pcm_t *p, int err, int silent) {
    REAL(int, snd_pcm_recover, snd_pcm_t *, int, int);
    int r = real(p, err, silent);
    logf_("recover %p err=%d silent=%d -> %d", (void *)p, err, silent, r);
    return r;
}

/* ---- hw params ---- */
EXPORT int snd_pcm_hw_params_any(snd_pcm_t *p, snd_pcm_hw_params_t *h) {
    REAL(int, snd_pcm_hw_params_any, snd_pcm_t *, snd_pcm_hw_params_t *);
    int r = real(p, h);
    logf_("hw_params_any %p -> %d", (void *)p, r);
    return r;
}
EXPORT int snd_pcm_hw_params(snd_pcm_t *p, snd_pcm_hw_params_t *h) {
    REAL(int, snd_pcm_hw_params, snd_pcm_t *, snd_pcm_hw_params_t *);
    int r = real(p, h);
    logf_("hw_params (apply) %p -> %d", (void *)p, r);
    return r;
}
EXPORT int snd_pcm_hw_params_set_access(snd_pcm_t *p, snd_pcm_hw_params_t *h, int a) {
    REAL(int, snd_pcm_hw_params_set_access, snd_pcm_t *, snd_pcm_hw_params_t *, int);
    int r = real(p, h, a);
    logf_("hw set_access %p %s -> %d", (void *)p, access_name(a), r);
    return r;
}
EXPORT int snd_pcm_hw_params_set_format(snd_pcm_t *p, snd_pcm_hw_params_t *h, int f) {
    REAL(int, snd_pcm_hw_params_set_format, snd_pcm_t *, snd_pcm_hw_params_t *, int);
    int r = real(p, h, f);
    logf_("hw set_format %p %d(%s) -> %d", (void *)p, f, format_name(f), r);
    return r;
}
EXPORT int snd_pcm_hw_params_test_format(snd_pcm_t *p, snd_pcm_hw_params_t *h, int f) {
    REAL(int, snd_pcm_hw_params_test_format, snd_pcm_t *, snd_pcm_hw_params_t *, int);
    int r = real(p, h, f);
    logf_("hw test_format %p %d(%s) -> %d", (void *)p, f, format_name(f), r);
    return r;
}
EXPORT int snd_pcm_hw_params_set_channels(snd_pcm_t *p, snd_pcm_hw_params_t *h, unsigned v) {
    REAL(int, snd_pcm_hw_params_set_channels, snd_pcm_t *, snd_pcm_hw_params_t *, unsigned);
    int r = real(p, h, v);
    logf_("hw set_channels %p %u -> %d", (void *)p, v, r);
    return r;
}
EXPORT int snd_pcm_hw_params_set_channels_near(snd_pcm_t *p, snd_pcm_hw_params_t *h, unsigned *v) {
    REAL(int, snd_pcm_hw_params_set_channels_near, snd_pcm_t *, snd_pcm_hw_params_t *, unsigned *);
    unsigned in = v ? *v : 0;
    int r = real(p, h, v);
    logf_("hw set_channels_near %p %u -> %d (got %u)", (void *)p, in, r, v ? *v : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_get_channels_min(const snd_pcm_hw_params_t *h, unsigned *v) {
    REAL(int, snd_pcm_hw_params_get_channels_min, const snd_pcm_hw_params_t *, unsigned *);
    int r = real(h, v);
    logf_("hw get_channels_min -> %d (%u)", r, v ? *v : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_get_channels_max(const snd_pcm_hw_params_t *h, unsigned *v) {
    REAL(int, snd_pcm_hw_params_get_channels_max, const snd_pcm_hw_params_t *, unsigned *);
    int r = real(h, v);
    logf_("hw get_channels_max -> %d (%u)", r, v ? *v : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_set_rate(snd_pcm_t *p, snd_pcm_hw_params_t *h, unsigned v, int dir) {
    REAL(int, snd_pcm_hw_params_set_rate, snd_pcm_t *, snd_pcm_hw_params_t *, unsigned, int);
    int r = real(p, h, v, dir);
    logf_("hw set_rate %p %u dir=%d -> %d", (void *)p, v, dir, r);
    return r;
}
EXPORT int snd_pcm_hw_params_set_rate_near(snd_pcm_t *p, snd_pcm_hw_params_t *h, unsigned *v, int *dir) {
    REAL(int, snd_pcm_hw_params_set_rate_near, snd_pcm_t *, snd_pcm_hw_params_t *, unsigned *, int *);
    unsigned in = v ? *v : 0;
    int r = real(p, h, v, dir);
    logf_("hw set_rate_near %p %u -> %d (got %u dir %d)", (void *)p, in, r, v ? *v : 0, dir ? *dir : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_test_rate(snd_pcm_t *p, snd_pcm_hw_params_t *h, unsigned v, int dir) {
    REAL(int, snd_pcm_hw_params_test_rate, snd_pcm_t *, snd_pcm_hw_params_t *, unsigned, int);
    int r = real(p, h, v, dir);
    logf_("hw test_rate %p %u dir=%d -> %d", (void *)p, v, dir, r);
    return r;
}
EXPORT int snd_pcm_hw_params_set_period_size_near(snd_pcm_t *p, snd_pcm_hw_params_t *h, snd_pcm_uframes_t *v, int *dir) {
    REAL(int, snd_pcm_hw_params_set_period_size_near, snd_pcm_t *, snd_pcm_hw_params_t *, snd_pcm_uframes_t *, int *);
    unsigned long in = v ? *v : 0;
    int r = real(p, h, v, dir);
    logf_("hw set_period_size_near %p %lu -> %d (got %lu)", (void *)p, in, r, v ? *v : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_set_periods_near(snd_pcm_t *p, snd_pcm_hw_params_t *h, unsigned *v, int *dir) {
    REAL(int, snd_pcm_hw_params_set_periods_near, snd_pcm_t *, snd_pcm_hw_params_t *, unsigned *, int *);
    unsigned in = v ? *v : 0;
    int r = real(p, h, v, dir);
    logf_("hw set_periods_near %p %u -> %d (got %u)", (void *)p, in, r, v ? *v : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_set_buffer_size_near(snd_pcm_t *p, snd_pcm_hw_params_t *h, snd_pcm_uframes_t *v) {
    REAL(int, snd_pcm_hw_params_set_buffer_size_near, snd_pcm_t *, snd_pcm_hw_params_t *, snd_pcm_uframes_t *);
    unsigned long in = v ? *v : 0;
    int r = real(p, h, v);
    logf_("hw set_buffer_size_near %p %lu -> %d (got %lu)", (void *)p, in, r, v ? *v : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_get_period_size(const snd_pcm_hw_params_t *h, snd_pcm_uframes_t *v, int *dir) {
    REAL(int, snd_pcm_hw_params_get_period_size, const snd_pcm_hw_params_t *, snd_pcm_uframes_t *, int *);
    int r = real(h, v, dir);
    logf_("hw get_period_size -> %d (%lu)", r, v ? *v : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_get_periods(const snd_pcm_hw_params_t *h, unsigned *v, int *dir) {
    REAL(int, snd_pcm_hw_params_get_periods, const snd_pcm_hw_params_t *, unsigned *, int *);
    int r = real(h, v, dir);
    logf_("hw get_periods -> %d (%u)", r, v ? *v : 0);
    return r;
}
EXPORT int snd_pcm_hw_params_get_buffer_size(const snd_pcm_hw_params_t *h, snd_pcm_uframes_t *v) {
    REAL(int, snd_pcm_hw_params_get_buffer_size, const snd_pcm_hw_params_t *, snd_pcm_uframes_t *);
    int r = real(h, v);
    logf_("hw get_buffer_size -> %d (%lu)", r, v ? *v : 0);
    return r;
}

/* ---- sw params ---- */
EXPORT int snd_pcm_sw_params(snd_pcm_t *p, snd_pcm_sw_params_t *s) {
    REAL(int, snd_pcm_sw_params, snd_pcm_t *, snd_pcm_sw_params_t *);
    int r = real(p, s);
    logf_("sw_params (apply) %p -> %d", (void *)p, r);
    return r;
}
EXPORT int snd_pcm_sw_params_current(snd_pcm_t *p, snd_pcm_sw_params_t *s) {
    REAL(int, snd_pcm_sw_params_current, snd_pcm_t *, snd_pcm_sw_params_t *);
    int r = real(p, s);
    logf_("sw_params_current %p -> %d", (void *)p, r);
    return r;
}
#define SWSET(name)                                                                              \
    EXPORT int snd_pcm_sw_params_set_##name(snd_pcm_t *p, snd_pcm_sw_params_t *s, snd_pcm_uframes_t v) { \
        REAL(int, snd_pcm_sw_params_set_##name, snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t); \
        int r = real(p, s, v);                                                                   \
        logf_("sw set_" #name " %p %lu -> %d", (void *)p, v, r);                                 \
        return r;                                                                                \
    }
SWSET(avail_min)
SWSET(start_threshold)
SWSET(stop_threshold)
SWSET(silence_threshold)
SWSET(silence_size)
EXPORT int snd_pcm_sw_params_get_boundary(const snd_pcm_sw_params_t *s, snd_pcm_uframes_t *v) {
    REAL(int, snd_pcm_sw_params_get_boundary, const snd_pcm_sw_params_t *, snd_pcm_uframes_t *);
    int r = real(s, v);
    logf_("sw get_boundary -> %d (%lu)", r, v ? *v : 0);
    return r;
}

/* ---- per-period calls: counted, first few and errors logged ---- */
#define IOCALL(name, K, bufT)                                                                          \
    EXPORT snd_pcm_sframes_t snd_pcm_##name(snd_pcm_t *p, bufT b, snd_pcm_uframes_t n) {                \
        REAL(snd_pcm_sframes_t, snd_pcm_##name, snd_pcm_t *, bufT, snd_pcm_uframes_t);                   \
        snd_pcm_sframes_t r = real(p, b, n);                                                             \
        if (tick(p, K, r, r > 0 ? (unsigned long)r : 0)) logf_(#name " %p %lu -> %ld", (void *)p, n, r); \
        return r;                                                                                        \
    }
IOCALL(readi, K_READI, void *)
IOCALL(writei, K_WRITEI, const void *)
IOCALL(readn, K_READN, void **)
IOCALL(writen, K_WRITEN, void **)
#define SEEKCALL(name, K)                                                                              \
    EXPORT snd_pcm_sframes_t snd_pcm_##name(snd_pcm_t *p, snd_pcm_uframes_t n) {                        \
        REAL(snd_pcm_sframes_t, snd_pcm_##name, snd_pcm_t *, snd_pcm_uframes_t);                         \
        snd_pcm_sframes_t r = real(p, n);                                                                \
        if (tick(p, K, r, r > 0 ? (unsigned long)r : 0)) logf_(#name " %p %lu -> %ld", (void *)p, n, r); \
        return r;                                                                                        \
    }
SEEKCALL(forward, K_FWD)
SEEKCALL(rewind, K_REW)
EXPORT snd_pcm_sframes_t snd_pcm_avail(snd_pcm_t *p) {
    REAL(snd_pcm_sframes_t, snd_pcm_avail, snd_pcm_t *);
    snd_pcm_sframes_t r = real(p);
    if (tick(p, K_AVAIL, r, 0)) logf_("avail %p -> %ld", (void *)p, r);
    return r;
}
EXPORT snd_pcm_sframes_t snd_pcm_avail_update(snd_pcm_t *p) {
    REAL(snd_pcm_sframes_t, snd_pcm_avail_update, snd_pcm_t *);
    snd_pcm_sframes_t r = real(p);
    if (tick(p, K_AVAILU, r, 0)) logf_("avail_update %p -> %ld", (void *)p, r);
    return r;
}
EXPORT int snd_pcm_wait(snd_pcm_t *p, int timeout) {
    REAL(int, snd_pcm_wait, snd_pcm_t *, int);
    int r = real(p, timeout);
    if (tick(p, K_WAIT, r, 0)) logf_("wait %p timeout=%d -> %d", (void *)p, timeout, r);
    return r;
}
EXPORT int snd_pcm_poll_descriptors_count(snd_pcm_t *p) {
    REAL(int, snd_pcm_poll_descriptors_count, snd_pcm_t *);
    int r = real(p);
    if (tick(p, K_POLLCNT, r, 0)) logf_("poll_descriptors_count %p -> %d", (void *)p, r);
    return r;
}
EXPORT int snd_pcm_poll_descriptors(snd_pcm_t *p, struct pollfd *f, unsigned space) {
    REAL(int, snd_pcm_poll_descriptors, snd_pcm_t *, struct pollfd *, unsigned);
    int r = real(p, f, space);
    if (tick(p, K_POLL, r, 0)) logf_("poll_descriptors %p space=%u -> %d", (void *)p, space, r);
    return r;
}
EXPORT int snd_pcm_poll_descriptors_revents(snd_pcm_t *p, struct pollfd *f, unsigned nfds, unsigned short *rev) {
    REAL(int, snd_pcm_poll_descriptors_revents, snd_pcm_t *, struct pollfd *, unsigned, unsigned short *);
    int r = real(p, f, nfds, rev);
    if (tick(p, K_REVENTS, r, 0)) logf_("poll_descriptors_revents %p nfds=%u -> %d (revents 0x%x)", (void *)p, nfds, r, rev ? *rev : 0);
    return r;
}

/* ---- device enumeration (what MPC looks at while it builds its device list) ---- */
typedef struct _snd_ctl snd_ctl_t;
typedef struct _snd_ctl_card_info snd_ctl_card_info_t;
typedef struct _snd_pcm_info snd_pcm_info_t;
EXPORT int snd_card_next(int *card) {
    REAL(int, snd_card_next, int *);
    int in = card ? *card : -2;
    int r = real(card);
    logf_("card_next %d -> %d (%d)", in, r, card ? *card : -2);
    return r;
}
EXPORT int snd_ctl_open(snd_ctl_t **ctl, const char *name, int mode) {
    REAL(int, snd_ctl_open, snd_ctl_t **, const char *, int);
    int r = real(ctl, name, mode);
    logf_("ctl_open \"%s\" mode=0x%x -> %d %p", name ? name : "(null)", mode, r, r == 0 && ctl ? (void *)*ctl : NULL);
    return r;
}
EXPORT int snd_ctl_close(snd_ctl_t *ctl) {
    REAL(int, snd_ctl_close, snd_ctl_t *);
    int r = real(ctl);
    logf_("ctl_close %p -> %d", (void *)ctl, r);
    return r;
}
EXPORT int snd_ctl_pcm_next_device(snd_ctl_t *ctl, int *dev) {
    REAL(int, snd_ctl_pcm_next_device, snd_ctl_t *, int *);
    int in = dev ? *dev : -2;
    int r = real(ctl, dev);
    logf_("ctl_pcm_next_device %p %d -> %d (%d)", (void *)ctl, in, r, dev ? *dev : -2);
    return r;
}
EXPORT int snd_ctl_pcm_info(snd_ctl_t *ctl, snd_pcm_info_t *info) {
    REAL(int, snd_ctl_pcm_info, snd_ctl_t *, snd_pcm_info_t *);
    int r = real(ctl, info);
    logf_("ctl_pcm_info %p -> %d", (void *)ctl, r);
    return r;
}
EXPORT int snd_device_name_hint(int card, const char *iface, void ***hints) {
    REAL(int, snd_device_name_hint, int, const char *, void ***);
    int r = real(card, iface, hints);
    logf_("device_name_hint card=%d iface=%s -> %d", card, iface ? iface : "(null)", r);
    return r;
}
