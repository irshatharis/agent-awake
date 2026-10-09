#include <stdint.h>
#include <sys/types.h>
typedef struct { int32_t pid; int32_t ppid; uint64_t started; uint32_t uid; char name[1024]; } AAProcess;
int aa_process(int32_t pid, AAProcess *out);
int aa_list_processes(int32_t *buffer, int capacity);
