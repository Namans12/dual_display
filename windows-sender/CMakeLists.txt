cmake_minimum_required(VERSION 3.20)
project(ExtendedDisplaySender LANGUAGES CXX)

add_executable(ExtendedDisplaySender
    src/main.cpp
)

target_compile_features(ExtendedDisplaySender PRIVATE cxx_std_20)

if (MSVC)
    target_compile_options(ExtendedDisplaySender PRIVATE /W4 /permissive-)
endif()
