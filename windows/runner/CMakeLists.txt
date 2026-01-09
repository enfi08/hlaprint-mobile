cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Opsi tambahan agar warning lebih terlihat (opsional, dari file full)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /W3")

# Define the application target.
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

# Link library standar Flutter dan Windows
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# ==============================================================================
# ### TAMBAHAN DARI VERSI LENGKAP (Poppler, Cairo, Glib) ###
# ==============================================================================

# PENTING: Pastikan path ini sesuai dengan lokasi vcpkg di komputer Anda saat ini.
# Jika Anda pindah komputer atau user, path "C:/Users/Dimas/..." harus diganti.
set(VCPKG_INSTALLED_DIR "C:/Users/Dimas/vcpkg/installed/x64-windows")

# 1. Include Directories (Supaya #include <poppler.h> di main.cpp terbaca)
target_include_directories(${BINARY_NAME} PRIVATE
        ${VCPKG_INSTALLED_DIR}/include
        ${VCPKG_INSTALLED_DIR}/include/poppler
        ${VCPKG_INSTALLED_DIR}/include/poppler/cpp
        ${VCPKG_INSTALLED_DIR}/include/poppler/glib
        ${VCPKG_INSTALLED_DIR}/include/glib-2.0
        ${VCPKG_INSTALLED_DIR}/lib/glib-2.0/include
        ${VCPKG_INSTALLED_DIR}/include/cairo
)

# 2. Link Directories (Supaya linker tahu di mana mencari .lib)
target_link_directories(${BINARY_NAME} PRIVATE
        ${VCPKG_INSTALLED_DIR}/lib
)

# 3. Link Libraries (Supaya fungsi-fungsi Poppler/Cairo bisa dipanggil)
target_link_libraries(${BINARY_NAME} PRIVATE
        poppler
        poppler-cpp
        glib-2.0
        poppler-glib
        cairo
        gobject-2.0
        intl
)

# Opsional: Logika find_path/library dari file full (bisa dibiarkan jika path di atas sudah benar)
# Namun saya sarankan pakai hardcode di atas dulu agar pasti ter-link.

# ==============================================================================
# ### AKHIR TAMBAHAN ###
# ==============================================================================

# Run the Flutter tool portions of the build.
add_dependencies(${BINARY_NAME} flutter_assemble)