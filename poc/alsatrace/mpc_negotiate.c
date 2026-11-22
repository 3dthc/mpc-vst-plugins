/* mpc_negotiate: run MPC's exact ALSA negotiation (from the alsatrace log on a Key 61) against a PCM and report what it gets.
 * MPC: open, hw_params_any, set_access RW_INTERLEAVED, set_format S32_LE, set_rate 44100 exact, set_channels_near 32,
 * set_period_size_near 192, set_periods_near 3 (playback) / 2 (capture), hw_params; sw: start = boundary, stop = buffer,
 * avail_min = period. Then streams 3 s duplex (silence out, capture in) and prints frames/s, xruns and capture ch1/ch2 peaks.
 * Usage: mpc_negotiate <pcm name> | mpc_negotiate --rate <card id>   (the latter builds a "type rate" PCM over hw:<card> at 48 kHz
 * from an inline config with snd_pcm_open_lconf, i.e. alsa-lib's rate converter without plug's channel/format conversion) */
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct snd_pcm snd_pcm_t; typedef struct snd_pcm_hw_params hw_t; typedef struct snd_pcm_sw_params sw_t;
typedef struct snd_config snd_config_t; typedef struct snd_input snd_input_t;
static void *h;
#define F(ret, name, ...) static ret (*name)(__VA_ARGS__)
F(int, p_open, snd_pcm_t **, const char *, int, int); F(int, p_open_lconf, snd_pcm_t **, const char *, int, int, snd_config_t *);
F(int, p_close, snd_pcm_t *); F(int, hw_malloc, hw_t **); F(int, hw_any, snd_pcm_t *, hw_t *);
F(int, hw_access, snd_pcm_t *, hw_t *, int); F(int, hw_format, snd_pcm_t *, hw_t *, int); F(int, hw_rate, snd_pcm_t *, hw_t *, unsigned, int);
F(int, hw_ch_near, snd_pcm_t *, hw_t *, unsigned *); F(int, hw_ch_min, const hw_t *, unsigned *); F(int, hw_ch_max, const hw_t *, unsigned *);
F(int, hw_per_near, snd_pcm_t *, hw_t *, unsigned long *, int *); F(int, hw_pers_near, snd_pcm_t *, hw_t *, unsigned *, int *);
F(int, hw_apply, snd_pcm_t *, hw_t *); F(int, hw_get_buf, const hw_t *, unsigned long *);
F(int, sw_malloc, sw_t **); F(int, sw_cur, snd_pcm_t *, sw_t *); F(int, sw_bound, const sw_t *, unsigned long *);
F(int, sw_start, snd_pcm_t *, sw_t *, unsigned long); F(int, sw_stop, snd_pcm_t *, sw_t *, unsigned long);
F(int, sw_avail, snd_pcm_t *, sw_t *, unsigned long); F(int, sw_apply, snd_pcm_t *, sw_t *);
F(int, p_prepare, snd_pcm_t *); F(int, p_start, snd_pcm_t *); F(long, p_writei, snd_pcm_t *, const void *, unsigned long);
F(long, p_readi, snd_pcm_t *, void *, unsigned long); F(int, p_drop, snd_pcm_t *); F(const char *, p_err, int);
F(int, cfg_top, snd_config_t **); F(int, in_buf, snd_input_t **, const char *, long); F(int, cfg_load, snd_config_t *, snd_input_t *);
F(int, in_close, snd_input_t *);

static snd_config_t *g_cfg;
static int open_pcm(snd_pcm_t **p, const char *name, int stream) {
    return g_cfg ? p_open_lconf(p, name, stream, 0, g_cfg) : p_open(p, name, stream, 0);
}

static int negotiate(const char *name, int stream, unsigned periods, snd_pcm_t **out, unsigned *ch, unsigned long *per, unsigned long *buf) {
    const char *sn = stream ? "capture " : "playback";
    snd_pcm_t *p; hw_t *hw; sw_t *sw; int r, dir = 0;
    if ((r = open_pcm(&p, name, stream)) < 0) { printf("  %s: open -> %s\n", sn, p_err(r)); return r; }
    hw_malloc(&hw); hw_any(p, hw);
    unsigned mn = 0, mx = 0; hw_ch_min(hw, &mn); hw_ch_max(hw, &mx);
    if ((r = hw_access(p, hw, 3)) < 0 || (r = hw_format(p, hw, 10)) < 0) { printf("  %s: access/format -> %s\n", sn, p_err(r)); p_close(p); return r; }
    if ((r = hw_rate(p, hw, 44100, 0)) < 0) { printf("  %s: set_rate 44100 exact -> %d (%s)  [channels offered %u..%u]\n", sn, r, p_err(r), mn, mx); p_close(p); return r; }
    *ch = 32; hw_ch_near(p, hw, ch);
    *per = 192; hw_per_near(p, hw, per, &dir);
    unsigned ps = periods; hw_pers_near(p, hw, &ps, &dir);
    if ((r = hw_apply(p, hw)) < 0) { printf("  %s: hw_params -> %s\n", sn, p_err(r)); p_close(p); return r; }
    hw_get_buf(hw, buf);
    sw_malloc(&sw); sw_cur(p, sw); unsigned long b; sw_bound(sw, &b);
    sw_start(p, sw, b); sw_stop(p, sw, *buf); sw_avail(p, sw, *per); sw_apply(p, sw);
    printf("  %s: OK  channels offered %u..%u, near 32 -> %u; period %lu, periods %u, buffer %lu\n", sn, mn, mx, *ch, *per, ps, *buf);
    *out = p; return 0;
}

