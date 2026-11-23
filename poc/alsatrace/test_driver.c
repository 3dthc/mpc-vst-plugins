/* test_driver: makes the ALSA calls MPC makes when it opens an audio device (the order JUCE's ALSA code uses), on
 * alsa-lib's "null" PCM, and prints every result. test.sh runs it with and without libalsatrace.so preloaded and
 * compares the output, so the probe is shown to change nothing. */
#include <alsa/asoundlib.h>
#include <stdio.h>

#define P(expr) printf("%-60s %ld\n", #expr, (long)(expr))

static void setup(snd_pcm_t *pcm) {
    snd_pcm_hw_params_t *hw;
    snd_pcm_sw_params_t *sw;
    unsigned ch = 2, rate = 44100;
    int dir = 0;
    snd_pcm_uframes_t per = 192, buf = 576, b;
    snd_pcm_hw_params_alloca(&hw);
    snd_pcm_sw_params_alloca(&sw);
    P(snd_pcm_hw_params_any(pcm, hw));
    P(snd_pcm_hw_params_test_rate(pcm, hw, 44100, 0));
    P(snd_pcm_hw_params_test_format(pcm, hw, SND_PCM_FORMAT_S32_LE));
    P(snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED));
    P(snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S32_LE));
    unsigned mn = 0, mx = 0;
    P(snd_pcm_hw_params_get_channels_min(hw, &mn));
    P(snd_pcm_hw_params_get_channels_max(hw, &mx));
    P(snd_pcm_hw_params_set_channels_near(pcm, hw, &ch));
    P(snd_pcm_hw_params_set_rate(pcm, hw, 44100, 0));
    P(snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, &dir));
    P(snd_pcm_hw_params_set_period_size_near(pcm, hw, &per, &dir));
    P(snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buf));
    P(snd_pcm_hw_params(pcm, hw));
    P(snd_pcm_hw_params_get_period_size(hw, &per, &dir));
    P(snd_pcm_hw_params_get_buffer_size(hw, &buf));
    printf("channels %u rate %u period %lu buffer %lu (min %u max %u)\n", ch, rate, per, buf, mn, mx);
    P(snd_pcm_sw_params_current(pcm, sw));
    P(snd_pcm_sw_params_get_boundary(sw, &b));
    P(snd_pcm_sw_params_set_start_threshold(pcm, sw, b));
    P(snd_pcm_sw_params_set_stop_threshold(pcm, sw, buf));
    P(snd_pcm_sw_params_set_avail_min(pcm, sw, per));
    P(snd_pcm_sw_params(pcm, sw));
}

int main(void) {
    int card = -1;
    while (snd_card_next(&card) == 0 && card >= 0) { char n[32]; snd_ctl_t *c; snprintf(n, sizeof n, "hw:%d", card); if (snd_ctl_open(&c, n, 0) == 0) snd_ctl_close(c); }
    P(snd_card_next(&card) == 0);
    { snd_ctl_t *c = NULL; int r = snd_ctl_open(&c, "hw:0", 0); printf("ctl_open hw:0 %s\n", r == 0 ? "ok" : "failed"); if (r == 0) snd_ctl_close(c); }
    snd_pcm_t *pb = NULL, *cap = NULL;
    static int32_t frames[192 * 2];
    P(snd_pcm_open(&pb, "null", SND_PCM_STREAM_PLAYBACK, 0));
    P(snd_pcm_open(&cap, "null", SND_PCM_STREAM_CAPTURE, 0));
    setup(pb);
    setup(cap);
    P(snd_pcm_link(cap, pb) <= 0);   /* the null PCM may refuse linking; only the result's sign is compared */
    P(snd_pcm_prepare(pb));
    P(snd_pcm_poll_descriptors_count(pb));
    P(snd_pcm_writei(pb, frames, 192));
    P(snd_pcm_start(pb));
    for (int i = 0; i < 20; i++) {
        long w = snd_pcm_writei(pb, frames, 192), r = snd_pcm_readi(cap, frames, 192);
        if (i == 0 || i == 19) printf("loop %d writei %ld readi %ld\n", i, w, r);
    }
    P(snd_pcm_avail(pb) >= 0);
    P(snd_pcm_drop(pb));
    P(snd_pcm_close(cap));
    P(snd_pcm_close(pb));
    return 0;
}
