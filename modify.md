# Go2W 雷达高程图话题配置修改记录

## 目标

让 MuJoCo 中的 Go2W 通过雷达高度扫描产生 ROS2 高程图话题数据：

```text
go2w radar raycaster -> /height_scan (sensor_msgs/PointCloud2) -> /elevation_map (grid_map_msgs/GridMap)
```

## 参考依据

参考了 `simulate/raycaster/readme.md` 中的 raycaster 插件说明。

本次选择 `mujoco.sensor.ray_caster`，没有选择 `mujoco.sensor.ray_caster_lidar`。原因是训练环境使用的是 Isaac Lab `RayCasterCfg` 网格高度扫描：

```text
resolution = 0.1
size = 1.6 x 1.0
ray_alignment = yaw
```

这个语义更接近“机器人局部地形高度网格”，不是 360 度旋转式多线激光雷达。当前配置会形成 187 个采样点，即 `17 x 11`，并以世界坐标点云输出给 GridMap 转换器。

## 修改文件

### `unitree_robots/go2w/go2w.xml`

新增 raycaster 插件声明：

```xml
<extension>
  <plugin plugin="mujoco.sensor.ray_caster"/>
</extension>
```

在 `base_link` 下新增 `radar` camera，位置参考 Go2W 训练 URDF 中的 `radar_joint`：

```xml
<camera name="radar" pos="0.28945 0 -0.046825" quat="1 0 0 0" />
```

在 `<sensor>` 中新增 `height_scan` raycaster 传感器：

```xml
<plugin name="height_scan" plugin="mujoco.sensor.ray_caster" objtype="camera" objname="radar">
  <config key="resolution" value="0.1"/>
  <config key="size" value="1.6 1.0"/>
  <config key="dis_range" value="0.05 5.0"/>
  <config key="type" value="yaw"/>
  <config key="sensor_data_types" value="pos_w"/>
  <config key="geomgroup" value="1 0 0 0 0 0"/>
  <config key="n_step_update" value="1"/>
  <config key="num_thread" value="4"/>
</plugin>
<framepos name="radar_pos" objtype="camera" objname="radar"/>
<framequat name="radar_quat" objtype="camera" objname="radar"/>
```

关键说明：

- `type="yaw"` 让扫描网格跟随机器人 yaw，贴近训练中的 `ray_alignment="yaw"`。
- `sensor_data_types="pos_w"` 输出世界坐标 hit points，现有 `GridMapPublisher` 可以直接按 `x/y/z` 生成 `/elevation_map`。
- `geomgroup="1 0 0 0 0 0"` 只检测环境几何体所在的 group 0，避免扫描到机器人自身碰撞体。

### `simulate/config.yaml`

默认机器人切换为 Go2W：

```yaml
robot: "go2w"
```

启用 raycaster 和 GridMap 发布器：

```yaml
enable_ray_array: true
enable_gridmap: true
```

配置 `height_scan` 为 PointCloud2 输出，因为 `GridMapPublisher` 的输入固定是 `/height_scan` 点云：

```yaml
raycaster_output_format: "pointcloud"

raycaster_sensors:
  height_scan:
    output_format: "pointcloud"
    flatten_xyz: false
    zero_mean: false
    replace_nan: "zero"
    distance_type: ""
```

关闭深度图可视化。本次只配置高度扫描，没有添加深度相机 image 输出：

```yaml
enable_depth_visualizer: false
```

发布频率设为 50 Hz，用于贴近训练 policy step rate：

```yaml
publisher_frequency: 50.0
```

训练侧对应关系是 `sim.dt=0.005`、`decimation=4`，即 policy step 为 `0.02s`。

## 预期 ROS2 话题

使用 `ENABLE_ROS2=ON` 编译并运行仿真后，预期出现：

```text
/height_scan     sensor_msgs/msg/PointCloud2
/elevation_map   grid_map_msgs/msg/GridMap
/tf              tf2_msgs/msg/TFMessage
```

## 编译与验证命令

