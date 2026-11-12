/* vst3_editor_mac.m — the macOS window layer of the desktop VST3 editor (wrapper/vst3_editor.c draws the page with cairo
 * into an image; this shows it in an NSView inside the host's window and passes the mouse back).
 *
 * Built by tools/build_vst3.sh (VST3_TARGET=macos) next to vst3_wrap.c. Everything here runs on the main thread, which
 * is where a macOS host calls IPlugView, so there is no run loop to register with: an NSTimer on the main run loop
 * drives the 33 ms tick. MPC_VIEW_CLASS is unique per plugin (the build derives it from the name, uid and version): every
 * plugin in a process shares one Objective-C class namespace, and two classes with the same name would mix up their code. */
#import <Cocoa/Cocoa.h>
#include <stdint.h>

#ifndef MPC_VIEW_CLASS
#error MPC_VIEW_CLASS must be defined (tools/build_vst3.sh does)
#endif
#define MPC_CAT2(a, b) a##b
#define MPC_CAT(a, b) MPC_CAT2(a, b)
#define MPC_TIMER_CLASS MPC_CAT(MPC_VIEW_CLASS, _Timer)

/* vst3_editor.c */
void mpc_ed_tick(void *ctx);
void mpc_ed_mouse(void *ctx, int kind, double x, double y);   /* 0 down, 1 drag, 2 up, 3 wheel up, 4 wheel down, 5 menu */

@interface MPC_VIEW_CLASS : NSView {
@public
    void *ctx;
    CGImageRef image;
    double wheel_acc;
    BOOL ctl_click;
}
@end

@implementation MPC_VIEW_CLASS
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { (void)e; return YES; }
- (void)drawRect:(NSRect)r {
    (void)r;
    CGContextRef cg = [[NSGraphicsContext currentContext] CGContext];
    NSRect b = [self bounds];
    if (!image) { CGContextSetRGBFillColor(cg, 0, 0, 0, 1); CGContextFillRect(cg, NSRectToCGRect(b)); return; }
    /* the view is flipped and CGContextDrawImage draws bottom-up: flip back for the image */
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, 0, b.size.height);
    CGContextScaleCTM(cg, 1, -1);
    CGContextSetInterpolationQuality(cg, kCGInterpolationHigh);
    CGContextDrawImage(cg, CGRectMake(0, 0, b.size.width, b.size.height), image);
    CGContextRestoreGState(cg);
}
- (NSPoint)at:(NSEvent *)e { return [self convertPoint:[e locationInWindow] fromView:nil]; }
- (void)mouseDown:(NSEvent *)e {
    if (!ctx) return;
    NSPoint p = [self at:e];
    if ([e modifierFlags] & NSEventModifierFlagControl) { ctl_click = YES; mpc_ed_mouse(ctx, 5, p.x, p.y); return; }
    ctl_click = NO;
    mpc_ed_mouse(ctx, 0, p.x, p.y);
}
- (void)rightMouseDown:(NSEvent *)e { if (ctx) { NSPoint p = [self at:e]; mpc_ed_mouse(ctx, 5, p.x, p.y); } }
- (void)mouseDragged:(NSEvent *)e { if (ctx && !ctl_click) { NSPoint p = [self at:e]; mpc_ed_mouse(ctx, 1, p.x, p.y); } }
- (void)mouseUp:(NSEvent *)e { if (ctx && !ctl_click) { NSPoint p = [self at:e]; mpc_ed_mouse(ctx, 2, p.x, p.y); } }
- (void)scrollWheel:(NSEvent *)e {
    if (!ctx) return;
    /* trackpads send many small deltas: one nudge per whole line's worth */
    wheel_acc += [e hasPreciseScrollingDeltas] ? [e scrollingDeltaY] / 10.0 : [e scrollingDeltaY];
    NSPoint p = [self at:e];
    while (wheel_acc >= 1) { mpc_ed_mouse(ctx, 3, p.x, p.y); wheel_acc -= 1; }
    while (wheel_acc <= -1) { mpc_ed_mouse(ctx, 4, p.x, p.y); wheel_acc += 1; }
}
- (void)dealloc {
    if (image) CGImageRelease(image);
    [super dealloc];
}
@end

