cmake_minimum_required(VERSION 3.14 FATAL_ERROR)
project(cr2xt)

# cr2xt version
set(CR2XT_VERSION_MAJOR 0)
set(CR2XT_VERSION_MINOR 9)
set(CR2XT_VERSION_PATCH 2)
set(CR2XT_VERSION "${CR2XT_VERSION_MAJOR}.${CR2XT_VERSION_MINOR}.${CR2XT_VERSION_PATCH}")

# Get git version information (tag or short hash)
find_package(Git QUIET)
if(GIT_FOUND)
    # Try to get version from git describe (tags)
    execute_process(
        COMMAND ${GIT_EXECUTABLE} describe --tags --always
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        OUTPUT_VARIABLE CR2XT_GIT_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
        RESULT_VARIABLE GIT_DESCRIBE_RESULT
    )
    if(NOT GIT_DESCRIBE_RESULT EQUAL 0 OR CR2XT_GIT_VERSION STREQUAL "")
        # Fallback to short commit hash
        execute_process(
            COMMAND ${GIT_EXECUTABLE} rev-parse --short HEAD
            WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
            OUTPUT_VARIABLE CR2XT_GIT_VERSION
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
            RESULT_VARIABLE GIT_HASH_RESULT
        )
        if(NOT GIT_HASH_RESULT EQUAL 0)
            set(CR2XT_GIT_VERSION "")
        endif()
    endif()
else()
    set(CR2XT_GIT_VERSION "")
endif()

# Build full version string
if(CR2XT_GIT_VERSION)
    set(CR2XT_VERSION_FULL "${CR2XT_VERSION} (${CR2XT_GIT_VERSION})")
else()
    set(CR2XT_VERSION_FULL "${CR2XT_VERSION}")
endif()

message(STATUS "cr2xt version: ${CR2XT_VERSION_FULL}")

# Shared options - these propagate to subdirectories
set(USE_QT QT6 CACHE STRING "Qt version to use")
set_property(CACHE USE_QT PROPERTY STRINGS QT5 QT6)

option(STATIC_CRENGINE_NG "Link with the static version of crengine-ng" OFF)

# crengine-ng specific options for cr2xt converter
set(USE_COLOR_BACKBUFFER OFF CACHE BOOL "Use color backbuffer")
set(GRAY_BACKBUFFER_BITS 2 CACHE STRING "Gray depth for gray backbuffer")

# Platform detection - set MACOS for Apple platforms
if(APPLE)
    set(MACOS TRUE)

    # Universal Binary support for macOS
    # Set CMAKE_OSX_ARCHITECTURES to "arm64;x86_64" for Universal builds
    # Note: This must be set BEFORE add_subdirectory() calls
    # If not set, defaults to native architecture
    if(NOT DEFINED CMAKE_OSX_ARCHITECTURES OR CMAKE_OSX_ARCHITECTURES STREQUAL "")
        # Default to native architecture if not specified
        execute_process(
            COMMAND uname -m
            OUTPUT_VARIABLE NATIVE_ARCH
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        set(CMAKE_OSX_ARCHITECTURES "${NATIVE_ARCH}" CACHE STRING "Target macOS architectures")
    endif()

    # Log the target architectures
    list(LENGTH CMAKE_OSX_ARCHITECTURES ARCH_COUNT)
    if(ARCH_COUNT GREATER 1)
        message(STATUS "Building Universal Binary for architectures: ${CMAKE_OSX_ARCHITECTURES}")
    else()
        message(STATUS "Building for architecture: ${CMAKE_OSX_ARCHITECTURES}")
    endif()
endif()

# Build crengine-ng first (the dependency)
add_subdirectory(crengine-ng)

# Create namespaced aliases that crqt-ng expects (matching find_package exports)
# These need PUBLIC include directories for the umbrella build to work
if(TARGET crengine-ng)
    # Get the source and binary include directories
    set(CRENGINE_NG_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/crengine-ng/crengine/include")
    set(CRENGINE_NG_BINARY_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/crengine-ng/crengine")

    # Add PUBLIC include directories to the existing targets
    # Include both source dir (headers) and binary dir (generated crengine-ng-config.h)
    target_include_directories(crengine-ng PUBLIC
        $<BUILD_INTERFACE:${CRENGINE_NG_INCLUDE_DIR}>
        $<BUILD_INTERFACE:${CRENGINE_NG_BINARY_INCLUDE_DIR}>
    )

    # Create namespaced alias
    add_library(crengine-ng::crengine-ng ALIAS crengine-ng)
endif()

if(TARGET crengine-ng_static)
    target_include_directories(crengine-ng_static PUBLIC
        $<BUILD_INTERFACE:${CRENGINE_NG_INCLUDE_DIR}>
        $<BUILD_INTERFACE:${CRENGINE_NG_BINARY_INCLUDE_DIR}>
    )
    add_library(crengine-ng::crengine-ng_static ALIAS crengine-ng_static)
endif()

# Set data directory for umbrella build
set(CRENGINE_NG_DATA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/crengine-ng/crengine/data")

# Pass cr2xt version to crqt-ng (will be empty if built standalone)
set(CR2XT_VERSION_FULL "${CR2XT_VERSION_FULL}" CACHE STRING "cr2xt umbrella project version" FORCE)
set(CR2XT_VERSION "${CR2XT_VERSION}" CACHE STRING "cr2xt version (without git hash)" FORCE)

# Build crqt-ng (depends on crengine-ng)
add_subdirectory(crqt-ng)

# Install cr2xt distribution defaults file
# On Windows: exe directory (portable)
# On macOS: Resources bundle
# On Linux: engine data directory (matches CRE_NG_DATADIR for system installs)
if(WIN32)
    install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/scripts/crui-defaults.ini DESTINATION .)
elseif(MACOS)
    install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/scripts/crui-defaults.ini DESTINATION Contents/Resources)
else()
    install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/scripts/crui-defaults.ini DESTINATION share/crengine-ng)
endif()
