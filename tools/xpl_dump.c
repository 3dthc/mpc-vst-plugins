/* tools/xpl_presets.sh links this with the wrapper and a port's engine on the build machine: it selects each program
 * the way MPC's PRESET menu does (effSetProgram) and prints the plugin's own chunk for it (effGetChunk), so every .xpl
 * holds exactly what a project saved on that program would. Output, per program: "<name>\t<chunk as hex>\n". */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "params.h"
typedef struct AEffect AEffect;
typedef intptr_t (*cb)(AEffect*,int32_t,int32_t,intptr_t,void*,float);
struct AEffect { int32_t magic; intptr_t (*d)(AEffect*,int32_t,int32_t,intptr_t,void*,float);
 void*p; void (*setP)(AEffect*,int32_t,float); float (*getP)(AEffect*,int32_t);
 int32_t np,npar,ni,no,flags; intptr_t r1,r2; int32_t a,b,c; float io; void*obj,*user; int32_t uid,ver;
 void (*pr)(AEffect*,float**,float**,int32_t); void*pdr; char f[56]; };
extern AEffect* VSTPluginMain(cb);
static double ti[16];
static intptr_t host(AEffect*e,int32_t op,int32_t i,intptr_t v,void*p,float o){
    if (op == 1) return 2400;   /* audioMasterVersion */
    if (op == 7) { ti[4] = 120.0; ((int32_t*)&ti[8])[5] = 1 << 10; return (intptr_t)ti; }
    return 0;
}
static void run(AEffect *a, int blocks) {
    float L[128], R[128], I0[128] = {0}, I1[128] = {0}, *o[2] = {L, R}, *in[2] = {I0, I1};
    for (int k = 0; k < blocks; k++) a->pr(a, a->ni >= 2 ? in : 0, o, 128);
}
static AEffect *open_plugin(void) {
    AEffect *a = VSTPluginMain(host);
    if (!a) return 0;
    a->d(a, 0, 0, 0, 0, 0); a->d(a, 10, 0, 0, 0, 44100.f); a->d(a, 11, 0, 128, 0, 0); a->d(a, 12, 0, 1, 0, 0);
    run(a, 4);
    return a;
}

/* --verify: each line of programs.tsv on stdin, restored into a fresh instance (effSetChunk, as MPC loads an .xpl),
 * must save back the same chunk and leave that program selected */
static int verify(void) {
    static char line[1 << 20];
    int i = -1, bad = 0, checked = 0;
    while (fgets(line, sizeof line, stdin)) {
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        i = atoi(line);   /* "<index> <name>\t<chunk>": xpl_presets.sh numbers the lines it keeps */
        char *sp = strchr(line, ' ');
        memmove(line, sp ? sp + 1 : line, strlen(sp ? sp + 1 : line) + 1);
        tab = strchr(line, '\t');
        char *hex = tab + 1;
        size_t n = strcspn(hex, "\n") / 2;
        unsigned char *c = malloc(n + 1);
        for (size_t k = 0; k < n; k++) { unsigned v; sscanf(hex + 2 * k, "%2x", &v); c[k] = v; }
        AEffect *a = open_plugin();
        a->d(a, 24, 0, (intptr_t)n, c, 0);   /* effSetChunk */
        run(a, 2);
        void *back = 0;
        intptr_t m = a->d(a, 23, 0, 0, &back, 0);
        int prog = (int)a->d(a, 3, 0, 0, 0, 0);   /* effGetProgram */
#ifdef PROG_PARAM   /* the program is a parameter, so the state carries it; a wrapper-side program list (NPRESETS) doesn't */
        int prog_ok = prog == i;
#else
        int prog_ok = 1;
#endif
        if (m != (intptr_t)n || memcmp(back, c, n) || !prog_ok) {
            *tab = 0;
            fprintf(stderr, "xpl_dump: program %d (%s) restores %s, as program %d\n", i, line,
                    m == (intptr_t)n && !memcmp(back, c, n) ? "the same state" : "a different state", prog);
            bad++;
        }
        a->d(a, 12, 0, 0, 0, 0); a->d(a, 1, 0, 0, 0, 0);
        free(c);
        checked++;
    }
    printf("xpl_dump: %d programs restored, %d differ\n", checked, bad);
    return bad != 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--verify")) return verify();
    AEffect *a = VSTPluginMain(host);
    if (!a) { fprintf(stderr, "xpl_dump: the plugin did not load\n"); return 1; }
    a->d(a, 0, 0, 0, 0, 0);          /* effOpen */
    a->d(a, 10, 0, 0, 0, 44100.f);   /* effSetSampleRate */
    a->d(a, 11, 0, 128, 0, 0);       /* effSetBlockSize */
    a->d(a, 12, 0, 1, 0, 0);         /* effMainsChanged on */
    run(a, 4);
    for (int i = 0; i < a->np; i++) {
        char name[256] = {0};   /* PROG_NAME_LEN 64 here: the whole name */
        a->d(a, 29, i, 0, name, 0);   /* effGetProgramNameIndexed */
        a->d(a, 2, 0, i, 0, 0);       /* effSetProgram */
        run(a, 2);
        void *chunk = 0;
        intptr_t n = a->d(a, 23, 0, 0, &chunk, 0);   /* effGetChunk (bank) */
        for (char *c = name; *c; c++) if (*c == '\t' || *c == '\n') *c = ' ';
        printf("%s\t", name);
        for (intptr_t k = 0; k < n && chunk; k++) printf("%02x", ((unsigned char *)chunk)[k]);
        printf("\n");
    }
    a->d(a, 12, 0, 0, 0, 0);
    a->d(a, 1, 0, 0, 0, 0);          /* effClose */
    return 0;
}
