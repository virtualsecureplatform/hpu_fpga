# (c) Copyright 2024, Advanced Micro Devices, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
############################################################

# TODO Remove interface UUID once ART is available

   # For now, this script:
   # - Calculates a platform Logic-UUID;
   # - Calculates a platform Interface-UUID from the routed checkpoint;
   # - Inserts the Logic-UUID and Interface-UUID into a dictionary in a file used by write_hw_platform.
   # =========================================================================

   # (from amd)
   proc find_dir {base name} {
     set res [glob -nocomplain -types d -directory $base $name]
     if {$res != {}} {
       return $res
     }
     foreach dir [glob -nocomplain -types d -directory $base *] {
       set res [find_dir [file join $base $dir] $name]
       if {$res != {}} {
         return $res
       }
     }
     return {}
   }

   # A worker resumed from a DCP may not retain the project's IP_REPO_PATHS.
   # PROJECT_DIR is exported by setup.sh for both full and resumed builds.
   proc find_uuid_update_script {} {
      set repo_paths [get_property IP_REPO_PATHS [current_project]]
      if {[info exists ::env(PROJECT_DIR)]} {
         lappend repo_paths [file join $::env(PROJECT_DIR) versal iprepo]
      }
      foreach repo_path [lsort -unique $repo_paths] {
         if {![file isdirectory $repo_path]} { continue }
         set uuid_dir [find_dir $repo_path shell_utils_uuid_rom_v2_0]
         if {$uuid_dir eq {}} { continue }
         set candidate [file join $uuid_dir tcl update_uuid_rom.tcl]
         if {[file isfile $candidate] && [file readable $candidate]} {
            return [file normalize $candidate]
         }
      }
      error "update_uuid_rom.tcl not found in IP repositories: $repo_paths"
   }

   # (from amd) procedure:  update the Logic UUID ROM
   # Input is 64 hex character string (256-bit UUID)
   proc update_logic_uuid_rom {uuid} {

      set update_uuid_rom [find_uuid_update_script]
      puts "INFO: UUID update script: $update_uuid_rom"
      source $update_uuid_rom

      # Search for the BLP_LOGIC_UUID_ROM cell path in the netlist, return an error if not found
      set uuid_cell [get_cells -hier -filter {NAME =~ "*uuid_rom" && PARENT =~ "*base_logic"}]
      if {$uuid_cell eq ""} {
         return -code error "ERROR: BLP_LOGIC_UUID_ROM cell not found in netlist, Logic UUID not populated."
      }

      # Call the update_uuid_rom script to update the Logic UUID ROM, return the response
      return [update_uuid_rom $uuid $uuid_cell]
   }

   # procedure: checks username and return appropriate value
   # goal is to have an identifier for each user in alphabetic order with empty slots
   # invited or unknown is 0 for now
   proc find_user {} {
      set username_hash [string range [exec echo $::env(USER) | md5sum] 0 31]

      array set user_map {
         "558f3ab7fdafd631c9b43d0f81d18ca0" 2
         "835e74a3bb3d8aa4a97585f48576dc42" 5
         "66bbf32c826120d5d493b747a81f4ec7" 8
         "0e8649b48bd832b526cee46a04ba6df5" B
         "8b9e2b10ef84451b59ea91049c20b931" E
      }
      return [expr {[info exists user_map($username_hash)] ? $user_map($username_hash) : 0}]
   }

   # procedure: finds hostname and return corresponding value depending on compilation server
   # if the server used is srvzama returns 1, otherwise 0
   proc find_host {} {
      set hostname [info hostname]
      return [expr {$hostname eq "srvzama" ? 1 : 0}]
   }

   # procedure: correspondence between each PSI and output digit
   # returns 1 digit: 0=16, 1=32, 2=64
   proc define_psi {ntt_psi} {
      array set psi_map {
         16  0
         32  1
         64  2
         128 3
      }
      return [expr {[info exists psi_map($ntt_psi)] ? $psi_map($ntt_psi) : F}]
   }

   # procedure: find in vivado's synthesis log the value of input "parameter"
   # most parameters can't be found in edalize.tcl file and we want to be sure
   # their value are from synthesis's output
   proc find_parameter {parameter} {
      set run_directory [file normalize [get_property DIRECTORY [current_project]]]
      set work_directory [file dirname [file dirname $run_directory]]
      set top_name [get_property TOP [current_design]]
      set top_vds_path "$work_directory/prj.runs/synth_1/$top_name.vds"
      if {[info exists ::env(HPU_SYNTHESIS_VDS)]} {
         set top_vds_path $::env(HPU_SYNTHESIS_VDS)
      }

      # Check if file exists
      if {![file exists $top_vds_path]} {
         error "Missing synthesis metadata: $top_vds_path"
      }

      set fileHandle [open $top_vds_path r]
      set pattern "Parameter $parameter"
      set decimalValue ""

      while {[gets $fileHandle line] >= 0} {
         # check if the line contains our pattern
         if {[string first $pattern $line] != -1} {
               # extract the binary value
               if {[regexp {32'sb([01]+)} $line -> binaryValue]} {
                  # convert binary to decimal
                  set decimalValue [expr 0b$binaryValue]
                  break
               }
         }
      }
      close $fileHandle

      if {$decimalValue eq ""} {
         error "Parameter $parameter not found in $top_vds_path"
      } else {
         return $decimalValue
      }
   }

   # procedure: define uuid such as uuid corresponds to 256 digits including
   # - time of compilation: position [9:0]
   #     format as YYMMDDHHMM
   # - User alphabetic order with empty slots: position [10]
   # - Compilation machine: position [11]
   #     (1 digit: 0x1 srvzama, 0x0 others)
   # - HPU compilation parameters (14 digits): position [19:12]
   #     - PSI (1 digit: 0=16, 1=32, 2=64…)
   #     - NTT Arch (1 digit: 5=GF64, 4=unfold…)
   #     - HPU Version (2 digits, today 2.0)
   #     - Frequency of main clk (4 digits: 0100 to 0400 on FPGA)
   # - GIT hash: position [26:20]
   # - 5 unused digits: position [31:27]
   # example : 00000606b36c 03002000 1 0 2504202055
   proc set_uuid {} {
      # this script is executed as a pre write device image during implementation step
      # this implies we are in prj.run/impl_1
      set run_directory [file normalize [get_property DIRECTORY [current_project]]]
      # in order to find work directory we must go back two folders
      set work_directory [file dirname [file dirname $run_directory]]

      # sourcing uservars to have effective ntt_psi
      set uservars $work_directory/uservars.tcl
      if {[info exists ::env(HPU_USERVARS)]} { set uservars $::env(HPU_USERVARS) }
      source $uservars

      # timestamp must have as format: YYMMDDHHMM (10 digit)
      set current_time [clock seconds]
      set timestamp [clock format [clock seconds] -format "%y%m%d%H%M"]

      set user_value [find_user]
      set host_value [find_host]

      if {[info exists ::env(HPU_SOURCE_REVISION)]} {
         set git_hash [string range $::env(HPU_SOURCE_REVISION) 0 6]
      } else {
         set git_hash [exec git rev-parse --short=7 HEAD]
      }
      if {![regexp {^[0-9a-f]{7}$} $git_hash]} { error "Invalid source revision" }

      # we want to have the parameters mapped during synthesis, this can be done reading .vds file
      # over there we can find NTT_ARCH and HPU version major and minor
      # ntt_arch corresponds to last digit of synthesis parameter
      set ntt_arch [string index [find_parameter "NTT_CORE_ARCH"] end ]
      # hpu versions are directly read
      set hpu_version_maj [find_parameter "VERSION_MAJOR"]
      set hpu_version_min [find_parameter "VERSION_MINOR"]

      # PSI is already present through uservars
      set psi [define_psi $::ntt_psi]

      # clock frequency can be found directly within vivado
      # we want to find the clock frequency of prc_clk in the top RTL file
      set clock_period [get_property PERIOD [get_clocks prc_clk]]
      set hpu_freq  [ format "%04d" [expr {round([expr 1000.0 / $clock_period])}] ]

      # 5 digits remain for later use
      set zero_filler "00000"

      puts "INFO: Building logic UUID ..."
      puts "INFO: git hash      $git_hash"
      puts "INFO: HPU frequency $hpu_freq"
      puts "INFO: version major $hpu_version_maj"
      puts "INFO: version minor $hpu_version_min"
      puts "INFO: NTT arch      $ntt_arch"
      puts "INFO: PSI           $psi"
      puts "INFO: host value    $host_value"
      puts "INFO: user value    $user_value"
      puts "INFO: timestamp     $timestamp"
      set uuid [format %s%s%s%s%s%s%s%s%s%s $zero_filler $git_hash $hpu_freq $hpu_version_maj $hpu_version_min $ntt_arch $psi $host_value $user_value $timestamp]
      if {![regexp {^[0-9a-fA-F]{32}$} $uuid]} { error "Invalid logic UUID: $uuid" }
      puts "INFO: generated UUID is $uuid"
      return $uuid
   }

   if {![info exists ::env(PROJECT_DIR)]} { error "PROJECT_DIR is required for image signoff" }
   if {[info exists ::env(HPU_SIGNOFF_SCRIPT)]} {
      source $::env(HPU_SIGNOFF_SCRIPT)
   } else {
      source [file join $::env(PROJECT_DIR) versal scripts timing_signoff.tcl]
   }
   set signoff_checkpoint [file join [pwd] postroute_physopt.dcp]
   if {[info exists ::env(HPU_ROUTED_CHECKPOINT)]} { set signoff_checkpoint $::env(HPU_ROUTED_CHECKPOINT) }
   hpu_signoff::run [file join [pwd] signoff_pre_uuid] $signoff_checkpoint
   set top_name [get_property TOP [current_design]]

   # Code to generate a Logic-UUID from the synthesized checkpoint
   # Get the absolute directory path of the project synth_1 run
   set synth_fname [file normalize "../synth_1/"]

   # from procedure, calculate a Logic-UUID and populate the ROM with it
   set logic_uuid [set_uuid]
   puts "INFO: updating logic-UUID as $logic_uuid"
   update_logic_uuid_rom $logic_uuid

   # Create a dictionary of each cell that will require a generated UUID, starting with design top
   set design_top [lindex [get_cells] 0]
   set uuid_dict [dict create logic_uuid $logic_uuid]

   # Generate a UUID and add it to the dictionary for ulp cell
   set dfx_cells [list top_i/ulp]
   if {1 != [llength $dfx_cells]} {
      return -code error "ERROR: more than one reconfigurable partition found; this is not currently supported, so cannot generate Interface-UUID."
   }
   foreach {dfx_cell} $dfx_cells {
      # Code to generate an Interface-UUID from the routed checkpoint
      # Get the absolute directory path of the project impl_1 run
      set route_fname [file normalize "./"]

      # Use md5sum to calculate an Interface-UUID, or return an error if the checkpoint isn't found
      set routed_checkpoint ${route_fname}/${top_name}_routed.dcp
      if {[info exists ::env(HPU_ROUTED_CHECKPOINT)]} { set routed_checkpoint $::env(HPU_ROUTED_CHECKPOINT) }
      if {[file exists $routed_checkpoint]} {
         set interface_uuid [lindex [exec md5sum $routed_checkpoint] 0]
         puts "Interface-UUID is $interface_uuid"
         dict set uuid_dict interface_uuid ${interface_uuid}
      } else {
         return -code error "ERROR: routed checkpoint ${top_name}_routed.dcp not found, cannot generate Interface-UUID."
      }
   }

   # Now write the full dictionary, consisting of key-value pairs of the top cell and its Logic-UUID, and the reconfigurable module
   # and its Interface-UUID, to a file with predetermined name required for the write_hw_platform flow.
   set metadata_dir [get_property DIRECTORY [current_project]]
   if {[info exists ::env(HPU_IMAGE_METADATA_DIR)]} { set metadata_dir $::env(HPU_IMAGE_METADATA_DIR) }
   set uuid_file [open [file join $metadata_dir "pfm_uuid_manifest.dict"] w]
   puts $uuid_file $uuid_dict
   close $uuid_file

# Enable automatic loading of bitstream USR_ACCESS 32-bit register with timestamp
# TODO why is this set here and not in build_hw.tcl?
set_property BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP [current_design]

# UUID updates change LUT contents. Sign off the exact design sent to Bootgen.
write_checkpoint -force [file join [pwd] image_input.dcp]
hpu_signoff::run [file join [pwd] signoff_image_input] [file join [pwd] image_input.dcp]
set checkpoint_hash [lindex [exec sha256sum [file join [pwd] image_input.dcp]] 0]
set hash_file [open [file join [pwd] signoff_image_input checkpoint.sha256] w]
puts $hash_file "$checkpoint_hash  image_input.dcp"
close $hash_file
