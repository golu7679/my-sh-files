#!/bin/bash

echo "Fetching connected devices info..."

# Get list of connected device serial numbers
device_list=$(adb devices | grep -w "device" | cut -f1)

if [ -z "$device_list" ]; then
  echo "No devices connected."
  exit 1
fi

# Build a list of device details
device_options=()
device_serials=()

index=1
for serial in $device_list; do
  model=$(adb -s "$serial" shell getprop ro.product.model | tr -d '\r')
  name=$(adb -s "$serial" shell getprop ro.product.name | tr -d '\r')
  manufacturer=$(adb -s "$serial" shell getprop ro.product.manufacturer | tr -d '\r')
  device_string="$manufacturer $model ($name) - [$serial]"
  device_options+=("$device_string")
  device_serials+=("$serial")
  echo "$index) $device_string"
  ((index++))
done

# Ask for multiple device selection
echo ""
echo "Enter the numbers of the devices to reverse ports (e.g. 1 2 3):"
read -r -a selections

for num in "${selections[@]}"; do
  if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#device_serials[@]} )); then
    index=$((num - 1))
    selected_serial="${device_serials[$index]}"
    selected_device="${device_options[$index]}"

    echo ""
    echo "You selected: $selected_device"
    echo "Reversing ports on $selected_serial..."

    adb -s "$selected_serial" reverse tcp:8000 tcp:8000
    adb -s "$selected_serial" reverse tcp:8081 tcp:8081

    echo "Reverse TCP done for $selected_serial"
  else
    echo "Invalid selection: $num"
  fi
done
