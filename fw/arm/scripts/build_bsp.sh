#!/bin/bash

# Copyright (c) 2023 Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT

################################################################################
#                                                                              #
# E.g. Build amc bsp:                                                          #
# ./build_bsp.sh -xsa <file path>                                              #
#                       -os freertos10_xilinx                                  #
#                                                                              #
#                                                                              #
# This will create a bsp (amc_bsp) in the top level directory                  #
#                                                                              #
#                                                                              #
#                                                                              #
################################################################################

################################################################################
###                                 Variables                                ###
################################################################################

ARCH_DIR=archive
### store xsa path ###
xsa=0
### store os param ###
os=0
### store FREERTOS_DEBUG param ###
FREERTOS_DEBUG=0
### FreeRTOS number of ticks per second ###
TICK_RATE_HZ=1000

### Heap size ###
HEAP_SIZE=131072

################################################################################
###                                 Functions                                ###
################################################################################

################################################################################
#
# This function will display syntax diagram, with description of each option
#
################################################################################
function help() {
    echo
    echo
    echo "Usage: ./create_bsp.sh [options]"
    echo "./create_bsp.sh will generate a BSP based on specified xsa and os"
    echo "All below options must be specified!"
    echo
    echo "Options:"
    echo "-xsa       [file path]    Specify .xsa file path"
    echo "-os        [name]         Specify target os (eg standalone)"
    echo "-clean                    Remove all vitis source directories"
    echo "-help                     Print this help"
    echo
    echo
}
################################################################################

################################################################################
#
# This function will remove all vitis source directories
#
################################################################################
function clean() {
    echo "Removing all vitis source files"
    rm -r .Xil
    rm -r .metadata
    rm -r .analytics
    rm -r IDE.log
}

################################################################################

################################################################################
###                           Script Starting Point                          ###
################################################################################

### handle options ###

### while-done structure defines a loop ###
### that executes once for each passed option ###
while [ $# -gt 0 ]; do
    ### case-esac structure evaluates each option ###
    case "$1" in
    -help)
        ### display Help ###
	    help
	    exit;;
    -clean)
        ### clean vitis source directories ###
	    clean
	    exit;;
	-xsa)
	    shift  ### shift to next passed variable (-xsa *) ###
	    xsa=$1 ### store option into xsa variable ###

        ### handle empty string ###
	    if [ "x$1" = x ]
            then
                    echo "Error: Invalid option"
                    help
                    exit
            else
                ### print out xsa path ###
                echo "xsa path set==>$xsa"
            fi
	    ;;

	-os)
	    shift
	    os=$1

	    if [ "x$1" = x  ]
            then
		    echo "Error: Invalid option"
	    	    help
		    exit
	    else
		echo "target os set ==> $os"
	    fi
	    ;;
    -freertos_debug)
	    FREERTOS_DEBUG=1
	    ;;
        *|--*|-*)
            ### Invalid option ###
            echo "Error: Invalid option"
	        help ### display help ###
            exit;;
    esac
    shift ### shift to next passed option ###
done

### start initial build ###

### handle xsa file path ###
if [ $xsa == 0 ] ### if xsa not specified ###
    then
        echo "Error: Please specify .xsa file path"
        help
        exit
fi

### handle os ###
if [ $os == 0 ] ### if os not specified ###
    then
	echo "Error: Please specify target os"
	help
	exit
fi

echo "=== Creating BSP in vitis ==="
cd ..
vitis -s ./scripts/create_bsp.py "$xsa" "$os" "$TICK_RATE_HZ" "$HEAP_SIZE" "$FREERTOS_DEBUG"
