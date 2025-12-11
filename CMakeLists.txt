cmake_minimum_required(VERSION 3.14 FATAL_ERROR)
project(cr2xt)

# Shared options - these propagate to subdirectories
set(USE_QT QT6 CACHE STRING "Qt version to use")
set_property(CACHE USE_QT PROPERTY STRINGS QT5 QT6)

option(STATIC_CRENGINE_NG "Link with the static version of crengine-ng" OFF)

# Build crengine-ng first (the dependency)
add_subdirectory(crengine-ng)

# Create namespaced aliases that crqt-ng expects (matching find_package exports)
# These need PUBLIC include directories for the umbrella build to work
if(TARGET crengine-ng)
    # Get the source include directory
    set(CRENGINE_NG_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/crengine-ng/crengine/include")

    # Add PUBLIC include directories to the existing targets
    target_include_directories(crengine-ng PUBLIC
        $<BUILD_INTERFACE:${CRENGINE_NG_INCLUDE_DIR}>
    )

    # Create namespaced alias
    add_library(crengine-ng::crengine-ng ALIAS crengine-ng)
endif()

if(TARGET crengine-ng_static)
    target_include_directories(crengine-ng_static PUBLIC
        $<BUILD_INTERFACE:${CRENGINE_NG_INCLUDE_DIR}>
    )
    add_library(crengine-ng::crengine-ng_static ALIAS crengine-ng_static)
endif()

# Set data directory for umbrella build
set(CRENGINE_NG_DATA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/crengine-ng/crengine/data")

# Build crqt-ng (depends on crengine-ng)
add_subdirectory(crqt-ng)