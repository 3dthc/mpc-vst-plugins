/* au_wrap.m — the port as an Audio Unit (AUv2) for Logic Pro, GarageBand and every macOS AU host.
 *
 * The AU drives the port's own VST3 (vst3_wrap.c, linked into the same binary) through its VST3 interfaces, so the sound,
 * the skin as the plugin window, programs, saved state and the window-size menu are the ones the VST3 has, with nothing
 * to keep in step. Built by tools/build_vst3.sh (VST3_TARGET=macos) into <name>.component next to <name>.vst3; Apple's auval
 * checks it in releases (tools/release_vst3.sh).
 *
 *   AU                                       VST3 (this binary)
 *   parameters (the host-listed controls)    parameter IDs, normalized 0..1 (list parameters: indexed, with names)
 *   factory presets / present preset         the program list (IUnitInfo) and the program parameter
 *   ClassInfo (the host's saved state)       IComponent::getState / setState, in "vst3-state"
 *   MusicDeviceMIDIEvent                     note events; controllers, pitch bend and aftertouch through IMidiMapping
 *   Cocoa view                               IPlugView "NSView" in the view the host shows
 *
 * Everything that has a name in the Objective-C runtime carries the plugin's own (MPC_AU_TAG): every plugin in a process
 * shares one class namespace. */
#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#include <pthread.h>
#include <stdatomic.h>
#include "vst3_abi.h"
#include "params.h"   /* PLUG_EFFECT */
#include <string.h>
#include <math.h>

#ifndef MPC_AU_TAG
#error MPC_AU_TAG must be defined (tools/build_vst3.sh does)
#endif
#define AU_CAT2(a, b) a##b
#define AU_CAT(a, b) AU_CAT2(a, b)
#define AU_VIEW_FACTORY AU_CAT(MPCAUViewFactory_, MPC_AU_TAG)
#define AU_VIEW AU_CAT(MPCAUView_, MPC_AU_TAG)
#define AU_STR2(x) #x
#define AU_STR(x) AU_STR2(x)

void *GetPluginFactory(void);   /* vst3_wrap.c */
int bundleEntry(void *);
static const TUID iid_IComponentHandler = IID(0x93A0BEA3u, 0x0BD045DBu, 0x8E890B0Cu, 0xC1E46AC6u);
static int iid_eq(const void *a, const void *b) { return !memcmp(a, b, 16); }

#define kMPCInstanceProperty 64099   /* private: the view factory asks for the instance behind an AudioUnit */
#define MAX_FRAMES_DEFAULT 4096
#define MAX_PARAMS 1024
#define MIDI_RING 512
#define PENDING_MAX 256

typedef struct { const IBStreamVtbl *v; uint8_t *buf; int64_t len, cap, pos; } mstream_t;
static tresult ms_q(void *s, const TUID i, void **o) { (void)s; (void)i; *o = NULL; return kNoInterface; }
static uint32_t ms_one(void *s) { (void)s; return 1; }
static tresult ms_read(void *s, void *b, int32_t n, int32_t *done) {
    mstream_t *m = s;
    int64_t k = m->len - m->pos;
    if (k > n) k = n;
    if (k < 0) k = 0;
    memcpy(b, m->buf + m->pos, (size_t)k);
    m->pos += k;
    if (done) *done = (int32_t)k;
    return kResultOk;
}
static tresult ms_write(void *s, void *b, int32_t n, int32_t *done) {
    mstream_t *m = s;
    if (m->pos + n > m->cap) {
        int64_t c = (m->pos + n) * 2 + 1024;
        uint8_t *nb = realloc(m->buf, (size_t)c);
        if (!nb) return kResultFalse;
        m->buf = nb; m->cap = c;
    }
    memcpy(m->buf + m->pos, b, (size_t)n);
    m->pos += n;
    if (m->pos > m->len) m->len = m->pos;
    if (done) *done = n;
    return kResultOk;
}
static tresult ms_seek(void *s, int64_t p, int32_t mode, int64_t *r) {
    mstream_t *m = s;
    int64_t np = mode == 0 ? p : mode == 1 ? m->pos + p : m->len + p;
    if (np < 0) np = 0;
    m->pos = np;
    if (r) *r = np;
    return kResultOk;
}
static tresult ms_tell(void *s, int64_t *p) { *p = ((mstream_t *)s)->pos; return kResultOk; }
static const IBStreamVtbl ms_vt = { ms_q, ms_one, ms_one, ms_read, ms_write, ms_seek, ms_tell };

/* parameter changes for one process() call */
typedef struct { const IParamValueQueueVtbl *v; uint32_t id; int n; int32_t off[8]; double val[8]; } pq_t;
typedef struct { const IParameterChangesVtbl *v; int n; pq_t q[PENDING_MAX]; } pc_t;
static uint32_t pq_id(void *s) { return ((pq_t *)s)->id; }
static int32_t pq_count(void *s) { return ((pq_t *)s)->n; }
static tresult pq_get(void *s, int32_t i, int32_t *o, double *v) {
    pq_t *q = s;
    if (i < 0 || i >= q->n) return kResultFalse;
    *o = q->off[i]; *v = q->val[i];
    return kResultOk;
}
static tresult pq_add(void *s, int32_t o, double v, int32_t *i) {
    pq_t *q = s;
    if (q->n == 8) { q->off[7] = o; q->val[7] = v; if (i) *i = 7; return kResultOk; }
    q->off[q->n] = o; q->val[q->n] = v;
    if (i) *i = q->n;
    q->n++;
    return kResultOk;
}
static const IParamValueQueueVtbl pq_vt = { ms_q, ms_one, ms_one, pq_id, pq_count, pq_get, pq_add };
static int32_t pc_count(void *s) { return ((pc_t *)s)->n; }
static IParamValueQueue *pc_get(void *s, int32_t i) { pc_t *c = s; return i >= 0 && i < c->n ? (IParamValueQueue *)&c->q[i] : NULL; }
static IParamValueQueue *pc_add(void *s, const uint32_t *id, int32_t *i) {
    pc_t *c = s;
    for (int k = 0; k < c->n; k++) if (c->q[k].id == *id) { if (i) *i = k; return (IParamValueQueue *)&c->q[k]; }
    if (c->n == PENDING_MAX) return NULL;
    pq_t *q = &c->q[c->n];
    q->v = &pq_vt; q->id = *id; q->n = 0;
    if (i) *i = c->n;
    c->n++;
    return (IParamValueQueue *)q;
}
static const IParameterChangesVtbl pc_vt = { ms_q, ms_one, ms_one, pc_count, pc_get, pc_add };

typedef struct { const IEventListVtbl *v; int n; Event e[MIDI_RING]; } ev_t;
static int32_t ev_count(void *s) { return ((ev_t *)s)->n; }
static tresult ev_get(void *s, int32_t i, Event *e) { ev_t *l = s; if (i < 0 || i >= l->n) return kResultFalse; *e = l->e[i]; return kResultOk; }
static tresult ev_add(void *s, Event *e) { ev_t *l = s; if (l->n == MIDI_RING) return kResultFalse; l->e[l->n++] = *e; return kResultOk; }
static const IEventListVtbl ev_vt = { ms_q, ms_one, ms_one, ev_count, ev_get, ev_add };

