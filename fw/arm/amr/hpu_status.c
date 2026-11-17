/* AMR-only glue: HPU status block for the host and OSAL additions. */
#include "FreeRTOS.h"
#include "task.h"
#include "sleep.h"
#include "osal.h"
#include "hpu_amr.h"
#include "ucore.h"
#include "xil_cache.h"

void hpu_amr_status(uint32_t state)
{
    volatile HpuAmrStatus *s = (volatile HpuAmrStatus *)HPU_AMR_STATUS_ADDR;
    s->magic = HPU_AMR_MAGIC;
    s->abi = HPU_AMR_ABI;
    s->ucore_major = UCORE_VERSION_MAJOR;
    s->ucore_minor = UCORE_VERSION_MINOR;
    s->state = state;
    Xil_DCacheFlushRange(HPU_AMR_STATUS_ADDR, sizeof(*s));
}

/* Same as src/osal: below one tick the OS cannot block a task, so let the ready
 * tasks of the same priority run first, then busy-wait. */
int iOSAL_Task_SleepUs(uint32_t ulSleepUs)
{
    if (taskSCHEDULER_NOT_STARTED == xTaskGetSchedulerState()) {
        return OSAL_ERRORS_OS_NOT_STARTED;
    }
    taskYIELD();
    usleep(ulSleepUs);
    return OSAL_ERRORS_NONE;
}
