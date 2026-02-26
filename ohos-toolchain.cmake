set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_BYTE_ORDER LITTLE_ENDIAN)
set(CMAKE_C_COMPILER_FORCED TRUE)
set(CMAKE_CXX_COMPILER_FORCED TRUE)

# Set OHOS_SDK_NATIVE to your OpenHarmony SDK native directory, e.g.:
#   export OHOS_SDK_NATIVE=/path/to/OpenHarmony/Sdk/12/native
if(DEFINED ENV{OHOS_SDK_NATIVE})
  set(OHOS_SYSROOT "$ENV{OHOS_SDK_NATIVE}/sysroot")
else()
  message(FATAL_ERROR "OHOS_SDK_NATIVE environment variable is not set. "
    "Set it to the OpenHarmony SDK native directory, e.g.:\n"
    "  export OHOS_SDK_NATIVE=/path/to/OpenHarmony/Sdk/12/native")
endif()

set(CMAKE_C_FLAGS "--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -fPIC" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS "--target=aarch64-linux-ohos --sysroot=${OHOS_SYSROOT} -fuse-ld=lld -fPIC" CACHE STRING "" FORCE)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