typedef struct au au_t;
typedef struct {
    const IComponentHandlerVtbl *v;
    au_t *au;
} handler_t;

typedef struct { uint32_t id; double v; } pend_t;
typedef struct { uint8_t b[3]; uint32_t off; } midi_t;
typedef struct { AudioUnitPropertyID id; AudioUnitPropertyListenerProc proc; void *ud; } listener_t;

struct au {
    AudioComponentPlugInInterface iface;   /* first: the host calls through it */
    AudioComponentInstance inst;
    void *comp, *proc, *ctrl, *midimap, *unitinfo;
    const ComponentVtbl *c;
    const ProcessorVtbl *p;
    const ControllerVtbl *e;
    handler_t handler;
    double rate;
    UInt32 max_frames;
    int initialized, effect, bypass;
    float *scratch[4];                       /* outputs (and inputs, effects) when the host gives no buffers */
    AURenderCallbackStruct input_cb;
    AudioUnitConnection conn;
    int has_conn, has_cb;
    HostCallbackInfo host;
    /* the visible (host-listed) parameters */
    int nparams;
    uint32_t pid[MAX_PARAMS];
    int psteps[MAX_PARAMS];
    /* changes waiting for the next render, from the host (SetParameter) and the view (performEdit) */
    pthread_mutex_t lock;
    pend_t pend[PENDING_MAX];
    int npend;
    midi_t midi[MIDI_RING];
    _Atomic int mhead, mtail;
    listener_t listeners[64];
    int nlisteners;
    struct { AURenderCallback proc; void *ud; } notify[8];
    int nnotify;
    /* presets */
    int nprog;
    AUPreset *factory;
    AUPreset present;
    int prog_seen;
    pc_t inpc, outpc;
    ev_t events;
};

#define AU(s) ((au_t *)(s))
#define VTP(T, p) (*(const T *const *)(p))