```bash
cd /home/applepie/project_for_test/unitree_mujoco/simulate/build
source /opt/ros/jazzy/setup.zsh
cmake -DENABLE_ROS2=ON ..
make -j$(nproc)
export LD_LIBRARY_PATH="/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/lib:$LD_LIBRARY_PATH"
./unitree_mujoco
```

另开终端检查话题：

```bash
source /opt/ros/jazzy/setup.zsh
ros2 topic list
ros2 topic hz /height_scan
ros2 topic hz /elevation_map
ros2 topic echo /elevation_map --once
```

## 部署注意事项

`/elevation_map` 是 ROS2 高程图话题，但它还不是训练 actor 直接使用的 187 维 `height_scan` 观测。若要直接部署训练策略，还需要增加一步转换：

```text
/elevation_map -> robot/radar-local 17x11 heightmap -> actor observation tail
```

该转换必须保持训练时的观测顺序、坐标系、裁剪和缩放逻辑。

## 2026-04-25 GridMap Python 版本修正

问题现象：

```text
ros2 topic hz /elevation_map
ImportError: libpython3.13.so.1.0: cannot open shared object file
rosidl_generator_py.import_type_support_impl.UnsupportedTypeSupport
```

原因：

`third_party/grid_map_install` 之前由 Conda 的 Python 3.13 构建，生成的 `grid_map_msgs` Python type support 位于：

```text
third_party/grid_map_install/lib/python3.13/site-packages
```

但 ROS Jazzy 的 `ros2` 命令使用系统 Python 3.12，因此订阅 `grid_map_msgs/msg/GridMap` 时会出现 Python ABI 不匹配。

处理：

使用系统 `/usr/bin/python3` 重新构建并安装最小 GridMap 依赖：

```bash
source /opt/ros/jazzy/setup.zsh

PREFIX=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install
SRC=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map

cmake -S "$SRC/grid_map_cmake_helpers" -B "$PREFIX/build_grid_map_cmake_helpers_py312" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DPython3_EXECUTABLE=/usr/bin/python3 \
  -DBUILD_TESTING=OFF
cmake --build "$PREFIX/build_grid_map_cmake_helpers_py312" --target install -j$(nproc)

cmake -S "$SRC/grid_map_msgs" -B "$PREFIX/build_grid_map_msgs_py312" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DPython3_EXECUTABLE=/usr/bin/python3 \
  -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.12.so \
  -DPython3_INCLUDE_DIR=/usr/include/python3.12 \
  -DBUILD_TESTING=OFF
cmake --build "$PREFIX/build_grid_map_msgs_py312" --target install -j$(nproc)

cmake -S "$SRC/grid_map_core" -B "$PREFIX/build_grid_map_core_py312" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DPython3_EXECUTABLE=/usr/bin/python3 \
  -DBUILD_TESTING=OFF
cmake --build "$PREFIX/build_grid_map_core_py312" --target install -j$(nproc)
```

修正后 `grid_map_msgs` 的环境 hook 指向：

```text
third_party/grid_map_install/lib/python3.12/site-packages
```

验证：

```bash
source /opt/ros/jazzy/setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_msgs/local_setup.zsh
export LD_LIBRARY_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/lib:$LD_LIBRARY_PATH

ros2 interface show grid_map_msgs/msg/GridMap
```

验证结果：`GridMap` Python type support 可正常导入，`unitree_mujoco` 已重新编译通过。

## 2026-04-25 本地安装 GridMap RViz 插件

问题现象：

```text
RViz2 -> Add 中找不到 grid_map_rviz_plugin/GridMap
sudo apt install ros-jazzy-grid-map-rviz-plugin
E: Unable to locate package
```

原因：

当前系统 apt 源没有配置 ROS2 Jazzy 软件源，且当前会话没有免密码 sudo，无法直接通过 apt 安装二进制包。仓库中已有 `third_party/grid_map/grid_map_rviz_plugin` 源码，但原版插件依赖 `grid_map_ros`，进一步需要 `grid_map_cv`、`filters`、`nav2_msgs` 等未安装依赖。

处理：

为避免系统级安装依赖，已将本地 `grid_map_rviz_plugin` 调整为直接解析 `grid_map_msgs/msg/GridMap`，去掉 `grid_map_ros` 依赖，仅依赖已有的 `grid_map_msgs`、`grid_map_core`、RViz 和 Qt。

