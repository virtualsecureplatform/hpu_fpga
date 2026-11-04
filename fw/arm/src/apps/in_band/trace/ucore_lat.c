// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// IOp latency trace on the R5, see ucore_lat.h

#include "ucore_lat.h"

#if defined(UCORE_LAT_TRACE) && !defined(UCORE_MHDMA_SIMU)

#include <string.h>
#include "osal.h"
#include "pll.h"

extern uint8_t phys_hpu_id;

volatile lat_rec_t lat_rec[256];
// Last two reads of the IOp queue: time and IOp found
static uint32_t lat_poll_prev = 0;
static uint32_t lat_poll_cur = 0;
static uint8_t lat_busy_prev = 0;
static uint8_t lat_busy_cur = 0;

// Measure the counter unit: count between two OS tick edges, about 100 ms apart
void lat_init(void) {
  uint32_t pmcr;
  asm volatile("MRC p15, 0, %0, c9, c12, 0" : "=r"(pmcr));
  uint32_t ms0 = ulOSAL_GetUptimeMs();
  while (ulOSAL_GetUptimeMs() == ms0) {}
  uint32_t c0 = lat_cycles();
  ms0 = ulOSAL_GetUptimeMs();
  iOSAL_Task_SleepMs(100);
  uint32_t ms1 = ulOSAL_GetUptimeMs();
  while (ulOSAL_GetUptimeMs() == ms1) {}
  uint32_t c1 = lat_cycles();
  ms1 = ulOSAL_GetUptimeMs();
  PLL_ERR("LAT", "init pmcr 0x%lx cnt_per_ms %lu",
          (unsigned long)pmcr, (unsigned long)((c1 - c0) / (ms1 - ms0)));
}

// Read of the IOp queue, at each main loop pass
void lat_poll(uint8_t busy) {
  lat_poll_prev = lat_poll_cur;
  lat_busy_prev = lat_busy_cur;
  lat_poll_cur = lat_cycles();
  lat_busy_cur = busy;
}

// IOp parsed: open the record of this iid with the stamps taken before the iid was known
void lat_parsed(uint8_t iid) {
  memset((void *)&lat_rec[iid], 0, sizeof(lat_rec_t));
  lat_rec[iid].cyc[LAT_POLL_PREV] = lat_poll_prev;
  lat_rec[iid].cyc[LAT_SEEN] = lat_poll_cur;
  lat_rec[iid].queued = lat_busy_prev;
  LAT_STAMP(iid, LAT_PARSED);
}

// DOp chunk sent to the ISC: the first one is a stamp, the others a count
void lat_flush(void) {
  if (lat_rec[cur_iid].flush_nb++ == 0) {
    LAT_STAMP(cur_iid, LAT_FIRST_FLUSH);
  }
}

// Dumping log to dmesg
void lat_dump(uint8_t iid) {
  volatile lat_rec_t *r = &lat_rec[iid];
  // PLL_ERR: visible at the default log level on both the console and the host log
  PLL_ERR("LAT", "H%u %u A q%u poll %lu parse %lu f0 %lu fN %lu",
          (unsigned)phys_hpu_id, (unsigned)iid, (unsigned)r->queued,
          (unsigned long)(r->cyc[LAT_SEEN] - r->cyc[LAT_POLL_PREV]),
          (unsigned long)(r->cyc[LAT_PARSED] - r->cyc[LAT_SEEN]),
          (unsigned long)(r->cyc[LAT_FIRST_FLUSH] - r->cyc[LAT_PARSED]),
          (unsigned long)(r->cyc[LAT_LAST_FLUSH] - r->cyc[LAT_FIRST_FLUSH]));
  PLL_ERR("LAT", "H%u %u B run %lu isr %lu tear %lu wt %lu rt %u",
          (unsigned)phys_hpu_id, (unsigned)iid,
          (unsigned long)(r->cyc[LAT_ACK_ISR] - r->cyc[LAT_LAST_FLUSH]),
          (unsigned long)(r->cyc[LAT_TEARDOWN] - r->cyc[LAT_ACK_ISR]),
          (unsigned long)(r->cyc[LAT_ACK_HOST] >= r->cyc[LAT_TEARDOWN]
                          ? r->cyc[LAT_ACK_HOST] - r->cyc[LAT_TEARDOWN] : 0),
          (unsigned long)(r->cyc[LAT_WT_DONE] - r->cyc[LAT_WT_START]),
          (unsigned)r->retry_nb);
  PLL_ERR("LAT", "H%u %u C isc %lu dep %lu src %lu flg %lu",
          (unsigned)phys_hpu_id, (unsigned)iid,
          (unsigned long)r->wait[LAT_WAIT_ISC],
          (unsigned long)r->wait[LAT_WAIT_DEP],
          (unsigned long)r->wait[LAT_WAIT_SRC],
          (unsigned long)r->wait[LAT_WAIT_FLG]);
}

#endif