static volatile int g_stop; static snd_pcm_t *g_pb; static unsigned g_pch; static unsigned long g_pper, g_pxr;
static void *play(void *a) { (void)a; int32_t *z = calloc(g_pper * g_pch, 4);
    while (!g_stop) { long n = p_writei(g_pb, z, g_pper); if (n < 0) { g_pxr++; p_prepare(g_pb); p_start(g_pb); } }
    free(z); return NULL; }

#define S(v, n) do { *(void **)&v = dlsym(h, n); if (!v) { printf("missing %s\n", n); return 1; } } while (0)
int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: %s <pcm> | --rate <card>\n", argv[0]); return 2; }
    h = dlopen("libasound.so.2", RTLD_NOW); if (!h) return 1;
    S(p_open, "snd_pcm_open"); S(p_open_lconf, "snd_pcm_open_lconf"); S(p_close, "snd_pcm_close"); S(hw_malloc, "snd_pcm_hw_params_malloc");
    S(hw_any, "snd_pcm_hw_params_any"); S(hw_access, "snd_pcm_hw_params_set_access"); S(hw_format, "snd_pcm_hw_params_set_format");
    S(hw_rate, "snd_pcm_hw_params_set_rate"); S(hw_ch_near, "snd_pcm_hw_params_set_channels_near"); S(hw_ch_min, "snd_pcm_hw_params_get_channels_min");
    S(hw_ch_max, "snd_pcm_hw_params_get_channels_max"); S(hw_per_near, "snd_pcm_hw_params_set_period_size_near");
    S(hw_pers_near, "snd_pcm_hw_params_set_periods_near"); S(hw_apply, "snd_pcm_hw_params"); S(hw_get_buf, "snd_pcm_hw_params_get_buffer_size");
    S(sw_malloc, "snd_pcm_sw_params_malloc"); S(sw_cur, "snd_pcm_sw_params_current"); S(sw_bound, "snd_pcm_sw_params_get_boundary");
    S(sw_start, "snd_pcm_sw_params_set_start_threshold"); S(sw_stop, "snd_pcm_sw_params_set_stop_threshold");
    S(sw_avail, "snd_pcm_sw_params_set_avail_min"); S(sw_apply, "snd_pcm_sw_params"); S(p_prepare, "snd_pcm_prepare"); S(p_start, "snd_pcm_start");
    S(p_writei, "snd_pcm_writei"); S(p_readi, "snd_pcm_readi"); S(p_drop, "snd_pcm_drop"); S(p_err, "snd_strerror");
    S(cfg_top, "snd_config_top"); S(in_buf, "snd_input_buffer_open"); S(cfg_load, "snd_config_load"); S(in_close, "snd_input_close");

    const char *name = argv[1];
    if (!strcmp(argv[1], "--rate") && argc > 2) {
        static char cfg[512];
        snprintf(cfg, sizeof cfg, "pcm.mpcrate { type rate slave { pcm { type hw card \"%s\" device 0 } rate 48000 } }", argv[2]);
        snd_input_t *in; cfg_top(&g_cfg); in_buf(&in, cfg, -1);
        int r = cfg_load(g_cfg, in); in_close(in);
        if (r < 0) { printf("config: %s\n", p_err(r)); return 1; }
        name = "mpcrate"; printf("== rate converter over hw:%s (inline config)\n", argv[2]);
    } else printf("== %s\n", name);

    snd_pcm_t *pb = NULL, *cap = NULL; unsigned pch = 0, cch = 0; unsigned long pper, pbuf, cper, cbuf;
    int a = negotiate(name, 0, 3, &pb, &pch, &pper, &pbuf), b = negotiate(name, 1, 2, &cap, &cch, &cper, &cbuf);
    if (a < 0 || b < 0) { if (pb) p_close(pb); if (cap) p_close(cap); return 0; }

    p_drop(cap); p_drop(pb); p_prepare(cap); p_prepare(pb);
    int32_t *z = calloc(pper * pch, 4); for (int i = 0; i < 3; i++) p_writei(pb, z, pper);
    p_start(cap); p_start(pb);
    g_pb = pb; g_pch = pch; g_pper = pper; pthread_t th; pthread_create(&th, NULL, play, NULL);
    int32_t *buf = malloc(cper * cch * 4); double pk[2] = {0, 0}; unsigned long tot = 0, cxr = 0;
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    while (tot < 44100UL * 3) {
        long n = p_readi(cap, buf, cper);
        if (n < 0) { cxr++; p_prepare(cap); p_start(cap); continue; }
        for (long f = 0; f < n; f++) for (int c = 0; c < 2 && c < (int)cch; c++) { double v = fabs(buf[f * cch + c] / 2147483648.0); if (v > pk[c]) pk[c] = v; }
        tot += n;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1); g_stop = 1; pthread_join(th, NULL);
    double el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("  stream: %.1f frames/s, capture xruns %lu, playback xruns %lu, ch1 peak %.1f dBFS, ch2 peak %.1f dBFS\n", tot / el, cxr, g_pxr,
           pk[0] > 0 ? 20 * log10(pk[0]) : -999.0, pk[1] > 0 ? 20 * log10(pk[1]) : -999.0);
    p_close(cap); p_close(pb);
    return 0;
}
