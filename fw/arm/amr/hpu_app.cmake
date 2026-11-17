# HPU application sources for the AMR management firmware.
# Included by AMR's fw/AMC/CMakeLists.txt when -DHPU_APP_DIR=<hpu_fpga>/fw/arm is given
# (see amr/amr-3.0.0-hpu.patch). Keeping the list here lets it follow the HPU sources.
if(NOT PROFILE STREQUAL "v80")
    message(FATAL_ERROR "HPU requires the v80 management profile")
endif()
if(NOT EXISTS "${BSP_SPECS}")
    message(FATAL_ERROR "HPU build requires matching Vitis BSP_SPECS")
endif()

set(HPU_APP_SOURCES
    ${HPU_APP_DIR}/amr/hpu_app.c
    ${HPU_APP_DIR}/amr/hpu_status.c
    ${HPU_APP_DIR}/src/apps/in_band/ucore.c
    ${HPU_APP_DIR}/src/apps/in_band/trace/ucore_lat.c
    ${HPU_APP_DIR}/src/apps/in_band/mhdma_driver/mhdma_driver.c
    ${HPU_APP_DIR}/src/device_drivers/stream_isc/stream_isc.c)

option(UCORE_LAT_TRACE "IOp latency trace in the AMC log" OFF)
if(UCORE_LAT_TRACE)
    target_compile_definitions(${NAME} PRIVATE UCORE_LAT_TRACE)
endif()

target_sources(${NAME} PRIVATE ${HPU_APP_SOURCES})
target_include_directories(${NAME} PRIVATE
    ${HPU_APP_DIR}/amr
    ${HPU_APP_DIR}/src/apps/in_band
    ${HPU_APP_DIR}/src/apps/in_band/mhdma_driver
    ${HPU_APP_DIR}/src/apps/in_band/trace
    ${HPU_APP_DIR}/src/device_drivers/stream_isc)
target_compile_definitions(${NAME} PRIVATE AMC_HPU_APP)
# The HPU sources expect the AVED HAL names: map them onto AMR's profile.
set_source_files_properties(${HPU_APP_SOURCES}
    PROPERTIES COMPILE_OPTIONS "-include;${HPU_APP_DIR}/amr/hpu_profile.h")
set(AMC_LINKER_SCRIPT "${HPU_APP_DIR}/src/lscript.ld")
target_link_options(${NAME} PRIVATE "-specs=${BSP_SPECS}" -Wl,--undefined=_boot "-Wl,-Map,${CMAKE_BINARY_DIR}/amc.map")
