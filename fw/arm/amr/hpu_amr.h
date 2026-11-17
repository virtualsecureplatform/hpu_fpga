/* HPU application ABI; management protocol remains AMD AMR 3.0. */
#ifndef HPU_AMR_H
#define HPU_AMR_H
#include <stdint.h>
#define HPU_SHARED_BASE 0x38000000U
#define HPU_AMR_STATUS_ADDR 0x107ff000U
#define HPU_AMR_MAGIC 0x48505541U
#define HPU_AMR_ABI 1U
/* Five little-endian u32 words; state: 0 starting, 1 ready, 2 failed. */
typedef struct {
    uint32_t magic, abi, ucore_major, ucore_minor, state;
} HpuAmrStatus;
void hpu_amr_status(uint32_t state);
void hpu_amr_run(void);
#endif
