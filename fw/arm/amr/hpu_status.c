#include "hpu_amr.h"
#include "xil_cache.h"
void hpu_amr_status(uint32_t state)
{
    volatile HpuAmrStatus *s = (volatile HpuAmrStatus *)HPU_AMR_STATUS_ADDR;
    s->magic = HPU_AMR_MAGIC;
    s->abi = HPU_AMR_ABI;
    s->ucore_major = 3;
    s->ucore_minor = 0;
    s->state = state;
    Xil_DCacheFlushRange(HPU_AMR_STATUS_ADDR, sizeof(*s));
}
