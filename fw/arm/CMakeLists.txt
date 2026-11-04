# Copyright (c) 2023 Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT

cmake_minimum_required(VERSION 3.5.0)

project( amc )

add_definitions( -DRUN_TIME )
option( UCORE_LAT_TRACE "IOp latency trace in the AMC log" OFF )
if( UCORE_LAT_TRACE )
    add_definitions( -DUCORE_LAT_TRACE )
endif()

#adds test directories if test flag set to true
if( TEST_ENABLE )
    add_subdirectory( ./ext/CMocka )
    add_subdirectory( ./src/test )
    add_subdirectory( ./src/apps/in_band/test )
    add_subdirectory( ./src/osal/src/test/unittest )
    add_subdirectory( ./src/proxy_drivers/apc/test )
    add_subdirectory( ./src/proxy_drivers/axc/test )
    add_subdirectory( ./src/proxy_drivers/ami/test )
    add_subdirectory( ./src/proxy_drivers/asc/test )
    add_subdirectory( ./src/proxy_drivers/bmc/test )
else()
    #if build type not specified, default to Release: the firmware is the release artifact
    if(NOT CMAKE_BUILD_TYPE)
        set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Build type" FORCE)
    endif()

    #if OS not specified, default to FreeRTOS
    if(NOT OS)
        set(OS "FreeRTOS")
    else()
        set(OS "FreeRTOS")
    endif()

    if(OS MATCHES "^(FreeRTOS)$")
        set(CMAKE_C_COMPILER armr5-none-eabi-gcc)
        set(CMAKE_SYSTEM_NAME Generic)
        set(CMAKE_SYSTEM_PROCESSOR arm)
        set(CMAKE_CROSSCOMPILING 1)
        set(CMAKE_C_COMPILER_WORKS TRUE)

        # Machine description. Also required on the link line: it drives the multilib
        # selection of libgcc/libc
        set(ARCH_FLAGS "-mcpu=cortex-r5 -mfloat-abi=hard -mfpu=vfpv3-d16")

        # set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${ARCH_FLAGS} -Werror -Wall")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${ARCH_FLAGS}")
        # NB: replaces the CMake default `-O3 -DNDEBUG`, i.e. assert() is kept enabled
        set(CMAKE_C_FLAGS_RELEASE "-O3 -flto -funroll-loops -fomit-frame-pointer")

        # With LTO the final codegen happens at link time, it needs the same flags
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${ARCH_FLAGS}")
        set(CMAKE_EXE_LINKER_FLAGS_RELEASE "${CMAKE_EXE_LINKER_FLAGS_RELEASE} -O3 -flto")
        set(OSAL_PATH "src/osal/src/freeRTOS/osal.c")
        set(FW_IF_PATH "src/fal/gcq/fw_if_gcq_amc.c")
        set(FW_I2C_PATH "src/device_drivers/i2c/aved/i2c.c")
        set(FW_EMMC_PATH "src/device_drivers/emmc/aved/emmc.c")
        set(FW_SYS_MON_PATH "src/device_drivers/sensors/sys_mon/aved/sys_mon.c")
        set(FW_OSPI_PATH "src/device_drivers/ospi/aved/ospi.c")
        set(FW_IF_OSPI_PATH "src/fal/ospi/fw_if_ospi_amc.c")
        set(FW_IF_MUXED_DEVICE_PATH "src/fal/muxed_device/fw_if_muxed_device_amc.c")
        set(EEPROM_PATH "src/device_drivers/eeprom/aved/eeprom.c")
        set(STREAM_ISC_PATH "src/device_drivers/stream_isc/stream_isc.c")
        set(FW_IF_EMMC_PATH "src/fal/emmc/fw_if_emmc_amc.c")
        set(NAME "amc.elf")

    endif()

    #set custom profile with -DPROFILE flag (v80, Linux, etc), Defaults to v80 if not specified
    if(NOT PROFILE)
        include_directories(src/profiles/v80)
        set(PROFILE "v80")
        set(PROFILE_FAL_PATH "src/profiles/v80/profile_fal.c")
        add_definitions(-DOOB_ENABLED)
    else()
        include_directories(src/profiles/v80)
        set(PROFILE "v80")
        set(PROFILE_FAL_PATH "src/profiles/v80/profile_fal.c")
        add_definitions(-DOOB_ENABLED)
    endif()


    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

    message("=================================================")
    message("                 BUILD SETTINGS                  ")
    message("=================================================")
    message("OS: ${OS}")
    message("Build Type: ${CMAKE_BUILD_TYPE}")
    message("Profile: ${PROFILE}")
    message("Output Dir: ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")

    #Running prerequisite script
    execute_process(COMMAND ./scripts/getVersion.sh amc WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
    execute_process(COMMAND ./getVersion.sh gcq WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/src/device_drivers/gcq_driver )

    #BSP created by scripts/create_bsp.py
    set(BSP_DIR ${CMAKE_SOURCE_DIR}/amc_bsp/ws/amc_bsp)
    set(BSP_LIB_DIR ${BSP_DIR}/export/amc_bsp/sw/freertos_domain/lib)
    set(BSP_INCLUDE_DIR ${BSP_DIR}/psv_cortexr5_0/freertos_domain/bsp/include)
    if(NOT EXISTS ${BSP_LIB_DIR}/libxil.a)
        message(FATAL_ERROR "BSP not found in ${BSP_LIB_DIR}: run scripts/build.sh with -xsa first")
    endif()
    #the driver headers select their struct layouts on this define, as when the BSP was built
    add_definitions(-DSDT)

    #adding static libraries
    find_library(FREERTOS_LIB NAMES freertos PATHS ${BSP_LIB_DIR} NO_DEFAULT_PATH)
    find_library(XIL_LIB NAMES xil PATHS ${BSP_LIB_DIR} NO_DEFAULT_PATH)
    find_library(XIL_TIMER NAMES xiltimer PATHS ${BSP_LIB_DIR} NO_DEFAULT_PATH)
    find_library(XIL_STANDALONE NAMES xilstandalone PATHS ${BSP_LIB_DIR} NO_DEFAULT_PATH)
    find_library(XIL_FPGA NAMES xilfpga PATHS ${BSP_LIB_DIR} NO_DEFAULT_PATH)
    find_library(XIL_SECURE NAMES xilsecure PATHS ${BSP_LIB_DIR} NO_DEFAULT_PATH)
    find_library(XIL_MAILBOX NAMES xilmailbox PATHS ${BSP_LIB_DIR} NO_DEFAULT_PATH)

    #Include directories
    include_directories(${BSP_INCLUDE_DIR})
    include_directories(src/common/include)
    include_directories(src/common/core_libs/pll)
    include_directories(src/common/core_libs/evl)
    include_directories(src/common/core_libs/dal)
    include_directories(src/osal/src)
    include_directories(src/fal)
    include_directories(src/fal/test)
    include_directories(src/fal/gcq)
    include_directories(src/fal/ospi)
    include_directories(src/fal/muxed_device)
    include_directories(src/fal/emmc)
    include_directories(src/device_drivers/gcq_driver/src)
    include_directories(src/device_drivers/ospi)
    include_directories(src/device_drivers/sensors/ina3221)
    include_directories(src/device_drivers/sensors/isl68221)
    include_directories(src/device_drivers/sensors/cat34ts02)
    include_directories(src/device_drivers/sensors/sys_mon)
    include_directories(src/device_drivers/i2c)
    include_directories(src/device_drivers/emmc)
    include_directories(src/device_drivers/eeprom)
    include_directories(src/device_drivers/stream_isc)
    include_directories(src/proxy_drivers/axc)
    include_directories(src/proxy_drivers/apc)
    include_directories(src/proxy_drivers/asc)
    include_directories(src/proxy_drivers/ami)
    include_directories(src/proxy_drivers/bmc)
    include_directories(src/proxy_drivers/bmc/mctp)
    include_directories(src/proxy_drivers/bmc/pldm)
    include_directories(src/apps/asdm)
    include_directories(src/apps/in_band)
    include_directories(src/apps/in_band/mhdma_driver)
    include_directories(src/apps/in_band/trace)
    include_directories(src/apps/out_of_band)
    include_directories(src/apps/bim)

    #Add main app executable
    add_executable(${NAME}
                src/amc.c
                src/apps/in_band/trace/ucore_lat.c
                ${OSAL_PATH}
                src/common/core_libs/pll/pll.c
                src/common/core_libs/evl/evl.c
                src/common/core_libs/dal/dal.c
                ${FW_IF_PATH}
                ${FW_IF_OSPI_PATH}
                ${FW_IF_MUXED_DEVICE_PATH}
                ${FW_IF_EMMC_PATH}
                src/device_drivers/gcq_driver/src/gcq_driver.c
                src/device_drivers/gcq_driver/src/gcq_features.c
                src/device_drivers/gcq_driver/src/gcq_hw.c
                src/device_drivers/sensors/ina3221/ina3221.c
                src/device_drivers/sensors/isl68221/isl68221.c
                src/device_drivers/sensors/cat34ts02/cat34ts02.c
                ${FW_SYS_MON_PATH}
                ${FW_OSPI_PATH}
                ${FW_I2C_PATH}
                ${FW_EMMC_PATH}
                ${EEPROM_PATH}
                ${STREAM_ISC_PATH}
                src/proxy_drivers/axc/axc_proxy_driver.c
                src/proxy_drivers/apc/apc_proxy_driver.c
                src/proxy_drivers/asc/asc_proxy_driver.c
                src/proxy_drivers/ami/ami_proxy_driver.c
                src/proxy_drivers/bmc/bmc_proxy_driver.c
                src/proxy_drivers/bmc/mctp/mctp_commands.c
                src/proxy_drivers/bmc/mctp/mctp_interpreter.c
                src/proxy_drivers/bmc/mctp/mctp_parser.c
                src/proxy_drivers/bmc/pldm/pldm_commands.c
                src/proxy_drivers/bmc/pldm/pldm_parser.c
                src/proxy_drivers/bmc/pldm/pldm_pdr.c
                src/proxy_drivers/bmc/pldm/pldm_processor.c
                src/apps/asdm/asdm.c
                src/apps/in_band/in_band_telemetry.c
                src/apps/in_band/ucore.c
                src/apps/in_band/mhdma_driver/mhdma_driver.c
                src/apps/out_of_band/out_of_band_telemetry.c
                src/apps/bim/bim.c
                ${LINUX_HAL_MEM_BASE}
                ${PROFILE_FAL_PATH}
                )
                target_compile_options(${NAME} PRIVATE -Wall -Wno-packed-bitfield-compat)

    #linking libraries with executable
    if(OS MATCHES "^(FreeRTOS)$")
        target_link_libraries(amc.elf "-Wl,-T -Wl,../src/lscript.ld" -Wl,--start-group,${XIL_TIMER},${XIL_STANDALONE},${XIL_LIB},${FREERTOS_LIB},${XIL_FPGA},${XIL_SECURE},${XIL_MAILBOX},-lgcc,-lc,--end-group)
        target_compile_definitions(amc.elf PRIVATE $<$<CONFIG:Debug>:DEBUG_PRINT> GCQ_MAX_INSTANCES=1)
    endif()

endif()
