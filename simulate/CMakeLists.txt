cmake_minimum_required(VERSION 3.16)
project(unitree_mujoco)

# Option to enable ROS2 support (includes raycaster and gridmap)
option(ENABLE_ROS2 "Enable ROS2 support (raycaster + gridmap)" OFF)

set(LOCAL_GRID_MAP_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/grid_map_install")
if(EXISTS "${LOCAL_GRID_MAP_PREFIX}/share/grid_map_msgs/cmake/grid_map_msgsConfig.cmake")
  list(PREPEND CMAKE_PREFIX_PATH "${LOCAL_GRID_MAP_PREFIX}")
  message(STATUS "Using local grid_map prefix: ${LOCAL_GRID_MAP_PREFIX}")
endif()

if (CMAKE_BUILD_TYPE MATCHES "Debug")
  message("Debug mode")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17 -g -O0 -fPIC")
else()
  message("Release mode")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17 -O3 -DNDEBUG -fPIC")
endif()

list(APPEND CMAKE_PREFIX_PATH "/opt/unitree_robotics/lib/cmake")
find_package(unitree_sdk2 REQUIRED)
find_package(Boost REQUIRED COMPONENTS program_options)
find_package(Eigen3 REQUIRED)
unset(fmt_DIR CACHE)
if(EXISTS "/usr/lib/x86_64-linux-gnu/cmake/fmt/fmt-config.cmake")
  find_package(fmt REQUIRED CONFIG
    PATHS "/usr/lib/x86_64-linux-gnu/cmake/fmt"
    NO_DEFAULT_PATH
  )
else()
  find_package(fmt REQUIRED)
endif()

set(MUJOCO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/mujoco" CACHE PATH "Path to the MuJoCo distribution")
if(NOT EXISTS "${MUJOCO_ROOT}/include/mujoco/mujoco.h")
  if(EXISTS "$ENV{HOME}/.mujoco/mujoco-3.3.6/include/mujoco/mujoco.h")
    set(MUJOCO_ROOT "$ENV{HOME}/.mujoco/mujoco-3.3.6")
  else()
    message(FATAL_ERROR "MuJoCo not found. Set MUJOCO_ROOT to a valid MuJoCo distribution.")
  endif()
endif()

set(MUJOCO_INCLUDE_DIR "${MUJOCO_ROOT}/include")
set(MUJOCO_SIMULATE_DIR "${MUJOCO_ROOT}/simulate")
find_library(MUJOCO_LIBRARY mujoco PATHS "${MUJOCO_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)

# Find ROS2 if enabled
if(ENABLE_ROS2)
  find_package(ament_cmake REQUIRED)
  find_package(rclcpp REQUIRED)
  find_package(sensor_msgs REQUIRED)
  find_package(std_msgs REQUIRED)
  find_package(geometry_msgs REQUIRED)
  find_package(tf2_ros REQUIRED)
  find_package(PCL REQUIRED COMPONENTS common)
  find_package(pcl_conversions REQUIRED)
  message(STATUS "ROS2 support enabled (raycaster + gridmap)")
  add_definitions(-DENABLE_ROS2)
endif()


include_directories(
  ${MUJOCO_INCLUDE_DIR}
  ${MUJOCO_SIMULATE_DIR}
  src/lodepng
  raycaster/src
  raycaster/plugin
  src
)

file(GLOB SIM_SRC
  src/joystick/joystick.cc

  # exclude mujoco/simulate/main.cc
  ${MUJOCO_SIMULATE_DIR}/glfw_*.cc
  ${MUJOCO_SIMULATE_DIR}/platform_*.cc
  ${MUJOCO_SIMULATE_DIR}/simulate.cc
  src/lodepng/lodepng.cpp
)

# Raycaster plugin source files
file(GLOB RAYCASTER_SRC raycaster/src/*.cpp raycaster/src/*.h raycaster/src/*.hpp)
file(GLOB RAYCASTER_PLUGIN_SRC raycaster/plugin/*.cc raycaster/plugin/*.h)

link_libraries(
  pthread
  ${MUJOCO_LIBRARY}
  glfw
  yaml-cpp
  unitree_sdk2
  boost_program_options
)

# Build raycaster plugin as shared library FIRST (before finding grid_map to avoid pollution)
add_library(sensor_ray SHARED ${RAYCASTER_PLUGIN_SRC} ${RAYCASTER_SRC})
target_include_directories(sensor_ray PRIVATE 
  ${CMAKE_CURRENT_SOURCE_DIR} 
  raycaster/src 
  raycaster/plugin 
  ${MUJOCO_INCLUDE_DIR}
)
target_link_libraries(sensor_ray PRIVATE ${MUJOCO_LIBRARY} Eigen3::Eigen)

# Copy plugin library to build directory for loading
add_custom_command(TARGET sensor_ray POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/mujoco_plugin"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:sensor_ray>"
        "${CMAKE_BINARY_DIR}/mujoco_plugin/"
    COMMENT "Copying sensor_ray plugin to mujoco_plugin directory..."
)

add_executable(unitree_mujoco ${SIM_SRC} src/main.cc)
target_link_libraries(unitree_mujoco sensor_ray fmt::fmt)

# Keep local ROS/grid_map runtime libraries discoverable without requiring
# users to manually export LD_LIBRARY_PATH before launching the simulator.
set(UNITREE_MUJOCO_RUNTIME_PATHS
  "${MUJOCO_ROOT}/lib"
  "${CMAKE_BINARY_DIR}"
  "/opt/ros/jazzy/lib"
  "${LOCAL_GRID_MAP_PREFIX}/lib"
  "/opt/unitree_robotics/lib"
)
set_target_properties(unitree_mujoco PROPERTIES
  BUILD_RPATH "${UNITREE_MUJOCO_RUNTIME_PATHS}"
  INSTALL_RPATH "${UNITREE_MUJOCO_RUNTIME_PATHS}"
)
# Use DT_RPATH instead of DT_RUNPATH so transitive dependencies from the local
# grid_map installation are also resolved from the embedded search paths.
target_link_options(unitree_mujoco PRIVATE "-Wl,--disable-new-dtags")

# Link ROS2 libraries if enabled
# IMPORTANT: grid_map packages must be found AFTER sensor_ray is defined
# to avoid polluting sensor_ray with EIGEN plugin definitions
if(ENABLE_ROS2)
  # Find grid_map packages here (after sensor_ray target is created)
  find_package(grid_map_msgs REQUIRED)
  find_package(grid_map_core REQUIRED)
  find_package(nav_msgs REQUIRED)
  find_package(fmt REQUIRED)
  find_package(CURL REQUIRED)
  
  # Remove global definitions added by grid_map_core
  remove_definitions(-DEIGEN_DENSEBASE_PLUGIN="grid_map_core/eigen_plugins/DenseBasePlugin.hpp")
  remove_definitions(-DEIGEN_FUNCTORS_PLUGIN="grid_map_core/eigen_plugins/FunctorsPlugin.hpp")
  
  # Add them only to unitree_mujoco target
  target_compile_definitions(unitree_mujoco PRIVATE
    EIGEN_DENSEBASE_PLUGIN="grid_map_core/eigen_plugins/DenseBasePlugin.hpp"
    EIGEN_FUNCTORS_PLUGIN="grid_map_core/eigen_plugins/FunctorsPlugin.hpp"
  )
  
  target_include_directories(unitree_mujoco PRIVATE 
    ${PCL_INCLUDE_DIRS}
    ${grid_map_core_INCLUDE_DIRS}
  )
  target_link_libraries(unitree_mujoco 
    ${PCL_LIBRARIES}
    fmt::fmt
    CURL::libcurl
  )
  ament_target_dependencies(unitree_mujoco
    rclcpp
    sensor_msgs
    std_msgs
    geometry_msgs
    tf2_ros
    grid_map_msgs
    grid_map_core
    pcl_conversions
    nav_msgs
  )
endif()

add_executable(jstest src/joystick/jstest.cc src/joystick/joystick.cc)
