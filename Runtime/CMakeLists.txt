cmake_minimum_required(VERSION 3.24)
project(CaptionLocalTranslation VERSION 1.0 LANGUAGES C CXX)

if(NOT LC_LLAMA_SOURCE)
    message(FATAL_ERROR "LC_LLAMA_SOURCE must name the pinned local llama.cpp source")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Static local inference dependencies" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "No common/network utilities" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "No upstream test tools" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "No upstream examples" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "No upstream tools" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "No server" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "No upstream app" FORCE)
set(GGML_METAL ON CACHE BOOL "Apple Metal inference" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "No external backend plugins" FORCE)
set(GGML_RPC OFF CACHE BOOL "No remote inference backend" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "Portable embedded Metal kernels" FORCE)
set(GGML_ACCELERATE ON CACHE BOOL "Apple Accelerate" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "Portable Apple Silicon CPU code" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "No external OpenMP runtime" FORCE)
add_subdirectory("${LC_LLAMA_SOURCE}" "${CMAKE_BINARY_DIR}/llama")

add_library(caption_local_translation SHARED local_translation.cpp)
target_link_libraries(caption_local_translation PRIVATE llama)
target_compile_definitions(caption_local_translation PRIVATE
    LC_LLAMA_PIN="7fe450e19305b828c199d602c23a8337aaa1f03b")
set_target_properties(caption_local_translation PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${LC_OUTPUT_DIRECTORY}"
    MACOSX_RPATH ON
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path")
target_link_options(caption_local_translation PRIVATE
    "LINKER:-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exported-symbols.txt")

add_executable(caption-local-benchmark benchmark.cpp)
target_link_libraries(caption-local-benchmark PRIVATE caption_local_translation)
set_target_properties(caption-local-benchmark PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${LC_OUTPUT_DIRECTORY}"
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path")
