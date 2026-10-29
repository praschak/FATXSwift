#include "CFATXPlatform.h"
#include <signal.h>
#ifdef __APPLE__
#include <libproc.h>
#endif
uint64_t fx_process_stamp(int pid) {
#ifdef __APPLE__
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return (uint64_t)info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec;
#else
    /* Linux test host; production macOS also checks process start identity. */
    return kill(pid, 0) == 0 ? 1 : 0;
#endif
}
