// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
//
// IOp latency trace on the R5. Build with -DUCORE_LAT_TRACE (CMake option UCORE_LAT_TRACE),
// otherwise every hook compiles to nothing and the firmware is unchanged.
//
// One record per IOp (indexed by iid, IOps overlap), stamped with the PMU cycle counter at the
// steps below. After the host ack the record is printed as two lines of the AMC log:
//   [LAT] H<hpu> <iid> A q<0|1> poll <c> parse <c> f0 <c> fN <c>
//   [LAT] H<hpu> <iid> B run <c> isr <c> tear <c> wt <c> rt <n>
//   [LAT] H<hpu> <iid> C isc <c> dep <c> src <c> flg <c>
// with, in PMU counts (see [LAT] init):
//   q     1: the previous queue read found an IOp, this IOp waited behind it
//   poll  previous queue read -> IOp seen. q0: detection delay. q1: IOp period
//   parse IOp seen -> IOp parsed, DOp table found
//   f0    IOp parsed -> first DOp chunk sent to the ISC
//   fN    first -> last DOp chunk sent
//   run   last DOp chunk sent -> ack interrupt (HPU execution)
//   isr   ack interrupt -> teardown started in the worker task
//   tear  teardown started -> host ack written. 0: acked from the ISR (single-HPU IOp)
//   wt    part of tear: wait for the destinations produced on other HPUs
//   rt    ISC FIFO full retries while sending the DOps (count)
//   isc   part of f0+fN: wait for space in the ISC FIFO
//   dep   part of f0+fN: wait for a local source IOp to be done
//   src   part of f0+fN: wait for a remote source
//   flg   part of f0+fN: wait for a WAIT DOp flag

#ifndef __UCORE_LAT_H__
#define __UCORE_LAT_H__

#include <stdint.h>

typedef enum {
  LAT_POLL_PREV = 0, // previous read of the IOp queue
  LAT_SEEN,          // IOp found in the queue
  LAT_PARSED,        // IOp parsed, DOp table found
  LAT_FIRST_FLUSH,   // first DOp chunk sent to the ISC
  LAT_LAST_FLUSH,    // last DOp chunk (SYNC) sent to the ISC
  LAT_ACK_ISR,       // outer SYNC ack popped in the ISR
  LAT_TEARDOWN,      // worker task starts iop_teardown
  LAT_WT_START,      // teardown: wait for the destinations produced on other HPUs
  LAT_WT_DONE,       // teardown: all owned destinations resolved
  LAT_ACK_HOST,      // ack written to the host queue
  LAT_NB
} lat_stage_t;

typedef enum {
  LAT_WAIT_ISC = 0,  // ISC FIFO full
  LAT_WAIT_DEP,      // local source IOp not done
  LAT_WAIT_SRC,      // remote source not read
  LAT_WAIT_FLG,      // WAIT DOp flag not received
  LAT_WAIT_NB
} lat_wait_t;

typedef struct {
  uint32_t cyc[LAT_NB]; // PMU cycle counter
  uint32_t wait[LAT_WAIT_NB]; // PMU counts in each wait
  uint16_t flush_nb;   // DOp chunks sent to the ISC
  uint16_t retry_nb;   // ISC stream FIFO full retries
  uint8_t queued;      // IOp waited in the queue behind another IOp
} lat_rec_t;

#if defined(UCORE_LAT_TRACE) && !defined(UCORE_MHDMA_SIMU)

extern volatile lat_rec_t lat_rec[256];
extern uint8_t cur_iid;

// Read the cycle counter of the CPU Performance Monitoring Unit (PMU).
// The counter is the PMCCNTR register of the Cortex-R5.
// PMCR.D = 1: the counter adds 1 each 64 CPU cycles. LAT_INIT prints the counts per ms.
static inline uint32_t lat_cycles(void) {
  uint32_t c;
  asm volatile("MRC p15, 0, %0, c9, c13, 0" : "=r"(c));
  return c;
}

void lat_init(void);
void lat_poll(uint8_t busy);
void lat_parsed(uint8_t iid);
void lat_flush(void);
void lat_dump(uint8_t iid);

#define LAT_INIT()         lat_init()
#define LAT_STAMP(iid, st) (lat_rec[(uint8_t)(iid)].cyc[(st)] = lat_cycles())
#define LAT_POLL(busy)     lat_poll(busy)
#define LAT_PARSED(iid)    lat_parsed(iid)
#define LAT_FLUSH()        lat_flush()
#define LAT_RETRY()        (lat_rec[cur_iid].retry_nb++)
#define LAT_DUMP(iid)      lat_dump(iid)
// LAT_WAIT_BEGIN declares t. LAT_WAIT_END adds the time since t to the wait w.
#define LAT_WAIT_BEGIN(t)       uint32_t t = lat_cycles()
#define LAT_WAIT_END(iid, w, t) (lat_rec[(uint8_t)(iid)].wait[(w)] += lat_cycles() - (t))

#else

#define LAT_INIT()         ((void)0)
#define LAT_STAMP(iid, st) ((void)0)
#define LAT_POLL(busy)     ((void)0)
#define LAT_PARSED(iid)    ((void)0)
#define LAT_FLUSH()        ((void)0)
#define LAT_RETRY()        ((void)0)
#define LAT_DUMP(iid)      ((void)0)
#define LAT_WAIT_BEGIN(t)
#define LAT_WAIT_END(iid, w, t) ((void)0)

#endif

#endif // __UCORE_LAT_H__
