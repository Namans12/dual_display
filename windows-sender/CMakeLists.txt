cmake_minimum_required(VERSION 3.20)
cmake_policy(SET CMP0091 NEW)  # MSVC_RUNTIME_LIBRARY controls the CRT flavor
project(ExtendedDisplaySender LANGUAGES CXX)

add_executable(ExtendedDisplaySender
    src/main.cpp
)

target_compile_features(ExtendedDisplaySender PRIVATE cxx_std_20)
target_link_libraries(ExtendedDisplaySender PRIVATE dxgi ws2_32 iphlpapi cfgmgr32)

if (MSVC)
    target_compile_options(ExtendedDisplaySender PRIVATE /W4 /permissive-)
    # Static CRT so the exe runs on a fresh Windows with no VC++ redistributable.
    set_property(TARGET ExtendedDisplaySender PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()
