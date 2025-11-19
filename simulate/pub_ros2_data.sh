#!/bin/zsh

source /opt/ros/humble/setup.zsh

DEFAULT_TOPIC="/height_scan_uncertainty_array"
DEFAULT_MSG_TYPE="std_msgs/msg/Float32MultiArray"
DEFAULT_COUNT=221
DEFAULT_VALUE=0.03
DEFAULT_RATE=50

COUNT=${1:-$DEFAULT_COUNT}
VALUE=${2:-$DEFAULT_VALUE}
TOPIC=${3:-$DEFAULT_TOPIC}
RATE=${4:-$DEFAULT_RATE}

DATA_ARRAY_STR=$(python3 -c "print(','.join(['$VALUE'] * $COUNT))")

if [ $? -ne 0 ]; then
    echo "Error: Python command failed. Could not generate data array."
    echo "Usage: $0 [count] [value] [topic] [rate]"
    exit 1
fi

MSG_DATA="{data: [$DATA_ARRAY_STR]}"

echo "Topic:   $TOPIC"
echo "Count:   $COUNT"
echo "Value:   $VALUE"
echo "Rate:    $RATE"
echo "Message: $MSG_DATA"
echo "---"

ros2 topic pub $TOPIC $DEFAULT_MSG_TYPE "$MSG_DATA" -r $RATE > /dev/null