本地编译安装命令：

```bash
PREFIX=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install
SRC=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map

source /opt/ros/jazzy/setup.zsh
source "$PREFIX/share/grid_map_msgs/local_setup.zsh"
source "$PREFIX/share/grid_map_core/local_setup.zsh"
export LD_LIBRARY_PATH="$PREFIX/lib:$LD_LIBRARY_PATH"
export CMAKE_PREFIX_PATH="$PREFIX:$CMAKE_PREFIX_PATH"

cmake -S "$SRC/grid_map_rviz_plugin" -B "$PREFIX/build_grid_map_rviz_plugin_py312" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DPython3_EXECUTABLE=/usr/bin/python3 \
  -DBUILD_TESTING=OFF
cmake --build "$PREFIX/build_grid_map_rviz_plugin_py312" --target install -j$(nproc)
```

验证：

```bash
source /opt/ros/jazzy/setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_msgs/local_setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_core/local_setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_rviz_plugin/local_setup.zsh
export LD_LIBRARY_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/lib:$LD_LIBRARY_PATH

ros2 pkg prefix grid_map_rviz_plugin
```

验证结果：

```text
/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install
```

插件描述已注册到：

```text
third_party/grid_map_install/share/ament_index/resource_index/rviz_common__pluginlib__plugin/grid_map_rviz_plugin
```

RViz2 中使用：

```text
Add -> grid_map_rviz_plugin/GridMap
Topic -> /elevation_map
Height Layer -> elevation
Color Layer -> elevation
```

## 2026-04-26 修复稀疏 GridMap 在 RViz 中不显示

问题现象：

`/elevation_map` 已经以约 50 Hz 发布，RViz 中也能订阅 `grid_map_rviz_plugin/GridMap`，但平地或稀疏高度图看起来没有显示。

原因：

本地 `grid_map_rviz_plugin` 原始渲染逻辑按相邻网格角点生成三角面：一个小方块至少需要 3 个有效角点才会画出来。当前 Go2W raycaster 产生约 `17 x 11 = 187` 个有效高度采样点，GridMap 总尺寸为 `80 x 80`，其余大部分为 `NaN`。有效点在大网格里比较稀疏时，很多 cell 无法组成连续三角面，所以即使平地高度为 0，RViz 也可能看不到任何高程图。

处理：

已修改 `third_party/grid_map/grid_map_rviz_plugin/src/GridMapVisual.cpp`：

- 每个有效 `elevation` cell 独立绘制一个以 cell 中心为中心的小方块。
- 不再要求相邻 3 个或 4 个有效格子才能形成可见三角面。
- 修复 `minIntensity == maxIntensity` 时颜色归一化除零的问题，平地高度全为 0 时使用中间颜色值。

重新编译安装：

```bash
source /opt/ros/jazzy/setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_msgs/local_setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_core/local_setup.zsh
export LD_LIBRARY_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/lib:$LD_LIBRARY_PATH
export CMAKE_PREFIX_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install:$CMAKE_PREFIX_PATH

cmake -S /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map/grid_map_rviz_plugin \
  -B /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/build_grid_map_rviz_plugin_py312 \
  -DCMAKE_INSTALL_PREFIX=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install \
  -DPython3_EXECUTABLE=/usr/bin/python3 \
  -DBUILD_TESTING=OFF
cmake --build /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/build_grid_map_rviz_plugin_py312 --target install -j$(nproc)
```

验证：

`libgrid_map_rviz_plugin.so` 已重新安装，`ldd` 检查没有 `not found`。RViz2 需要关闭后重新按下面命令启动，才能加载新的插件动态库：

```bash
source /opt/ros/jazzy/setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_msgs/local_setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_core/local_setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_rviz_plugin/local_setup.zsh
export LD_LIBRARY_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/lib:$LD_LIBRARY_PATH
rviz2
```

## 2026-04-27 修复 Go2W StepIt 策略 ROS2 节点和高程图订阅

问题现象：

使用下面命令启动策略：