/* ---- helpers ---------------------------------------------------------------------- */
static void utf16_to_utf8(const char16 *s, char *out, int n) {
    int i = 0;
    for (; s[i] && i < n - 1; i++) out[i] = s[i] < 128 ? (char)s[i] : '?';
    out[i] = 0;
}
static CFStringRef cfstr16(const char16 *s) {
    int n = 0;
    while (n < 128 && s[n]) n++;
    return CFStringCreateWithCharacters(NULL, (const UniChar *)s, n);
}
static void notify_prop(au_t *a, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el) {
    for (int i = 0; i < a->nlisteners; i++)
        if (a->listeners[i].id == id) a->listeners[i].proc(a->listeners[i].ud, a->inst, id, scope, el);
}
static void param_event(au_t *a, AudioUnitEventType t, uint32_t id) {
    AudioUnitEvent ev;
    memset(&ev, 0, sizeof ev);
    ev.mEventType = t;
    ev.mArgument.mParameter.mAudioUnit = a->inst;
    ev.mArgument.mParameter.mParameterID = id;
    ev.mArgument.mParameter.mScope = kAudioUnitScope_Global;
    ev.mArgument.mParameter.mElement = 0;
    AUEventListenerNotify(NULL, NULL, &ev);
}
static void queue_change(au_t *a, uint32_t id, double v) {
    pthread_mutex_lock(&a->lock);
    int k = 0;
    for (; k < a->npend; k++) if (a->pend[k].id == id) break;
    if (k == a->npend && a->npend < PENDING_MAX) a->npend++;
    if (k < PENDING_MAX) { a->pend[k].id = id; a->pend[k].v = v; }
    pthread_mutex_unlock(&a->lock);
}
static int find_param(au_t *a, uint32_t id) {
    for (int i = 0; i < a->nparams; i++) if (a->pid[i] == id) return i;
    return -1;
}
static uint32_t prog_param(au_t *a) {
    int n = a->e->getParameterCount(a->ctrl);
    for (int i = 0; i < n; i++) {
        ParameterInfo pi;
        if (a->e->getParameterInfo(a->ctrl, i, &pi) == kResultOk && (pi.flags & kIsProgramChange)) return pi.id;
    }
    return 0xFFFFFFFFu;
}
static int cur_prog(au_t *a) {
    uint32_t id = prog_param(a);
    if (id == 0xFFFFFFFFu || a->nprog < 2) return 0;
    return (int)lround(a->e->getParamNormalized(a->ctrl, id) * (a->nprog - 1));
}
static void build_presets(au_t *a) {
    a->nprog = 0;
    if (!a->unitinfo) return;
    const UnitInfoVtbl *u = VTP(UnitInfoVtbl, a->unitinfo);
    ProgramListInfo li;
    if (u->getProgramListCount(a->unitinfo) < 1 || u->getProgramListInfo(a->unitinfo, 0, &li) != kResultOk || li.programCount < 1) return;
    a->factory = calloc((size_t)li.programCount, sizeof(AUPreset));
    if (!a->factory) return;
    for (int i = 0; i < li.programCount; i++) {
        char16 nm[128] = { 0 };
        u->getProgramName(a->unitinfo, li.id, i, nm);
        a->factory[i].presetNumber = i;
        a->factory[i].presetName = cfstr16(nm);
    }
    a->nprog = li.programCount;
}
static void sync_present(au_t *a, int notify) {   /* the present preset follows the plugin's program */
    if (a->nprog < 1) return;
    int p = cur_prog(a);
    if (p < 0 || p >= a->nprog) return;
    if (p == a->prog_seen && a->present.presetNumber == p) return;
    a->prog_seen = p;
    if (a->present.presetName) CFRelease(a->present.presetName);
    a->present.presetNumber = p;
    a->present.presetName = (CFStringRef)CFRetain(a->factory[p].presetName);
    if (notify) notify_prop(a, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
}

/* ---- IComponentHandler: edits from the plugin's own window --------------------------- */
static tresult h_query(void *s, const TUID iid, void **o) {
    if (iid_eq(iid, iid_FUnknown) || iid_eq(iid, iid_IComponentHandler)) { *o = s; return kResultOk; }
    *o = NULL;
    return kNoInterface;
}
static uint32_t h_ref(void *s) { (void)s; return 1; }
static tresult h_begin(void *s, uint32_t id) {
    au_t *a = ((handler_t *)s)->au;
    if (find_param(a, id) >= 0) param_event(a, kAudioUnitEvent_BeginParameterChangeGesture, id);
    return kResultOk;
}
static tresult h_perform(void *s, uint32_t id, double v) {
    au_t *a = ((handler_t *)s)->au;
    queue_change(a, id, v);
    if (find_param(a, id) >= 0) param_event(a, kAudioUnitEvent_ParameterValueChange, id);
    return kResultOk;
}
static tresult h_end(void *s, uint32_t id) {
    au_t *a = ((handler_t *)s)->au;
    if (find_param(a, id) >= 0) param_event(a, kAudioUnitEvent_EndParameterChangeGesture, id);
    return kResultOk;
}
static tresult h_restart(void *s, int32_t flags) {
    au_t *a = ((handler_t *)s)->au;
    (void)flags;
    AudioUnitParameter any = { a->inst, kAUParameterListener_AnyParameter, kAudioUnitScope_Global, 0 };
    AUParameterListenerNotify(NULL, NULL, &any);   /* every value may have changed (a program): hosts re-read */
    sync_present(a, 1);
    return kResultOk;
}
static const IComponentHandlerVtbl h_vt = { h_query, h_ref, h_ref, h_begin, h_perform, h_end, h_restart };

/* ---- open / close -------------------------------------------------------------------- */
static OSStatus au_open(void *s, AudioComponentInstance inst) {
    au_t *a = AU(s);
    a->inst = inst;
    bundleEntry(NULL);
    void *f = GetPluginFactory();
    const FactoryVtbl *fv = VTP(FactoryVtbl, f);
    PClassInfo ci;
    if (fv->getClassInfo(f, 0, &ci) != kResultOk) return kAudioUnitErr_FailedInitialization;
    if (fv->createInstance(f, (const char *)ci.cid, (const char *)iid_IComponent, &a->comp) != kResultOk || !a->comp)
        return kAudioUnitErr_FailedInitialization;
    a->c = VTP(ComponentVtbl, a->comp);
    if (a->c->initialize(a->comp, NULL) != kResultOk) return kAudioUnitErr_FailedInitialization;
    a->c->queryInterface(a->comp, iid_IAudioProcessor, &a->proc);
    a->c->queryInterface(a->comp, iid_IEditController, &a->ctrl);
    if (!a->proc || !a->ctrl) return kAudioUnitErr_FailedInitialization;
    a->p = VTP(ProcessorVtbl, a->proc);
    a->e = VTP(ControllerVtbl, a->ctrl);
    a->e->initialize(a->ctrl, NULL);
    a->handler.v = &h_vt;
    a->handler.au = a;
    a->e->setComponentHandler(a->ctrl, (IComponentHandler *)&a->handler);
    if (a->c->queryInterface(a->comp, iid_IMidiMapping, &a->midimap) != kResultOk) a->midimap = NULL;
    if (a->c->queryInterface(a->comp, iid_IUnitInfo, &a->unitinfo) != kResultOk) a->unitinfo = NULL;
#ifdef PLUG_EFFECT
    a->effect = 1;
#endif
    a->rate = 44100;
    a->max_frames = MAX_FRAMES_DEFAULT;
    pthread_mutex_init(&a->lock, NULL);
    /* the host-listed parameters: the controls the VST3 lists (not hidden, not the program, bypass or MIDI helpers) */
    int n = a->e->getParameterCount(a->ctrl);
    for (int i = 0; i < n && a->nparams < MAX_PARAMS; i++) {
        ParameterInfo pi;
        if (a->e->getParameterInfo(a->ctrl, i, &pi) != kResultOk) continue;
        if (pi.flags & (kIsHidden | kIsProgramChange | kIsBypass)) continue;
        a->psteps[a->nparams] = (pi.flags & kIsList) ? pi.stepCount : 0;
        a->pid[a->nparams++] = pi.id;
    }
    build_presets(a);
    a->prog_seen = -1;
    sync_present(a, 0);
    a->inpc.v = &pc_vt;
    a->outpc.v = &pc_vt;
    a->events.v = &ev_vt;
    return noErr;
}

static OSStatus au_close(void *s) {
    au_t *a = AU(s);
    if (a->initialized) { a->p->setProcessing(a->proc, 0); a->c->setActive(a->comp, 0); }
    if (a->ctrl) { a->e->setComponentHandler(a->ctrl, NULL); a->e->terminate(a->ctrl); a->e->release(a->ctrl); }
    if (a->midimap) VTP(MidiMappingVtbl, a->midimap)->release(a->midimap);
    if (a->unitinfo) VTP(UnitInfoVtbl, a->unitinfo)->release(a->unitinfo);
    if (a->proc) a->p->release(a->proc);
    if (a->comp) { a->c->terminate(a->comp); a->c->release(a->comp); }
    for (int i = 0; i < a->nprog; i++) if (a->factory[i].presetName) CFRelease(a->factory[i].presetName);
    free(a->factory);
    if (a->present.presetName) CFRelease(a->present.presetName);
    for (int i = 0; i < 4; i++) free(a->scratch[i]);
    pthread_mutex_destroy(&a->lock);
    free(a);
    return noErr;
}

static OSStatus au_initialize(void *s) {
    au_t *a = AU(s);
    if (a->initialized) return noErr;
    uint64_t st = 3;   /* stereo */
    if (a->effect) a->p->setBusArrangements(a->proc, &st, 1, &st, 1);
    else a->p->setBusArrangements(a->proc, NULL, 0, &st, 1);
    ProcessSetup ps = { 0, 0, (int32_t)a->max_frames, a->rate };
    if (a->p->setupProcessing(a->proc, &ps) != kResultOk) return kAudioUnitErr_FailedInitialization;
    for (int i = 0; i < 4; i++) {
        free(a->scratch[i]);
        a->scratch[i] = calloc(a->max_frames, sizeof(float));
        if (!a->scratch[i]) return kAudioUnitErr_FailedInitialization;
    }
    if (a->c->setActive(a->comp, 1) != kResultOk) return kAudioUnitErr_FailedInitialization;
    a->p->setProcessing(a->proc, 1);
    a->initialized = 1;
    return noErr;
}
static OSStatus au_uninitialize(void *s) {
    au_t *a = AU(s);
    if (!a->initialized) return noErr;
    a->p->setProcessing(a->proc, 0);
    a->c->setActive(a->comp, 0);
    a->initialized = 0;
    return noErr;
}
static OSStatus au_reset(void *s, AudioUnitScope sc, AudioUnitElement el) {
    au_t *a = AU(s);
    (void)sc; (void)el;
    if (a->initialized) { a->p->setProcessing(a->proc, 0); a->p->setProcessing(a->proc, 1); }
    return noErr;
}

/* ---- state ---------------------------------------------------------------------------- */
static CFDictionaryRef make_classinfo(au_t *a) {
    mstream_t m = { &ms_vt, NULL, 0, 0, 0 };
    a->c->getState(a->comp, (IBStream *)&m);
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    AudioComponentDescription desc;
    AudioComponentGetDescription(AudioComponentInstanceGetComponent(a->inst), &desc);
    SInt32 v0 = 0, ty = (SInt32)desc.componentType, sub = (SInt32)desc.componentSubType, man = (SInt32)desc.componentManufacturer;
    CFNumberRef n;
    n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v0); CFDictionarySetValue(d, CFSTR(kAUPresetVersionKey), n); CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberSInt32Type, &ty); CFDictionarySetValue(d, CFSTR(kAUPresetTypeKey), n); CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberSInt32Type, &sub); CFDictionarySetValue(d, CFSTR(kAUPresetSubtypeKey), n); CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberSInt32Type, &man); CFDictionarySetValue(d, CFSTR(kAUPresetManufacturerKey), n); CFRelease(n);
    CFDictionarySetValue(d, CFSTR(kAUPresetNameKey), a->present.presetName ? a->present.presetName : CFSTR("Untitled"));
    CFDataRef data = CFDataCreate(NULL, m.buf ? m.buf : (const UInt8 *)"", (CFIndex)m.len);
    CFDictionarySetValue(d, CFSTR("vst3-state"), data);
    CFRelease(data);
    free(m.buf);
    return d;
}
static OSStatus set_classinfo(au_t *a, CFPropertyListRef pl) {
    if (!pl || CFGetTypeID(pl) != CFDictionaryGetTypeID()) return kAudioUnitErr_InvalidPropertyValue;
    CFDataRef data = CFDictionaryGetValue((CFDictionaryRef)pl, CFSTR("vst3-state"));
    if (!data || CFGetTypeID(data) != CFDataGetTypeID()) return kAudioUnitErr_InvalidPropertyValue;
    mstream_t m = { &ms_vt, (uint8_t *)CFDataGetBytePtr(data), CFDataGetLength(data), CFDataGetLength(data), 0 };
    a->c->setState(a->comp, (IBStream *)&m);
    m.pos = 0;
    a->e->setComponentState(a->ctrl, (IBStream *)&m);
    CFStringRef nm = CFDictionaryGetValue((CFDictionaryRef)pl, CFSTR(kAUPresetNameKey));
    a->prog_seen = -1;
    sync_present(a, 0);
    if (nm && CFGetTypeID(nm) == CFStringGetTypeID()) {
        if (a->present.presetName) CFRelease(a->present.presetName);
        a->present.presetName = (CFStringRef)CFRetain(nm);
    }
    AudioUnitParameter any = { a->inst, kAUParameterListener_AnyParameter, kAudioUnitScope_Global, 0 };
    AUParameterListenerNotify(NULL, NULL, &any);
    notify_prop(a, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
    return noErr;
}

/* ---- properties ----------------------------------------------------------------------- */
static void fill_format(au_t *a, AudioStreamBasicDescription *f) {
    memset(f, 0, sizeof *f);
    f->mSampleRate = a->rate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    f->mBytesPerPacket = f->mBytesPerFrame = 4;
    f->mFramesPerPacket = 1;
    f->mChannelsPerFrame = 2;
    f->mBitsPerChannel = 32;
}
static UInt32 element_count(au_t *a, AudioUnitScope sc) {
    if (sc == kAudioUnitScope_Global) return 1;
    if (sc == kAudioUnitScope_Output) return 1;
    if (sc == kAudioUnitScope_Input) return a->effect ? 1 : 0;
    return 0;
}

static OSStatus au_get_info(void *s, AudioUnitPropertyID id, AudioUnitScope sc, AudioUnitElement el, UInt32 *size, Boolean *w) {
    au_t *a = AU(s);
    UInt32 sz = 0;
    Boolean wr = false;
    (void)el;
    switch (id) {
    case kAudioUnitProperty_ClassInfo: sz = sizeof(CFPropertyListRef); wr = true; break;
    case kAudioUnitProperty_SampleRate: sz = sizeof(Float64); wr = true; break;
    case kAudioUnitProperty_ParameterList: sz = sc == kAudioUnitScope_Global ? sizeof(AudioUnitParameterID) * (UInt32)a->nparams : 0; break;
    case kAudioUnitProperty_ParameterInfo: sz = sizeof(AudioUnitParameterInfo); break;
    case kAudioUnitProperty_StreamFormat:
        if (sc != kAudioUnitScope_Output && !(sc == kAudioUnitScope_Input && a->effect)) return kAudioUnitErr_InvalidScope;
        sz = sizeof(AudioStreamBasicDescription); wr = true; break;
    case kAudioUnitProperty_ElementCount: sz = sizeof(UInt32); break;
    case kAudioUnitProperty_Latency: case kAudioUnitProperty_TailTime: sz = sizeof(Float64); break;
    case kAudioUnitProperty_SupportedNumChannels: sz = sizeof(AUChannelInfo); break;
    case kAudioUnitProperty_MaximumFramesPerSlice: sz = sizeof(UInt32); wr = true; break;
    case kAudioUnitProperty_ParameterValueStrings: sz = sizeof(CFArrayRef); break;
    case kAudioUnitProperty_ParameterStringFromValue: sz = sizeof(AudioUnitParameterStringFromValue); break;
    case kAudioUnitProperty_ParameterValueFromString: sz = sizeof(AudioUnitParameterValueFromString); break;
    case kAudioUnitProperty_BypassEffect: if (!a->effect) return kAudioUnitErr_InvalidProperty; sz = sizeof(UInt32); wr = true; break;
    case kAudioUnitProperty_LastRenderError: sz = sizeof(OSStatus); break;
    case kAudioUnitProperty_SetRenderCallback: if (!a->effect) return kAudioUnitErr_InvalidProperty; sz = sizeof(AURenderCallbackStruct); wr = true; break;
    case kAudioUnitProperty_MakeConnection: if (!a->effect) return kAudioUnitErr_InvalidProperty; sz = sizeof(AudioUnitConnection); wr = true; break;
    case kAudioUnitProperty_FactoryPresets: if (a->nprog < 1) return kAudioUnitErr_InvalidProperty; sz = sizeof(CFArrayRef); break;
    case kAudioUnitProperty_PresentPreset: sz = sizeof(AUPreset); wr = true; break;
    case kAudioUnitProperty_HostCallbacks: sz = sizeof(HostCallbackInfo); wr = true; break;
    case kAudioUnitProperty_InPlaceProcessing: sz = sizeof(UInt32); wr = true; break;
    case kAudioUnitProperty_CocoaUI: sz = sizeof(AudioUnitCocoaViewInfo); break;
    case kAudioUnitProperty_ShouldAllocateBuffer: sz = sizeof(UInt32); wr = true; break;
    case kMPCInstanceProperty: sz = sizeof(void *); break;
    default: return kAudioUnitErr_InvalidProperty;
    }
    if (size) *size = sz;
    if (w) *w = wr;
    return noErr;
}

static OSStatus au_get(void *s, AudioUnitPropertyID id, AudioUnitScope sc, AudioUnitElement el, void *out, UInt32 *size) {
    au_t *a = AU(s);
    UInt32 need = 0;
    OSStatus r = au_get_info(s, id, sc, el, &need, NULL);
    if (r) return r;
    if (!out) { if (size) *size = need; return noErr; }
    if (size && *size < need && id != kAudioUnitProperty_ParameterList) return kAudioUnitErr_InvalidPropertyValue;
    switch (id) {
    case kAudioUnitProperty_ClassInfo: *(CFPropertyListRef *)out = make_classinfo(a); break;
    case kAudioUnitProperty_SampleRate: *(Float64 *)out = a->rate; break;
    case kAudioUnitProperty_ParameterList:
        for (int i = 0; i < a->nparams && (UInt32)(i + 1) * sizeof(AudioUnitParameterID) <= *size; i++) ((AudioUnitParameterID *)out)[i] = a->pid[i];
        break;
    case kAudioUnitProperty_ParameterInfo: {
        int i = find_param(a, el);
        if (i < 0 || sc != kAudioUnitScope_Global) return kAudioUnitErr_InvalidParameter;
        ParameterInfo pi;
        int n = a->e->getParameterCount(a->ctrl);
        for (int k = 0; k < n; k++) if (a->e->getParameterInfo(a->ctrl, k, &pi) == kResultOk && pi.id == el) break;
        AudioUnitParameterInfo *ai = out;
        memset(ai, 0, sizeof *ai);
        char nm[52];
        utf16_to_utf8(pi.title, nm, sizeof nm);
        snprintf(ai->name, sizeof ai->name, "%s", nm);
        ai->cfNameString = cfstr16(pi.title);
        ai->flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable | kAudioUnitParameterFlag_HasCFNameString |
                    kAudioUnitParameterFlag_CFNameRelease | kAudioUnitParameterFlag_ValuesHaveStrings;
        if (a->psteps[i] > 0) {
            ai->unit = kAudioUnitParameterUnit_Indexed;
            ai->minValue = 0;
            ai->maxValue = a->psteps[i];
            ai->defaultValue = (AudioUnitParameterValue)lround(pi.defaultNormalizedValue * a->psteps[i]);
            ai->flags &= ~kAudioUnitParameterFlag_ValuesHaveStrings;
        } else {
            ai->unit = kAudioUnitParameterUnit_Generic;
            ai->minValue = 0;
            ai->maxValue = 1;
            ai->defaultValue = (AudioUnitParameterValue)pi.defaultNormalizedValue;
        }
        break;
    }
    case kAudioUnitProperty_StreamFormat: fill_format(a, out); break;
    case kAudioUnitProperty_ElementCount: *(UInt32 *)out = element_count(a, sc); break;
    case kAudioUnitProperty_Latency: *(Float64 *)out = a->rate > 0 ? a->p->getLatencySamples(a->proc) / a->rate : 0; break;
    case kAudioUnitProperty_TailTime: *(Float64 *)out = 2.0; break;
    case kAudioUnitProperty_SupportedNumChannels: {
        AUChannelInfo *ci = out;
        ci->inChannels = a->effect ? 2 : 0;
        ci->outChannels = 2;
        break;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice: *(UInt32 *)out = a->max_frames; break;
    case kAudioUnitProperty_ParameterValueStrings: {
        int i = find_param(a, el);
        if (i < 0 || a->psteps[i] <= 0) return kAudioUnitErr_InvalidProperty;
        CFMutableArrayRef arr = CFArrayCreateMutable(NULL, a->psteps[i] + 1, &kCFTypeArrayCallBacks);
        for (int k = 0; k <= a->psteps[i]; k++) {
            char16 t[128] = { 0 };
            a->e->getParamStringByValue(a->ctrl, a->pid[i], (double)k / a->psteps[i], t);
            CFStringRef str = cfstr16(t);
            CFArrayAppendValue(arr, str);
            CFRelease(str);
        }
        *(CFArrayRef *)out = arr;
        break;
    }
    case kAudioUnitProperty_ParameterStringFromValue: {
        AudioUnitParameterStringFromValue *sv = out;
        int i = find_param(a, sv->inParamID);
        if (i < 0) return kAudioUnitErr_InvalidParameter;
        double v = sv->inValue ? *sv->inValue : a->e->getParamNormalized(a->ctrl, sv->inParamID);
        if (a->psteps[i] > 0) v /= a->psteps[i];
        char16 t[128] = { 0 };
        a->e->getParamStringByValue(a->ctrl, sv->inParamID, v, t);
        sv->outString = cfstr16(t);
        break;
    }
    case kAudioUnitProperty_ParameterValueFromString: {
        AudioUnitParameterValueFromString *vs = out;
        int i = find_param(a, vs->inParamID);
        if (i < 0 || !vs->inString) return kAudioUnitErr_InvalidParameter;
        char16 t[128] = { 0 };
        CFIndex n = CFStringGetLength(vs->inString);
        if (n > 127) n = 127;
        CFStringGetCharacters(vs->inString, CFRangeMake(0, n), (UniChar *)t);
        double v = 0;
        if (a->e->getParamValueByString(a->ctrl, vs->inParamID, t, &v) != kResultOk) return kAudioUnitErr_InvalidPropertyValue;
        vs->outValue = (AudioUnitParameterValue)(a->psteps[i] > 0 ? v * a->psteps[i] : v);
        break;
    }
    case kAudioUnitProperty_BypassEffect: *(UInt32 *)out = (UInt32)a->bypass; break;
    case kAudioUnitProperty_LastRenderError: *(OSStatus *)out = noErr; break;
    case kAudioUnitProperty_SetRenderCallback: *(AURenderCallbackStruct *)out = a->input_cb; break;
    case kAudioUnitProperty_MakeConnection: *(AudioUnitConnection *)out = a->conn; break;
    case kAudioUnitProperty_FactoryPresets: {
        const void **ptrs = malloc(sizeof(void *) * (size_t)a->nprog);
        for (int i = 0; i < a->nprog; i++) ptrs[i] = &a->factory[i];
        *(CFArrayRef *)out = CFArrayCreate(NULL, ptrs, a->nprog, NULL);
        free(ptrs);
        break;
    }
    case kAudioUnitProperty_PresentPreset: {
        sync_present(a, 0);
        AUPreset *pr = out;
        pr->presetNumber = a->present.presetNumber;
        pr->presetName = a->present.presetName ? (CFStringRef)CFRetain(a->present.presetName) : CFSTR("Untitled");
        break;
    }
    case kAudioUnitProperty_HostCallbacks: *(HostCallbackInfo *)out = a->host; break;
    case kAudioUnitProperty_InPlaceProcessing: *(UInt32 *)out = 0; break;
    case kAudioUnitProperty_ShouldAllocateBuffer: *(UInt32 *)out = 1; break;
    case kAudioUnitProperty_CocoaUI: {
        NSBundle *b = [NSBundle bundleForClass:NSClassFromString(@AU_STR(AU_VIEW_FACTORY))];
        AudioUnitCocoaViewInfo *vi = out;
        vi->mCocoaAUViewBundleLocation = (CFURLRef)CFBridgingRetain([b bundleURL]);
        vi->mCocoaAUViewClass[0] = CFSTR(AU_STR(AU_VIEW_FACTORY));
        break;
    }
    case kMPCInstanceProperty: *(void **)out = a; break;
    }
    if (size && id != kAudioUnitProperty_ParameterList) *size = need;
    return noErr;
}

static OSStatus au_set(void *s, AudioUnitPropertyID id, AudioUnitScope sc, AudioUnitElement el, const void *in, UInt32 size) {
    au_t *a = AU(s);
    (void)el;
    switch (id) {
    case kAudioUnitProperty_ClassInfo:
        if (size < sizeof(CFPropertyListRef)) return kAudioUnitErr_InvalidPropertyValue;
        return set_classinfo(a, *(const CFPropertyListRef *)in);
    case kAudioUnitProperty_SampleRate: {
        Float64 r = *(const Float64 *)in;
        if (r <= 0) return kAudioUnitErr_InvalidPropertyValue;
        if (a->initialized && r != a->rate) return kAudioUnitErr_Initialized;
        a->rate = r;
        notify_prop(a, kAudioUnitProperty_SampleRate, sc, 0);
        return noErr;
    }
    case kAudioUnitProperty_StreamFormat: {
        const AudioStreamBasicDescription *f = in;
        if (size < sizeof *f) return kAudioUnitErr_InvalidPropertyValue;
        if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != 2 || f->mBitsPerChannel != 32 ||
            !(f->mFormatFlags & kAudioFormatFlagIsFloat) || !(f->mFormatFlags & kAudioFormatFlagIsNonInterleaved))
            return kAudioUnitErr_FormatNotSupported;
        if (a->initialized && f->mSampleRate != a->rate) return kAudioUnitErr_Initialized;
        a->rate = f->mSampleRate;
        notify_prop(a, kAudioUnitProperty_StreamFormat, sc, 0);
        return noErr;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice: {
        UInt32 m = *(const UInt32 *)in;
        if (m < 1) return kAudioUnitErr_InvalidPropertyValue;
        if (a->initialized && m > a->max_frames) return kAudioUnitErr_Initialized;
        a->max_frames = m;
        notify_prop(a, kAudioUnitProperty_MaximumFramesPerSlice, sc, 0);
        return noErr;
    }
    case kAudioUnitProperty_BypassEffect: a->bypass = *(const UInt32 *)in != 0; return noErr;
    case kAudioUnitProperty_SetRenderCallback:
        a->input_cb = *(const AURenderCallbackStruct *)in;
        a->has_cb = a->input_cb.inputProc != NULL;
        a->has_conn = 0;
        return noErr;
    case kAudioUnitProperty_MakeConnection:
        a->conn = *(const AudioUnitConnection *)in;
        a->has_conn = a->conn.sourceAudioUnit != NULL;
        a->has_cb = 0;
        return noErr;
    case kAudioUnitProperty_PresentPreset: {
        const AUPreset *pr = in;
        if (pr->presetNumber >= 0) {
            if (pr->presetNumber >= a->nprog) return kAudioUnitErr_InvalidPropertyValue;
            uint32_t pid = prog_param(a);
            double v = a->nprog > 1 ? (double)pr->presetNumber / (a->nprog - 1) : 0;
            a->e->setParamNormalized(a->ctrl, pid, v);   /* applied there and then (vst3_wrap.c ctrl_set_norm) */
            queue_change(a, pid, v);
            a->prog_seen = -1;
            sync_present(a, 0);
            AudioUnitParameter any = { a->inst, kAUParameterListener_AnyParameter, kAudioUnitScope_Global, 0 };
            AUParameterListenerNotify(NULL, NULL, &any);
        } else {   /* a user preset: the host keeps its data; only its name is ours to show */
            if (a->present.presetName) CFRelease(a->present.presetName);
            a->present.presetNumber = pr->presetNumber;
            a->present.presetName = pr->presetName ? (CFStringRef)CFRetain(pr->presetName) : CFSTR("Untitled");
        }
        notify_prop(a, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
        return noErr;
    }
    case kAudioUnitProperty_HostCallbacks:
        memset(&a->host, 0, sizeof a->host);
        memcpy(&a->host, in, size < sizeof a->host ? size : sizeof a->host);
        return noErr;
    case kAudioUnitProperty_InPlaceProcessing: case kAudioUnitProperty_ShouldAllocateBuffer: return noErr;
    default: return kAudioUnitErr_InvalidProperty;
    }
}

static OSStatus au_add_listener(void *s, AudioUnitPropertyID id, AudioUnitPropertyListenerProc proc, void *ud) {
    au_t *a = AU(s);
    if (a->nlisteners == 64) return kAudioUnitErr_TooManyFramesToProcess;
    a->listeners[a->nlisteners++] = (listener_t){ id, proc, ud };
    return noErr;
}
static OSStatus au_remove_listener(void *s, AudioUnitPropertyID id, AudioUnitPropertyListenerProc proc) {
    au_t *a = AU(s);
    for (int i = 0; i < a->nlisteners; i++)
        if (a->listeners[i].id == id && a->listeners[i].proc == proc) { a->listeners[i--] = a->listeners[--a->nlisteners]; }
    return noErr;
}
static OSStatus au_remove_listener_ud(void *s, AudioUnitPropertyID id, AudioUnitPropertyListenerProc proc, void *ud) {
    au_t *a = AU(s);
    for (int i = 0; i < a->nlisteners; i++)
        if (a->listeners[i].id == id && a->listeners[i].proc == proc && a->listeners[i].ud == ud) { a->listeners[i--] = a->listeners[--a->nlisteners]; }
    return noErr;
}
static OSStatus au_add_notify(void *s, AURenderCallback proc, void *ud) {
    au_t *a = AU(s);
    if (a->nnotify == 8) return kAudioUnitErr_InvalidPropertyValue;
    a->notify[a->nnotify].proc = proc;
    a->notify[a->nnotify++].ud = ud;
    return noErr;
}
static OSStatus au_remove_notify(void *s, AURenderCallback proc, void *ud) {
    au_t *a = AU(s);
    for (int i = 0; i < a->nnotify; i++)
        if (a->notify[i].proc == proc && a->notify[i].ud == ud) { a->notify[i--] = a->notify[--a->nnotify]; }
    return noErr;
}

/* ---- parameters ----------------------------------------------------------------------- */
static OSStatus au_get_param(void *s, AudioUnitParameterID id, AudioUnitScope sc, AudioUnitElement el, AudioUnitParameterValue *v) {
    au_t *a = AU(s);
    (void)el;
    int i = find_param(a, id);
    if (i < 0 || sc != kAudioUnitScope_Global) return kAudioUnitErr_InvalidParameter;
    double n = a->e->getParamNormalized(a->ctrl, id);
    *v = (AudioUnitParameterValue)(a->psteps[i] > 0 ? lround(n * a->psteps[i]) : n);
    return noErr;
}
static OSStatus au_set_param(void *s, AudioUnitParameterID id, AudioUnitScope sc, AudioUnitElement el, AudioUnitParameterValue v, UInt32 off) {
    au_t *a = AU(s);
    (void)el; (void)off;
    int i = find_param(a, id);
    if (i < 0 || sc != kAudioUnitScope_Global) return kAudioUnitErr_InvalidParameter;
    double n = a->psteps[i] > 0 ? (double)v / a->psteps[i] : (double)v;
    if (n < 0) n = 0;
    if (n > 1) n = 1;
    a->e->setParamNormalized(a->ctrl, id, n);
    queue_change(a, id, n);
    return noErr;
}
static OSStatus au_schedule(void *s, const AudioUnitParameterEvent *ev, UInt32 n) {
    for (UInt32 i = 0; i < n; i++)
        if (ev[i].eventType == kParameterEvent_Immediate)
            au_set_param(s, ev[i].parameter, ev[i].scope, ev[i].element, ev[i].eventValues.immediate.value, ev[i].eventValues.immediate.bufferOffset);
        else
            au_set_param(s, ev[i].parameter, ev[i].scope, ev[i].element, ev[i].eventValues.ramp.endValue, 0);
    return noErr;
}

/* ---- MIDI ----------------------------------------------------------------------------- */
static OSStatus au_midi(void *s, UInt32 st, UInt32 d1, UInt32 d2, UInt32 off) {
    au_t *a = AU(s);
    int h = atomic_load(&a->mhead), nx = (h + 1) % MIDI_RING;
    if (nx == atomic_load(&a->mtail)) return noErr;   /* full: drop */
    a->midi[h].b[0] = (uint8_t)st; a->midi[h].b[1] = (uint8_t)d1; a->midi[h].b[2] = (uint8_t)d2; a->midi[h].off = off;
    atomic_store(&a->mhead, nx);
    return noErr;
}
static OSStatus au_sysex(void *s, const UInt8 *d, UInt32 n) { (void)s; (void)d; (void)n; return noErr; }

static void take_midi(au_t *a, UInt32 frames) {
    a->events.n = 0;
    int t = atomic_load(&a->mtail), h = atomic_load(&a->mhead);
    const MidiMappingVtbl *mm = a->midimap ? VTP(MidiMappingVtbl, a->midimap) : NULL;
    for (; t != h; t = (t + 1) % MIDI_RING) {
        midi_t *m = &a->midi[t];
        int type = m->b[0] & 0xF0, ch = m->b[0] & 0x0F;
        int32_t off = (int32_t)(m->off < frames ? m->off : frames - 1);
        Event e;
        memset(&e, 0, sizeof e);
        e.sampleOffset = off;
        if (type == 0x90 && m->b[2] > 0) {
            e.type = kNoteOnEvent;
            e.noteOn.channel = (int16_t)ch; e.noteOn.pitch = m->b[1]; e.noteOn.velocity = m->b[2] / 127.0f; e.noteOn.noteId = -1;
            ev_add(&a->events, &e);
        } else if (type == 0x80 || type == 0x90) {
            e.type = kNoteOffEvent;
            e.noteOff.channel = (int16_t)ch; e.noteOff.pitch = m->b[1]; e.noteOff.velocity = m->b[2] / 127.0f; e.noteOff.noteId = -1;
            ev_add(&a->events, &e);
        } else if (mm && (type == 0xB0 || type == 0xE0 || type == 0xD0)) {
            int16_t ctl = type == 0xB0 ? m->b[1] : type == 0xE0 ? 129 /* kPitchBend */ : 128 /* kAfterTouch */;
            double v = type == 0xB0 ? m->b[2] / 127.0 : type == 0xE0 ? ((m->b[2] << 7) | m->b[1]) / 16383.0 : m->b[1] / 127.0;
            uint32_t pid;
            if (mm->getMidiControllerAssignment(a->midimap, 0, (int16_t)ch, ctl, &pid) == kResultOk) {
                int32_t qi;
                IParamValueQueue *q = pc_add(&a->inpc, &pid, &qi);
                if (q) pq_add(q, off, v, &qi);
            }
        }
    }
    atomic_store(&a->mtail, t);
}

/* ---- render --------------------------------------------------------------------------- */
static OSStatus au_render(void *s, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    au_t *a = AU(s);
    if (!a->initialized) return kAudioUnitErr_Uninitialized;
    if (frames > a->max_frames) return kAudioUnitErr_TooManyFramesToProcess;
    if (bus != 0 || !io) return kAudioUnitErr_InvalidElement;
    for (int i = 0; i < a->nnotify; i++) {
        AudioUnitRenderActionFlags f = kAudioUnitRenderAction_PreRender;
        a->notify[i].proc(a->notify[i].ud, &f, ts, bus, frames, io);
    }
    float *out[2];
    for (int c = 0; c < 2; c++) {
        if ((UInt32)c < io->mNumberBuffers && io->mBuffers[c].mData) out[c] = io->mBuffers[c].mData;
        else { out[c] = a->scratch[c]; if ((UInt32)c < io->mNumberBuffers) { io->mBuffers[c].mData = out[c]; io->mBuffers[c].mDataByteSize = frames * 4; } }
    }
    float *in[2] = { a->scratch[2], a->scratch[3] };
    if (a->effect) {
        struct { UInt32 n; AudioBuffer b[2]; } inl = { 2, { { 1, frames * 4, in[0] }, { 1, frames * 4, in[1] } } };
        AudioUnitRenderActionFlags f = 0;
        OSStatus r = noErr;
        if (a->has_cb) r = a->input_cb.inputProc(a->input_cb.inputProcRefCon, &f, ts, 0, frames, (AudioBufferList *)&inl);
        else if (a->has_conn) r = AudioUnitRender(a->conn.sourceAudioUnit, &f, ts, a->conn.sourceOutputNumber, frames, (AudioBufferList *)&inl);
        else { memset(in[0], 0, frames * 4); memset(in[1], 0, frames * 4); }
        if (r) return r;
        for (int c = 0; c < 2; c++) if (inl.b[c].mData && inl.b[c].mData != in[c]) memcpy(in[c], inl.b[c].mData, frames * 4);
        if (a->bypass) {
            for (int c = 0; c < 2; c++) memcpy(out[c], in[c], frames * 4);
            return noErr;
        }
    }
    /* pending parameter changes (host, the plugin's window) and MIDI, then one process() call */
    a->inpc.n = 0;
    a->outpc.n = 0;
    if (pthread_mutex_trylock(&a->lock) == 0) {
        for (int i = 0; i < a->npend; i++) {
            int32_t qi;
            IParamValueQueue *q = pc_add(&a->inpc, &a->pend[i].id, &qi);
            if (q) pq_add(q, 0, a->pend[i].v, &qi);
        }
        a->npend = 0;
        pthread_mutex_unlock(&a->lock);
    }
    take_midi(a, frames);
    ProcessContext ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.sampleRate = a->rate;
    if (a->host.beatAndTempoProc) {
        Float64 beat = 0, tempo = 0;
        if (a->host.beatAndTempoProc(a->host.hostUserData, &beat, &tempo) == noErr && tempo > 0) {
            ctx.tempo = tempo; ctx.projectTimeMusic = beat;
            ctx.state |= kTempoValid | kProjectTimeMusicValid;
        }
    }
    if (a->host.transportStateProc) {
        Boolean playing = false, changed = false, looping = false;
        Float64 sample = 0, cs = 0, ce = 0;
        if (a->host.transportStateProc(a->host.hostUserData, &playing, &changed, &sample, &looping, &cs, &ce) == noErr) {
            if (playing) ctx.state |= kPlaying;
            ctx.projectTimeSamples = (int64_t)sample;
        }
    }
    AudioBusBuffers ib = { 2, 0, in }, ob = { 2, 0, out };
    ProcessData d = { 0, 0, (int32_t)frames, a->effect ? 1 : 0, 1, a->effect ? &ib : NULL, &ob,
                      (IParameterChanges *)&a->inpc, (IParameterChanges *)&a->outpc, (IEventList *)&a->events, NULL, &ctx };
    a->p->process(a->proc, &d);
    for (int i = 0; i < a->nnotify; i++) {
        AudioUnitRenderActionFlags f = kAudioUnitRenderAction_PostRender;
        a->notify[i].proc(a->notify[i].ud, &f, ts, bus, frames, io);
    }
    (void)flags;
    return noErr;
}

/* ---- the selector table ----------------------------------------------------------------- */
static AudioComponentMethod au_lookup(SInt16 sel) {
    switch (sel) {
    case kAudioUnitInitializeSelect: return (AudioComponentMethod)au_initialize;
    case kAudioUnitUninitializeSelect: return (AudioComponentMethod)au_uninitialize;
    case kAudioUnitGetPropertyInfoSelect: return (AudioComponentMethod)au_get_info;
    case kAudioUnitGetPropertySelect: return (AudioComponentMethod)au_get;
    case kAudioUnitSetPropertySelect: return (AudioComponentMethod)au_set;
    case kAudioUnitAddPropertyListenerSelect: return (AudioComponentMethod)au_add_listener;
    case kAudioUnitRemovePropertyListenerSelect: return (AudioComponentMethod)au_remove_listener;
    case kAudioUnitRemovePropertyListenerWithUserDataSelect: return (AudioComponentMethod)au_remove_listener_ud;
    case kAudioUnitAddRenderNotifySelect: return (AudioComponentMethod)au_add_notify;
    case kAudioUnitRemoveRenderNotifySelect: return (AudioComponentMethod)au_remove_notify;
    case kAudioUnitGetParameterSelect: return (AudioComponentMethod)au_get_param;
    case kAudioUnitSetParameterSelect: return (AudioComponentMethod)au_set_param;
    case kAudioUnitScheduleParametersSelect: return (AudioComponentMethod)au_schedule;
    case kAudioUnitRenderSelect: return (AudioComponentMethod)au_render;
    case kAudioUnitResetSelect: return (AudioComponentMethod)au_reset;
#ifndef PLUG_EFFECT
    case kMusicDeviceMIDIEventSelect: return (AudioComponentMethod)au_midi;
    case kMusicDeviceSysExSelect: return (AudioComponentMethod)au_sysex;
#else
    case kMusicDeviceMIDIEventSelect: return (AudioComponentMethod)au_midi;   /* an effect can take MIDI too (aumf hosts) */
#endif
    default: return NULL;
    }
}

/* The factory named in Info.plist (AudioComponents factoryFunction). */
__attribute__((visibility("default"))) void *AU_CAT(MPCAUFactory_, MPC_AU_TAG)(const AudioComponentDescription *desc) {
    (void)desc;
    au_t *a = calloc(1, sizeof *a);
    if (!a) return NULL;
    a->iface.Open = au_open;
    a->iface.Close = au_close;
    a->iface.Lookup = au_lookup;
    return a;
}

/* ---- the plugin window: the VST3 editor in the view the host shows ------------------------- */
typedef struct { const PlugFrameVtbl *v; void *owner; } frame_t;

@interface AU_VIEW : NSView {
@public
    void *plugview;
    frame_t frame;
}
- (void)teardown;
@end

static tresult fr_q(void *s, const TUID iid, void **o) {
    if (iid_eq(iid, iid_FUnknown) || iid_eq(iid, iid_IPlugFrame)) { *o = s; return kResultOk; }
    *o = NULL;
    return kNoInterface;
}
static uint32_t fr_ref(void *s) { (void)s; return 1; }
static tresult fr_resize(void *s, void *view, ViewRect *r) {   /* the window-size menu: the host's window follows our frame */
    AU_VIEW *v = (__bridge AU_VIEW *)((frame_t *)s)->owner;
    (void)view;
    [v setFrameSize:NSMakeSize(r->right - r->left, r->bottom - r->top)];
    if (v->plugview) VTP(PlugViewVtbl, v->plugview)->onSize(v->plugview, r);
    return kResultOk;
}
static const PlugFrameVtbl fr_vt = { fr_q, fr_ref, fr_ref, fr_resize };

@implementation AU_VIEW
- (BOOL)isFlipped { return YES; }
- (void)teardown {
    if (plugview) {
        const PlugViewVtbl *pv = VTP(PlugViewVtbl, plugview);
        pv->setFrame(plugview, NULL);
        pv->removed(plugview);
        pv->release(plugview);
        plugview = NULL;
    }
}
- (void)viewWillMoveToWindow:(NSWindow *)w { if (!w) [self teardown]; [super viewWillMoveToWindow:w]; }
- (void)dealloc { [self teardown]; [super dealloc]; }
@end

@interface AU_VIEW_FACTORY : NSObject <AUCocoaUIBase>
@end
@implementation AU_VIEW_FACTORY
- (unsigned)interfaceVersion { return 0; }
- (NSString *)description { return @AU_STR(MPC_AU_TAG); }
- (NSView *)uiViewForAudioUnit:(AudioUnit)unit withSize:(NSSize)size {
    (void)size;
    au_t *a = NULL;
    UInt32 sz = sizeof a;
    if (AudioUnitGetProperty(unit, kMPCInstanceProperty, kAudioUnitScope_Global, 0, &a, &sz) != noErr || !a) return nil;
    void *pv = a->e->createView(a->ctrl, "editor");
    if (!pv) return nil;
    const PlugViewVtbl *v = VTP(PlugViewVtbl, pv);
    ViewRect r = { 0, 0, 800, 450 };
    v->getSize(pv, &r);
    AU_VIEW *view = [[AU_VIEW alloc] initWithFrame:NSMakeRect(0, 0, r.right - r.left, r.bottom - r.top)];
    view->plugview = pv;
    view->frame.v = &fr_vt;
    view->frame.owner = (__bridge void *)view;
    v->setFrame(pv, &view->frame);
    if (v->attached(pv, (__bridge void *)view, "NSView") != kResultOk) { [view teardown]; [view release]; return nil; }
    return [view autorelease];
}
@end
