/* The saved state shared by the device VST2 and the desktop VST3, so a project saved with one opens with the other
 * (an MPC project made on the device and opened in MPC Desktop's controller mode with the VST3, say).
 *
 *   - An engine with a "state" key: its text, as is (what the VST2 chunk has always been).
 *   - An engine without one: "mpc-vst3 params\n" then one key=value line per setting (popup flags, momentary, stepper,
 *     text readouts and "live" values left out): the VST3 already saved this, and the VST2 chunk now does too
 *     (it used to be empty, so such a plugin came back at its defaults in a saved project).
 *
 * mpc_state_unwrap() finds that text inside whatever a host hands over: the VST3's own "mpc-vst3 state\n" /
 * "mpc-vst3 params\n" text (with its \x01 wrapper settings after it), a raw VST2 chunk, or a VST2 chunk that a host
 * wrapped when it moved a project from the VST2 to the VST3 ("VstW" header, then an fxBank / fxProgram "CcnK" block,
 * as Steinberg's VST2 compatibility and JUCE do). Header-only; the caller supplies its engine get/set. */
#ifndef MPC_STATE_TEXT_H
#define MPC_STATE_TEXT_H

#include <stdint.h>
#include <string.h>
#include <stdio.h>

#define MPC_STATE_PARAMS_HDR "mpc-vst3 params\n"
#define MPC_STATE_STATE_HDR "mpc-vst3 state\n"

typedef int (*mpc_state_get_fn)(void *w, const char *k, char *buf, int n);
typedef void (*mpc_state_set_fn)(void *w, const char *k, const char *v);

static inline int mpc_state_skip(int i) {   /* not a setting: never saved, never restored */
    const param_t *p = &PARAMS[i];
    if (popup_is(i) || p->momentary || p->step_target >= 0 || p->string_display) return 1;
#ifdef PLUG_LIVE_COUNT
    for (int k = 0; k < PLUG_LIVE_COUNT; k++) if (PLUG_LIVE[k] == i) return 1;
#endif
    return 0;
}

/* The params text into out (NUL-terminated); its length, or -1 if it did not fit. */
static inline int mpc_state_params_text(void *w, mpc_state_get_fn get, char *out, int cap) {
    int len = snprintf(out, cap, "%s", MPC_STATE_PARAMS_HDR);
    if (len < 0 || len >= cap) return -1;
    for (int i = 0; i < NPARAMS; i++) {
        char buf[96];
        if (mpc_state_skip(i) || get(w, PARAMS[i].key, buf, sizeof buf) <= 0) continue;
        buf[sizeof buf - 1] = 0;
        int n = snprintf(out + len, cap - len, "%s=%s\n", PARAMS[i].key, buf);
        if (n < 0 || n >= cap - len) return -1;
        len += n;
    }
    return len;
}

/* key=value lines (text after the params header) back into the engine; text is modified. */
static inline void mpc_state_apply_params(void *w, mpc_state_set_fn set, char *text) {
    for (char *line = text, *next; line && *line; line = next) {
        next = strchr(line, '\n');
        if (next) *next++ = 0;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        for (int i = 0; i < NPARAMS; i++)
            if (!strcmp(PARAMS[i].key, line)) { if (!mpc_state_skip(i)) set(w, line, eq + 1); break; }
    }
}

static inline uint32_t mpc_be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* A VST2 chunk a host wrapped: the chunk's offset and length inside buf, or 0 if buf is not such a block. */
static inline int mpc_state_vst2_block(const uint8_t *buf, int len, int *off, int *n) {
    int base = 0;
    if (len >= 12 && !memcmp(buf, "VstW", 4)) {   /* 'VstW', header length, version, bypass, then the block */
        uint32_t hl = mpc_be32(buf + 4);
        if (hl > (uint32_t)len - 8) return 0;
        base = 8 + (int)hl;
    }
    if (len - base < 60 || memcmp(buf + base, "CcnK", 4)) return 0;
    int at;
    if (!memcmp(buf + base + 8, "FBCh", 4)) at = base + 156;        /* fxBank: 7 ints, 128 reserved, size, chunk */
    else if (!memcmp(buf + base + 8, "FPCh", 4)) at = base + 56;    /* fxProgram: 7 ints, 28-byte name, size, chunk */
    else return 0;                                                   /* FxCk / FxBk (parameter floats): never ours */
    if (len - at < 4) return 0;
    uint32_t sz = mpc_be32(buf + at);
    if (sz > (uint32_t)(len - at - 4)) sz = (uint32_t)(len - at - 4);
    *off = at + 4;
    *n = (int)sz;
    return 1;
}

/* Restore from buf (len bytes, buf[len] writable: it becomes the terminator). Returns a pointer to the wrapper's own
 * settings after \x01 (the VST3's program/bypass), or NULL; *ok is 1 when something was restored. buf is modified. */
static inline char *mpc_state_restore(void *w, mpc_state_set_fn set, char *buf, int len, int *ok) {
    *ok = 0;
    int off = 0, n = len;
    if (mpc_state_vst2_block((const uint8_t *)buf, len, &off, &n)) { memmove(buf, buf + off, n); len = n; }
    buf[len] = 0;
    while (len > 0 && buf[len - 1] == 0) len--;   /* a VST2 chunk ends with its NUL */
    char *own = NULL;
    for (int i = 0; i < len; i++)
        if (buf[i] == '\x01') { own = buf + i + 1; buf[i > 0 && buf[i - 1] == '\n' ? i - 1 : i] = 0; break; }
    if (!strncmp(buf, MPC_STATE_STATE_HDR, strlen(MPC_STATE_STATE_HDR))) {
        set(w, "state", buf + strlen(MPC_STATE_STATE_HDR));
        *ok = 1;
    } else if (!strncmp(buf, MPC_STATE_PARAMS_HDR, strlen(MPC_STATE_PARAMS_HDR))) {
        mpc_state_apply_params(w, set, buf + strlen(MPC_STATE_PARAMS_HDR));
        *ok = 1;
    } else if (buf[0]) {   /* a raw VST2 chunk: the engine's own state text (an engine without "state" ignores it) */
        set(w, "state", buf);
        *ok = 1;
    }
    return own;
}

#endif
