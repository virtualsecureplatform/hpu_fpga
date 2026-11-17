/* Forced include only for the AMR HPU firmware build. Never use AVED HAL. */
#ifndef HPU_AMR_PROFILE_H
#define HPU_AMR_PROFILE_H
#include "profile_hal.h"
#include "hpu_amr.h"
#include "xinterrupt_wrap.h"
#include "xparameters_ps.h"
#define HAL_RPU_SHARED_MEMORY_BASE_ADDR HPU_SHARED_BASE
#define HAL_INVALIDATE_CACHE_DATA(addr, size) Xil_DCacheInvalidateRange(addr, size)
#define XPAR_AXI_FIFO_0_BASEADDR XPAR_XLLFIFO_0_BASEADDR
#ifndef RETRY
#define RETRY ( 2 )
#endif
/* Not part of AMR's OSAL; implemented in hpu_status.c. */
int iOSAL_Task_SleepUs(uint32_t ulSleepUs);
/* Versal CIPS pl_ps_irq0..5 map to RPU GIC SPI 116..121. The BSP's
 * XPAR_FPGAx_INTERRUPT_ID values instead encode the ZynqMP 121..126 map.
 * We confirmed pl_ps_irq1 -> GIC 117 using the debug interrupt register.
 * xinterrupt_wrap expects SPI ID minus 32 in bits [11:0] and trigger type
 * in bits [15:12]. Keep the ISC acknowledgement edge-triggered. */
#define HPU_AMR_SPI_ID(irq, trigger) (((irq) - 32U) | ((trigger) << 12))
#define XPAR_FABRIC_RTL_INTERRUPT_0_INTR HPU_AMR_SPI_ID(117U, XIL_TRIG_ACTIVE_HIGH_LEVEL)
#define XPAR_FABRIC_RTL_INTERRUPT_1_INTR HPU_AMR_SPI_ID(118U, XIL_TRIG_LOW_TO_HIGH_EDGE)
#define XPAR_FABRIC_RTL_INTERRUPT_3_INTR HPU_AMR_SPI_ID(120U, XIL_TRIG_ACTIVE_HIGH_LEVEL)
#define XPAR_FABRIC_RTL_INTERRUPT_4_INTR HPU_AMR_SPI_ID(121U, XIL_TRIG_ACTIVE_HIGH_LEVEL)
_Static_assert(HAL_GCQ_SHARED_BASEADDR == 0x10000000, "AMR mailbox moved");
_Static_assert(HAL_RPU_SHARED_MEMORY_ENDADDR <= HPU_AMR_STATUS_ADDR, "Status overlaps AMR allocation");
_Static_assert(HPU_AMR_STATUS_ADDR + sizeof(HpuAmrStatus) <= 0x10800000, "Status outside BAR window");
#endif
