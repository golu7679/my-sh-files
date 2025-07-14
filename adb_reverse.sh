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

for serial in $device_list; do
  model=$(adb -s "$serial" shell getprop ro.product.model | tr -d '\r')
  name=$(adb -s "$serial" shell getprop ro.product.name | tr -d '\r')
  manufacturer=$(adb -s "$serial" shell getprop ro.product.manufacturer | tr -d '\r')
  device_options+=("$manufacturer $model ($name) - [$serial]")
  device_serials+=("$serial")
done

# Display selection menu
echo ""
echo "Select a device to reverse ports:"
select choice in "${device_options[@]}"; do
  if [[ -n "$choice" ]]; then
    index=$((REPLY - 1))
    selected_serial="${device_serials[$index]}"
    echo ""
    echo "You selected: $choice"
    echo "Reversing ports on $selected_serial..."

    adb -s "$selected_serial" reverse tcp:8000 tcp:8000
    adb -s "$selected_serial" reverse tcp:8081 tcp:8081

    echo "Reverse TCP done for $selected_serial"
    break
  else
    echo "Invalid selection. Try again."
  fi
done
