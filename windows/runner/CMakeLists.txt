cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /W3")

add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

apply_standard_settings(${BINARY_NAME})

target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# ------------------------------
# Poppler (manual integration)
# ------------------------------
# Ganti path di bawah sesuai lokasi vcpkg-mu
set(VCPKG_INSTALLED_DIR "C:/Users/Dimas/vcpkg/installed/x64-windows")

target_include_directories(${BINARY_NAME} PRIVATE
    ${VCPKG_INSTALLED_DIR}/include
    ${VCPKG_INSTALLED_DIR}/include/poppler
    ${VCPKG_INSTALLED_DIR}/include/poppler/cpp
    ${VCPKG_INSTALLED_DIR}/include/poppler/glib
    ${VCPKG_INSTALLED_DIR}/include/glib-2.0
    ${VCPKG_INSTALLED_DIR}/lib/glib-2.0/include
)

target_link_directories(${BINARY_NAME} PRIVATE
    ${VCPKG_INSTALLED_DIR}/lib
)

target_link_libraries(${BINARY_NAME} PRIVATE
    poppler
    poppler-cpp
)

# ---- Cairo ----
target_include_directories(${BINARY_NAME} PRIVATE
    ${VCPKG_INSTALLED_DIR}/include/cairo
)

target_link_libraries(${BINARY_NAME} PRIVATE
    glib-2.0
    poppler-glib
    cairo
    gobject-2.0
    intl
)



find_path(POPLER_INCLUDE_DIR
    NAMES poppler-version.h
    PATHS "${VCPKG_INSTALLED_DIR}/include"
)

find_library(POPLER_LIBRARY
    NAMES poppler
    PATHS "${VCPKG_INSTALLED_DIR}/lib"
)

find_library(POPLER_CPP_LIBRARY
    NAMES poppler-cpp
    PATHS "${VCPKG_INSTALLED_DIR}/lib"
)

if(POPLER_INCLUDE_DIR AND POPLER_LIBRARY)
    target_include_directories(${BINARY_NAME} PRIVATE ${POPLER_INCLUDE_DIR})
    target_link_libraries(${BINARY_NAME} PRIVATE ${POPLER_LIBRARY})
endif()

if(POPLER_CPP_LIBRARY)
    target_link_libraries(${BINARY_NAME} PRIVATE ${POPLER_CPP_LIBRARY})
endif()
# ------------------------------

add_dependencies(${BINARY_NAME} flutter_assemble)
