/* Force-included in every source of a Windows desktop VST3 build (tools/build_vst3.sh, VST3_TARGET=windows): the few POSIX
 * calls MPC engines use that mingw-w64 spells differently, so a port builds for Windows unchanged. */
#ifndef MPC_WIN_COMPAT_H
#define MPC_WIN_COMPAT_H
#ifdef _WIN32
#include <io.h>
#include <direct.h>
#include <sys/stat.h>
#define mkdir(path, mode) _mkdir(path)   /* no permission bits on Windows */
#endif
#endif