```bash
cd /home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws
./scripts/run.sh ./configs/go2w.sh -p /home/applepie/project_for_test/go2w_cusrl_demo/stepit/policy/go2w_policy_cusrl_with_sensor
```

将 `configs/go2w.sh` 改为 `-P ros2` 后，程序启动失败：

```text
Factory 'ros2' not found for type 'stepit::Publisher'. Registered factories are:
- priority 4: 'csv'
- priority 0: 'dummy'
```

原因：

当前 StepIt workspace 被 `run.sh` 识别为 `cmake` 构建，实际运行的是：

```text
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/install/bin/stepit
```

之前构建 `cmake` 版本时没有 source ROS2 环境，因此 `ros2_base` 插件没有被编译安装，`install/lib` 中缺少：

```text
libstepit_plugin_ros2_base.so
libstepit_plugin_ros2_base_entry.so
```

所以 `-P ros2` 会触发 publisher factory 查找失败。

同时，策略的高程图输入还存在两个配置问题：

- `policy/go2w_policy_cusrl_with_sensor/heightmap.yml` 没有显式指定 MuJoCo 发布的 `/elevation_map`。
- StepIt ROS2 高程图插件原始依赖 `grid_map_ros`，当前系统没有 `ros-jazzy-grid-map-ros`，而本地只安装了 `grid_map_msgs` 和 `grid_map_core`。

处理：

1. 修改 `/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/configs/go2w.sh`

新增 ROS2 和本地 GridMap 环境加载：

```bash
set +u
source /opt/ros/jazzy/setup.bash
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_msgs/local_setup.bash
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_core/local_setup.bash
set -u
export LD_LIBRARY_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/lib:${LD_LIBRARY_PATH:-}
```

将默认 publisher 从 `dummy` 改为 `ros2`：

```bash
STEPIT_ARGS="${STEPIT_ARGS:-} -r go2w -c console -c joystick -f joystick@usb -P ros2"
```

2. 修改 StepIt ROS2 高程图插件

修改文件：

```text
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/src/stepit/plugin/policy_neuro_ros2/CMakeLists.txt
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/src/stepit/plugin/policy_neuro_ros2/package.xml
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/src/stepit/plugin/policy_neuro_ros2/include/stepit/policy_neuro_ros2/heightmap_subscriber2.h
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/src/stepit/plugin/policy_neuro_ros2/src/heightmap_subscriber2.cpp
```

变更内容：

- 去掉 `grid_map_ros` 依赖。
- 改为依赖 `grid_map_core` 和 `grid_map_msgs`。
- 在 `heightmap_subscriber2.cpp` 中增加 `grid_map_msgs/msg/GridMap` 到 `grid_map::GridMap` 的本地转换函数。
- 用本地转换函数替代 `grid_map::GridMapRosConverter::fromMessage()`。

3. 修改策略高程图配置

修改文件：

```text
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/policy/go2w_policy_cusrl_with_sensor/heightmap.yml
```

新增配置：

```yaml
grid_map_subscriber:
  topic: "/elevation_map"
  qos:
    reliability: "best_effort"
    durability: "volatile"
    history: "keep_last"
  timeout_threshold: 0.5
  default_enabled: true

localization_subscriber:
  topic: "/odometry"
  topic_type: "nav_msgs/msg/Odometry"
  qos:
    reliability: "best_effort"
    durability: "volatile"
    history: "keep_last"
  timeout_threshold: 0.1

elevation_layer: "elevation"
uncertainty_layer: "uncertainty"
elevation_interpolation_method: "nearest"
uncertainty_interpolation_method: "nearest"
elevation_zero_mean: true
uncertainty_squared: false
uncertainty_scaling: 0.25
```

重新编译：

```bash
cd /home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws

source /opt/ros/jazzy/setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_msgs/local_setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_core/local_setup.zsh
export LD_LIBRARY_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/lib:${LD_LIBRARY_PATH:-}
export CMAKE_PREFIX_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install:${CMAKE_PREFIX_PATH:-}

./scripts/build.sh cmake --configure -j $(nproc) -DPython3_EXECUTABLE=/usr/bin/python3
```

构建注意：

必须显式指定：

```bash
-DPython3_EXECUTABLE=/usr/bin/python3
```

