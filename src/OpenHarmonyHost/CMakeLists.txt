cmake_minimum_required(VERSION 3.4.1)
project(openharmonyhost)

set(CMAKE_CXX_STANDARD 17)

add_library(openharmonyhost SHARED host_napi.cpp openharmony_host.c host_optional.c)

target_include_directories(openharmonyhost PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# Keep this list aligned with src/OpenHarmonyHost/host-deps.conf [needed]: every other
# system library is resolved at runtime by host_optional.c (dlopen/dlsym).
target_link_libraries(openharmonyhost PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    libnative_drawing.so)
