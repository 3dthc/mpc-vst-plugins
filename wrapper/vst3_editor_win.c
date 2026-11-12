/* vst3_editor_win.c — the Windows window layer of the desktop VST3 editor (wrapper/vst3_editor.c draws the page with
 * cairo into an image; this shows it in a child window of the host's HWND and passes the mouse back).
 *
 * Built by tools/build_vst3.sh (VST3_TARGET=windows) when the editor is on. A Windows host calls IPlugView on its UI
 * thread, which also runs this window's messages, so the 33 ms tick is a WM_TIMER. The window class is registered under
 * MPC_VIEW_CLASS (unique per plugin and version: classes are per process) while at least one view is open, and
 * unregistered with the last one, so unloading the DLL never leaves a class pointing at freed code. Sizes are window
 * pixels: the host sizes the view for its DPI, and the page is drawn at that size. */
#include <windows.h>
#include <windowsx.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef MPC_VIEW_CLASS
#error MPC_VIEW_CLASS must be defined (tools/build_vst3.sh does)
#endif
#define MPC_STR2(x) #x
#define MPC_STR(x) MPC_STR2(x)

/* vst3_editor.c */
void mpc_ed_tick(void *ctx);
void mpc_ed_mouse(void *ctx, int kind, double x, double y);   /* 0 down, 1 drag, 2 up, 3 wheel up, 4 wheel down, 5 menu */

typedef struct {
    HWND hwnd;
    void *ctx;
    unsigned char *px;     /* the last frame, BGRX top-down (cairo RGB24 on little-endian) */
    int pw, ph, stride;
    int down;
    int wheel_acc;
} win_view_t;

static int g_class_refs;
static HINSTANCE g_inst;

static HINSTANCE this_module(void) {
    if (!g_inst)
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)&this_module, (HMODULE *)&g_inst);
    return g_inst;
}

