#!/bin/sh
# Logs, once a second, what the Mac's USB-C ports and USB device controller
# are doing: who supplies power, which data role the Mac has, and whether a
# host (e.g. DJI goggles) has enumerated/configured the Mac. Read-only.
# Usage: tools/usbc-role-monitor.sh [seconds]   (default: run until Ctrl-C)
N=${1:-0}; i=0
while [ "$N" -eq 0 ] || [ "$i" -lt "$N" ]; do
  ts=$(date +%H:%M:%S)
  ports=$(ioreg -p IOAccessory -w0 -l 2>/dev/null | awk '
    /\+-o Port-USB-C@/ { if (p) print p; p=$2 }
    /"ConnectionActive" =/ { p=p" active="$NF }
    /"TransportsActive" =/ { sub(/.*= /,""); gsub(/[" ]/,""); p=p" tx="$0 }
    /"Data Status Reg" =/ { sub(/.*= /,""); p=p" dsr="$0 }
    END { print p }' | tr '\n' ' ')
  pwr=$(ioreg -rw0 -c AppleSmartBattery | grep -oE '"AdapterDetails" = \{[^}]*\}' | grep -oE '"Watts"=[0-9]+|"Current"=[0-9]+|"AdapterVoltage"=[0-9]+' | tr '\n' ' ')
  dev=$(ioreg -w0 -l -r -c AppleT8103USBXDCI 2>/dev/null | grep -oE '"CurrentState" = \{[^}]*\}' | grep -oE '"(DeviceState|DeviceAddress|SelectedConfiguration|ConnectionSpeedDescription)"=[^,}]*' | tr '\n' ' ' )
  host=$(ioreg -p IOUSB -w0 | grep -c 'IOUSBHostDevice')
  ncm=$(netstat -I en3 -b 2>/dev/null | awk 'NR==2{print "en3 in="$5" out="$8}')
  echo "$ts | $ports | power: $pwr | mac-as-device: $dev | usb-devices-seen: $host | $ncm"
  i=$((i+1)); sleep 1
done
