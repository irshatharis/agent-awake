#include "ProcessSupport.h"
#include <libproc.h>
#include <string.h>
int aa_process(int32_t pid, AAProcess *out) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    if (info.pbi_status == 5) return 0; // zombie
    out->pid = pid; out->ppid = info.pbi_ppid; out->uid = info.pbi_uid;
    out->started = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
    memset(out->name, 0, sizeof(out->name));
    proc_pidpath(pid, out->name, sizeof(out->name));
    if (!out->name[0]) strlcpy(out->name, info.pbi_name, sizeof(out->name));
    return 1;
}
int aa_list_processes(int32_t *buffer, int capacity) {
    return proc_listallpids(buffer, capacity * sizeof(int32_t));
}