@interface MPC_TIMER_CLASS : NSObject {
@public
    void *ctx;
    int picked;
}
- (void)fire:(NSTimer *)t;
- (void)pick:(NSMenuItem *)item;
@end
@implementation MPC_TIMER_CLASS
- (void)fire:(NSTimer *)t { (void)t; if (ctx) mpc_ed_tick(ctx); }
- (void)pick:(NSMenuItem *)item { picked = (int)[item tag]; }
@end

typedef struct {
    MPC_VIEW_CLASS *view;
    MPC_TIMER_CLASS *target;
    NSTimer *timer;
} mac_view_t;

void *mpc_plat_open(void *parent, int w, int h, void *ctx) {
    @autoreleasepool {
        NSView *p = (NSView *)parent;
        if (!p) return NULL;
        mac_view_t *m = calloc(1, sizeof *m);
        if (!m) return NULL;
        m->view = [[MPC_VIEW_CLASS alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
        m->view->ctx = ctx;
        [p addSubview:m->view];
        m->target = [[MPC_TIMER_CLASS alloc] init];
        m->target->ctx = ctx;
        m->timer = [[NSTimer timerWithTimeInterval:0.033 target:m->target selector:@selector(fire:) userInfo:nil repeats:YES] retain];
        [[NSRunLoop mainRunLoop] addTimer:m->timer forMode:NSRunLoopCommonModes];
        return m;
    }
}

void mpc_plat_close(void *h) {
    mac_view_t *m = h;
    if (!m) return;
    @autoreleasepool {
        [m->timer invalidate];
        [m->timer release];
        m->target->ctx = NULL;
        [m->target release];
        m->view->ctx = NULL;
        [m->view removeFromSuperview];
        [m->view release];
    }
    free(m);
}

void mpc_plat_size(void *h, int w, int hh) {
    mac_view_t *m = h;
    if (m) [m->view setFrame:NSMakeRect(0, 0, w, hh)];
}

/* Pixels per point of the screen the view is on (2 on a Retina display), so the page is drawn sharp. */
double mpc_plat_backing_scale(void *h) {
    mac_view_t *m = h;
    if (!m) return 1;
    NSWindow *win = [m->view window];
    double s = win ? [win backingScaleFactor] : [[NSScreen mainScreen] backingScaleFactor];
    return s >= 1 ? s : 1;
}

/* A new frame: data is cairo's ARGB32 (premultiplied, native-endian 32-bit words). The image keeps its own copy. */
void mpc_plat_present(void *h, const unsigned char *data, int stride, int w, int hh) {
    mac_view_t *m = h;
    if (!m || !data || w <= 0 || hh <= 0) return;
    CFDataRef bytes = CFDataCreate(NULL, data, (CFIndex)stride * hh);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData(bytes);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef im = CGImageCreate(w, hh, 8, 32, stride, cs,
                                  kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, dp, NULL, false,
                                  kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(dp);
    CFRelease(bytes);
    if (!im) return;
    if (m->view->image) CGImageRelease(m->view->image);
    m->view->image = im;
    [m->view setNeedsDisplay:YES];
}

/* A small menu at the pointer (right-click or Control-click); returns the picked item, or -1. */
int mpc_plat_menu(void *h, const char *const *items, int n, int checked, double x, double y) {
    mac_view_t *m = h;
    if (!m) return -1;
    @autoreleasepool {
        NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
        [menu setAutoenablesItems:NO];
        m->target->picked = -1;
        for (int i = 0; i < n; i++) {
            NSMenuItem *it = [[[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:items[i]]
                                                         action:@selector(pick:) keyEquivalent:@""] autorelease];
            [it setTarget:m->target];
            [it setTag:i];
            [it setEnabled:YES];
            if (i == checked) [it setState:NSControlStateValueOn];
            [menu addItem:it];
        }
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(x, y) inView:m->view];
        return m->target->picked;
    }
}
