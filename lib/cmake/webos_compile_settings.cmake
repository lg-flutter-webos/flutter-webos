# Copyright (c) 2026 LG Electronics, Inc. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Shipped by flutter-webos NativeBundle. Do not edit.
#
# Provides:
#   - SYSTEM include paths for cross-compile (e.g. libstdc++ headers).
#     Consumes FLUTTER_SYSTEM_INCLUDE_DIRECTORIES passed via -D from
#     flutter-webos. include_directories() is directory-scoped so this
#     file must be included before add_subdirectory() of subprojects.
#   - APPLY_STANDARD_SETTINGS(TARGET) function applied to the user binary.

include_directories(SYSTEM ${FLUTTER_SYSTEM_INCLUDE_DIRECTORIES})

function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)

  # Suppress unused-command-line-argument warning for Release/Profile builds
  # (prevents conflict between toolchain's -feliminate-unused-debug-types and our -g0)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-Wno-unused-command-line-argument>")

  # Debug: full debug symbols, no optimization
  target_compile_options(${TARGET} PRIVATE "$<$<CONFIG:Debug>:-g;-O0>")

  # Release: no debug symbols, maximum optimization
  target_compile_options(${TARGET} PRIVATE "$<$<CONFIG:Release>:-g0;-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Release>:NDEBUG>")

  # Profile: minimal debug symbols, maximum optimization
  target_compile_options(${TARGET} PRIVATE "$<$<CONFIG:Profile>:-g1;-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Profile>:NDEBUG>")

  # Strip debug sections during linking for non-Debug builds
  target_link_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-Wl,--strip-debug>")
endfunction()
