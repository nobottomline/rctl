#pragma once

// Only package/bootstrap files belong below the jailbreak root. User data,
// sockets, and Apple frameworks retain their original filesystem paths.
#if defined(RCTL_ROOTLESS) && RCTL_ROOTLESS
#include <rootless.h>
// Resolve each literal once; libroot's C macro uses a static output buffer.
#define RCTL_ROOT_PATH(path) ([] { static const char *resolved = ROOT_PATH(path); return resolved; }())
#define RCTL_ROOT_PATH_NS(path) ROOT_PATH_NS(path)
#define RCTL_WEB_CLIENT RCTL_ROOT_PATH("/usr/local/share/rctl/web/index.html")
#else
#define RCTL_ROOT_PATH(path) (path)
#define RCTL_ROOT_PATH_NS(path) (path)
#define RCTL_WEB_CLIENT "/var/mobile/rctl/index.html"
#endif
