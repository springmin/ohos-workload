cmake_minimum_required(VERSION 3.4.1)
project(openharmonyhost)

set(CMAKE_CXX_STANDARD 17)

add_library(openharmonyhost SHARED host_napi.cpp openharmony_host.c)

target_include_directories(openharmonyhost PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(openharmonyhost PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so)
