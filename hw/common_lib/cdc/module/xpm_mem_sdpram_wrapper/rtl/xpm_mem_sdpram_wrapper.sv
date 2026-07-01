// ==============================================================================================
// BSD 3-Clause Clear License
// Copyright © 2025 ZAMA. All rights reserved.
// ==============================================================================================
// Description  : Simple wrapper around the XPM simple-dual-port RAM (independent clocks)
// ----------------------------------------------------------------------------------------------
//
// Dual-clock simple-dual-port RAM: dedicated write port on wr_clk, dedicated read port on rd_clk.
// Supported on Versal (see am007-versal-memory.pdf p46/p92: XPM is a supported design-entry
// method for Versal block RAM / UltraRAM).
//
// Documentation about the XPM module:
// https://docs.amd.com/r/en-US/ug1353-versal-architecture-ai-libraries/XPM_MEMORY_SDPRAM
//
// Read port has READ_LATENCY cycles of latency: rd_data is valid READ_LATENCY rd_clk cycles after
// rd_addr/rd_en are presented.
// ==============================================================================================

module xpm_mem_sdpram_wrapper #(
  parameter int DATA_W           = 128,
  parameter int DEPTH            = 64,
  parameter int READ_LATENCY     = 1,
  parameter     MEMORY_PRIMITIVE = "auto",
  localparam int ADDR_W          = $clog2(DEPTH)
) (
  // Write domain
  input  logic              wr_clk,
  input  logic              wr_en,
  input  logic [ADDR_W-1:0] wr_addr,
  input  logic [DATA_W-1:0] wr_data,
  // Read domain
  input  logic              rd_clk,
  input  logic              rd_rstn,
  input  logic              rd_en,
  input  logic [ADDR_W-1:0] rd_addr,
  output logic [DATA_W-1:0] rd_data
);

  // xpm_memory_sdpram: Simple Dual Port RAM
  // Xilinx Parameterized Macro, version 2025.1
  xpm_memory_sdpram #(
    .ADDR_WIDTH_A           (ADDR_W            ), // DECIMAL
    .ADDR_WIDTH_B           (ADDR_W            ), // DECIMAL
    .AUTO_SLEEP_TIME        (0                 ), // DECIMAL
    .BYTE_WRITE_WIDTH_A     (DATA_W            ), // DECIMAL (single write-enable)
    .CASCADE_HEIGHT         (0                 ), // DECIMAL
    .CLOCKING_MODE          ("independent_clock"), // String
    .ECC_MODE               ("no_ecc"          ), // String
    .MEMORY_INIT_FILE       ("none"            ), // String
    .MEMORY_INIT_PARAM      ("0"               ), // String
    .MEMORY_OPTIMIZATION    ("true"            ), // String
    .MEMORY_PRIMITIVE       (MEMORY_PRIMITIVE  ), // String
    .MEMORY_SIZE            (DATA_W * DEPTH    ), // DECIMAL (total bits)
    .MESSAGE_CONTROL        (0                 ), // DECIMAL
    .READ_DATA_WIDTH_B      (DATA_W            ), // DECIMAL
    .READ_LATENCY_B         (READ_LATENCY      ), // DECIMAL
    .READ_RESET_VALUE_B     ("0"               ), // String
    .RST_MODE_A             ("SYNC"            ), // String
    .RST_MODE_B             ("SYNC"            ), // String
    .SIM_ASSERT_CHK         (0                 ), // DECIMAL
    .USE_EMBEDDED_CONSTRAINT(0                 ), // DECIMAL
    .USE_MEM_INIT           (0                 ), // DECIMAL
    .WAKEUP_TIME            ("disable_sleep"   ), // String
    .WRITE_DATA_WIDTH_A     (DATA_W            ), // DECIMAL
    .WRITE_MODE_B           ("read_first"      )  // String
  ) xpm_memory_sdpram (
    .doutb        (rd_data    ),
    .addra        (wr_addr    ),
    .addrb        (rd_addr    ),
    .clka         (wr_clk     ),
    .clkb         (rd_clk     ),
    .dina         (wr_data    ),
    .ena          (1'b1       ),
    .enb          (rd_en      ),
    .injectdbiterra(1'b0      ),
    .injectsbiterra(1'b0      ),
    .regceb       (1'b1       ),
    .rstb         (~rd_rstn   ),
    .sleep        (1'b0       ),
    .wea          (wr_en      ),
    .dbiterrb     (/* UNUSED */),
    .sbiterrb     (/* UNUSED */)
  );

endmodule