static LRESULT CALLBACK wnd_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    win_view_t *m = (win_view_t *)GetWindowLongPtrA(h, GWLP_USERDATA);
    switch (msg) {
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        RECT r;
        GetClientRect(h, &r);
        if (m && m->px) {
            BITMAPINFO bi;
            memset(&bi, 0, sizeof bi);
            bi.bmiHeader.biSize = sizeof bi.bmiHeader;
            bi.bmiHeader.biWidth = m->stride / 4;
            bi.bmiHeader.biHeight = -m->ph;   /* top-down */
            bi.bmiHeader.biPlanes = 1;
            bi.bmiHeader.biBitCount = 32;
            bi.bmiHeader.biCompression = BI_RGB;
            if (r.right - r.left == m->pw && r.bottom - r.top == m->ph)
                SetDIBitsToDevice(dc, 0, 0, m->pw, m->ph, 0, 0, 0, m->ph, m->px, &bi, DIB_RGB_COLORS);
            else {
                SetStretchBltMode(dc, HALFTONE);
                StretchDIBits(dc, 0, 0, r.right - r.left, r.bottom - r.top, 0, 0, m->pw, m->ph, m->px, &bi,
                              DIB_RGB_COLORS, SRCCOPY);
            }
        } else
            FillRect(dc, &r, (HBRUSH)GetStockObject(BLACK_BRUSH));
        EndPaint(h, &ps);
        return 0;
    }
    case WM_TIMER:
        if (m && m->ctx) mpc_ed_tick(m->ctx);
        return 0;
    case WM_LBUTTONDOWN:
        if (m && m->ctx) {
            SetCapture(h);
            m->down = 1;
            mpc_ed_mouse(m->ctx, 0, GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
        }
        return 0;
    case WM_MOUSEMOVE:
        if (m && m->ctx && m->down) mpc_ed_mouse(m->ctx, 1, GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
        return 0;
    case WM_LBUTTONUP:
    case WM_CAPTURECHANGED:
        if (m && m->ctx && m->down) {
            m->down = 0;
            if (msg == WM_LBUTTONUP) ReleaseCapture();
            mpc_ed_mouse(m->ctx, 2, GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
        }
        return 0;
    case WM_RBUTTONUP:
        if (m && m->ctx) mpc_ed_mouse(m->ctx, 5, GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
        return 0;
    case WM_MOUSEWHEEL:
        if (m && m->ctx) {
            POINT p = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };   /* screen coordinates */
            ScreenToClient(h, &p);
            m->wheel_acc += GET_WHEEL_DELTA_WPARAM(wp);
            while (m->wheel_acc >= WHEEL_DELTA) { mpc_ed_mouse(m->ctx, 3, p.x, p.y); m->wheel_acc -= WHEEL_DELTA; }
            while (m->wheel_acc <= -WHEEL_DELTA) { mpc_ed_mouse(m->ctx, 4, p.x, p.y); m->wheel_acc += WHEEL_DELTA; }
        }
        return 0;
    case WM_MOUSEACTIVATE:
        return MA_ACTIVATE;
    }
    return DefWindowProcA(h, msg, wp, lp);
}

void *mpc_plat_open(void *parent, int w, int h, void *ctx) {
    if (!parent) return NULL;
    HINSTANCE inst = this_module();
    if (g_class_refs == 0) {
        WNDCLASSA wc;
        memset(&wc, 0, sizeof wc);
        wc.style = CS_DBLCLKS;
        wc.lpfnWndProc = wnd_proc;
        wc.hInstance = inst;
        wc.hCursor = LoadCursor(NULL, IDC_ARROW);
        wc.lpszClassName = MPC_STR(MPC_VIEW_CLASS);
        if (!RegisterClassA(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
    }
    win_view_t *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->ctx = ctx;
    m->hwnd = CreateWindowExA(0, MPC_STR(MPC_VIEW_CLASS), "", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, 0, 0, w, h,
                              (HWND)parent, NULL, inst, NULL);
    if (!m->hwnd) {
        free(m);
        if (g_class_refs == 0) UnregisterClassA(MPC_STR(MPC_VIEW_CLASS), inst);
        return NULL;
    }
    g_class_refs++;
    SetWindowLongPtrA(m->hwnd, GWLP_USERDATA, (LONG_PTR)m);
    SetTimer(m->hwnd, 1, 33, NULL);
    return m;
}

void mpc_plat_close(void *p) {
    win_view_t *m = p;
    if (!m) return;
    KillTimer(m->hwnd, 1);
    m->ctx = NULL;
    SetWindowLongPtrA(m->hwnd, GWLP_USERDATA, 0);
    DestroyWindow(m->hwnd);
    free(m->px);
    free(m);
    if (--g_class_refs == 0) UnregisterClassA(MPC_STR(MPC_VIEW_CLASS), this_module());
}

void mpc_plat_size(void *p, int w, int h) {
    win_view_t *m = p;
    if (m) SetWindowPos(m->hwnd, NULL, 0, 0, w, h, SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOMOVE);
}

double mpc_plat_backing_scale(void *p) { (void)p; return 1; }   /* the view's size is already in pixels */

void mpc_plat_present(void *p, const unsigned char *data, int stride, int w, int h) {
    win_view_t *m = p;
    if (!m || !data || w <= 0 || h <= 0) return;
    size_t n = (size_t)stride * h;
    if (!m->px || m->stride * m->ph != (int)n) {
        unsigned char *nb = realloc(m->px, n);
        if (!nb) return;
        m->px = nb;
    }
    memcpy(m->px, data, n);
    m->pw = w; m->ph = h; m->stride = stride;
    InvalidateRect(m->hwnd, NULL, FALSE);
}

/* A small menu at the pointer (right-click); returns the picked item, or -1. */
int mpc_plat_menu(void *p, const char *const *items, int n, int checked, double x, double y) {
    win_view_t *m = p;
    if (!m) return -1;
    HMENU menu = CreatePopupMenu();
    if (!menu) return -1;
    for (int i = 0; i < n; i++) AppendMenuA(menu, MF_STRING | (i == checked ? MF_CHECKED : 0), (UINT_PTR)(i + 1), items[i]);
    POINT pt = { (LONG)x, (LONG)y };
    ClientToScreen(m->hwnd, &pt);
    int cmd = (int)TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0, m->hwnd, NULL);
    DestroyMenu(menu);
    return cmd > 0 ? cmd - 1 : -1;
}