否则 CMake 可能选择 Conda Python，导致 ROS2 `rosidl_adapter` 报错：

```text
ModuleNotFoundError: No module named 'em'
```

验证结果：

安装目录已生成：

```text
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/install/lib/libstepit_plugin_ros2_base.so
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/install/lib/libstepit_plugin_ros2_base_entry.so
/home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws/install/lib/libstepit_plugin_policy_neuro_ros2.so
```

启动策略后，ROS2 图中可以看到：

```text
/stepit_ros2
```

并且 `/elevation_map` 已被策略订阅：

```bash
source /opt/ros/jazzy/setup.zsh
source /home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/share/grid_map_msgs/local_setup.zsh
export LD_LIBRARY_PATH=/home/applepie/project_for_test/unitree_mujoco/third_party/grid_map_install/lib:$LD_LIBRARY_PATH

ros2 topic info -v /elevation_map
```

结果：

```text
Type: grid_map_msgs/msg/GridMap
Publisher count: 1
Node name: raycaster_publisher

Subscription count: 1
Node name: stepit_ros2
```

结论：

现在使用原始启动命令即可创建策略 ROS2 节点，并订阅 MuJoCo 产生的 `/elevation_map`：

```bash
cd /home/applepie/project_for_test/go2w_cusrl_demo/stepit/stepit_ws
./scripts/run.sh ./configs/go2w.sh -p /home/applepie/project_for_test/go2w_cusrl_demo/stepit/policy/go2w_policy_cusrl_with_sensor
```

如果要重新build

```
source /opt/ros/jazzy/setup.zsh
  cmake -S . -B build -DENABLE_ROS2=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j$(nproc)
```

## 2026-06-02 MuJoCo 侧当前改动汇总

本节只记录 `unitree_mujoco` 侧改动，不包含 StepIt 策略目录中的配置修改。

### `unitree_robots/go2w/go2w.xml`

Go2W 机身 link 与 IsaacLab 训练配置对齐：

```xml
<body name="base" pos="0 0 0.45" childclass="go2">
```

说明：

- 训练侧 `base_link_name = "base"`，因此 MuJoCo body 使用 `base`。
- base 初始高度从 `0.6` 改为 `0.45`，与 MIRLab/IsaacLab 初始状态对齐。

雷达高度扫描挂载在 base 中心：

```xml
<camera name="radar" pos="0 0 0" quat="1 0 0 0" />
```

当前 raycaster 配置：

```xml
<plugin name="height_scan" plugin="mujoco.sensor.ray_caster" objtype="camera" objname="radar">
  <config key="resolution" value="0.1"/>
  <config key="size" value="1.0 1.6"/>
  <config key="dis_range" value="0.05 5.0"/>
  <config key="type" value="yaw"/>
  <config key="draw_hip_point" value="1 0.02 1 0 0 0.5"/>
  <config key="sensor_data_types" value="pos_w"/>
  <config key="geomgroup" value="1 0 0 0 0 0"/>
  <config key="n_step_update" value="1"/>
  <config key="num_thread" value="4"/>
</plugin>
```

说明：

- `resolution=0.1`，`size=1.0 1.6` 会产生 `11 x 17 = 187` 个采样点。
- `type="yaw"` 让扫描区域跟随机器人 yaw。
- `geomgroup="1 0 0 0 0 0"` 只检测 group 0。
- 轮子 visual mesh 增加 `class="visual"`，避免高程射线打到机器人自身视觉几何体。

轮子力矩上限与训练侧 actuator 对齐：

```xml
<motor ctrlrange="-23.5 23.5" name="FR_wheel" joint="FR_wheel_joint" />
<motor ctrlrange="-23.5 23.5" name="FL_wheel" joint="FL_wheel_joint" />
<motor ctrlrange="-23.5 23.5" name="RR_wheel" joint="RR_wheel_joint" />
<motor ctrlrange="-23.5 23.5" name="RL_wheel" joint="RL_wheel_joint" />
```

关节 dry friction 从 `0.2` 降低到接近训练配置的 `0.01`：

```xml
<joint axis="0 1 0" damping="0.1" armature="0.01" frictionloss="0.01" />
```

新增训练初始姿态 keyframe：

```xml
<keyframe>
  <key name="isaaclab_default"
    qpos="0 0 0.45 1 0 0 0 0 0.8 -1.5 0 0 0.8 -1.5 0 0 0.8 -1.5 0 0 0.8 -1.5 0"
    qvel="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"/>
</keyframe>
```

注意：

- MuJoCo `qpos` 顺序是 XML 树顺序：`FL, FR, RL, RR`，不是 SDK/policy 的 `FR, FL, RR, RL`。
- keyframe 设置 base z 为 `0.45`，四条腿 thigh 为 `0.8`，calf 为 `-1.5`，hip/wheel 和所有速度为 `0`。

### `simulate/src/main.cc`

新增 reset helper：

```cpp
void ResetDataToTrainingInitialState(const mjModel *model, mjData *data)
```

行为：

- 如果模型中存在 `isaaclab_default` keyframe，则使用 `mj_resetDataKeyframe`。
- 如果不存在该 keyframe，则回退到原始 `mj_resetData`。

已接入的位置：

- 启动加载模型后。
- GUI/拖拽重新加载模型后。
- 按 Backspace reset 时。

这样启动和手动 reset 都会回到训练初始姿态。

同时，SDK bridge 的 elastic band 挂载 body 查找逻辑兼容 `base_link` 和 `base`：

```cpp
body_id = mj_name2id(m, mjOBJ_BODY, "base_link");
if (body_id < 0) {
  body_id = mj_name2id(m, mjOBJ_BODY, "base");
}
```

### `unitree_robots/go2w/scene.xml`

楼梯地形改为等间距上楼梯、最高平台、连续下楼梯：

```text
stair_up_01   x=[2.15, 2.45] top_z=0.15
stair_up_02   x=[2.45, 2.75] top_z=0.30
stair_up_03   x=[2.75, 3.05] top_z=0.45
stair_up_04   x=[3.05, 3.35] top_z=0.60
stair_up_05   x=[3.35, 3.65] top_z=0.75
stair_up_06   x=[3.65, 4.85] top_z=0.90
stair_down_01 x=[4.85, 5.15] top_z=0.75
stair_down_02 x=[5.15, 5.45] top_z=0.60
stair_down_03 x=[5.45, 5.75] top_z=0.45
stair_down_04 x=[5.75, 6.05] top_z=0.30
stair_down_05 x=[6.05, 6.35] top_z=0.15
```

最高层平台宽度：

```text
x=[3.65, 4.85], full_x=1.20m, top_z=0.90m
```

该平台用于给机器狗到达最高台阶后留出站立空间，再进入下楼梯段。

### `simulate/src/gridmap_publisher.h`

GridMap 世界坐标范围扩展到覆盖后半段楼梯：

```cpp
node_->declare_parameter("gridmap.min_x", -4.0);
node_->declare_parameter("gridmap.max_x", 8.0);
```

原因：

- 当前楼梯 x 范围为 `[2.15, 6.35]`。
- 原始 `gridmap.max_x=4.0` 会导致最高平台后半段和下楼梯段被 `/elevation_map` 过滤。
- 扩展到 `8.0` 后，楼梯末端还有约 `1.65m` 余量。

### 验证结果

MuJoCo XML 解析验证：

```text
qpos0_base_z 0.450
keyframe_base_z 0.450
FL_thigh_joint 0.800
FR_thigh_joint 0.800
RL_thigh_joint 0.800
RR_thigh_joint 0.800
FL_calf_joint -1.500
FR_calf_joint -1.500
RL_calf_joint -1.500
RR_calf_joint -1.500
```

frictionloss 解析验证：

```text
FR_hip_joint frictionloss= 0.010
FR_thigh_joint frictionloss= 0.010
FR_calf_joint frictionloss= 0.010
FR_wheel_joint frictionloss= 0.010
```

重新编译验证：

```bash
cd /home/applepie/project_for_test/unitree_mujoco/simulate/build
cmake --build .
```

结果：

```text
[85%] Built target unitree_mujoco
[100%] Built target jstest
```
