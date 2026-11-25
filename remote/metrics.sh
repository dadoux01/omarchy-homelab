# Runs on the homelab host through `ssh host sh -s`. POSIX sh, Linux only.
# Prints one "key<TAB>field<TAB>..." record per line; Model.js parses them.
# Sections the hardware lacks (GPU, sensors, swap) simply print nothing.
LC_ALL=C
export LC_ALL
T=$(printf '\t')

net_bytes() {
  awk -F'[: ]+' 'NR > 2 && $2 != "lo" { rx += $3; tx += $11 } END { printf "%.0f %.0f", rx, tx }' /proc/net/dev
}

echo "host${T}$(cat /proc/sys/kernel/hostname 2>/dev/null)"
if [ -r /etc/os-release ]; then
  (. /etc/os-release && echo "os${T}${PRETTY_NAME:-$NAME}")
fi
echo "kernel${T}$(uname -r)"
echo "uptime${T}$(cut -d' ' -f1 /proc/uptime)"
echo "load${T}$(cut -d' ' -f1-3 /proc/loadavg)"
echo "cpus${T}$(grep -c '^processor' /proc/cpuinfo)"
model=$(grep -m1 -E '^(model name|Model|Hardware)' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
[ -n "$model" ] && echo "cpumodel${T}${model}"

# CPU and network rates come from two samples half a second apart.
s1=$(head -1 /proc/stat); n1=$(net_bytes)
sleep 0.5
s2=$(head -1 /proc/stat); n2=$(net_bytes)
echo "cpustat${T}${s1}${T}${s2}"
echo "net${T}${n1}${T}${n2}${T}0.5"

awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ { v[$1] = $2 }
  END { printf "mem\t%s\t%s\t%s\t%s\n", v["MemTotal:"], v["MemAvailable:"], v["SwapTotal:"], v["SwapFree:"] }' /proc/meminfo

df -P -k -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs -x fuse.snapfuse 2>/dev/null \
  | awk 'NR > 1 && $2 > 0 && !seen[$1]++ { print "disk\t" $6 "\t" $2 "\t" $3 }' | head -n 12

for chip in /sys/class/hwmon/hwmon*; do
  [ -r "$chip/name" ] || continue
  name=$(cat "$chip/name")
  for input in "$chip"/temp*_input; do
    [ -r "$input" ] || continue
    value=$(cat "$input" 2>/dev/null) || continue
    label=$(cat "${input%_input}_label" 2>/dev/null)
    echo "temp${T}${name}${T}${label}${T}${value}"
  done
done | head -n 64

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', *' '{ print "gpu\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }'
fi
for busy in /sys/class/drm/card*/device/gpu_busy_percent; do
  [ -r "$busy" ] || continue
  dev=${busy%/gpu_busy_percent}
  used=$(cat "$dev/mem_info_vram_used" 2>/dev/null)
  total=$(cat "$dev/mem_info_vram_total" 2>/dev/null)
  echo "gpu${T}AMD GPU${T}$(cat "$busy")${T}$(( ${used:-0} / 1048576 ))${T}$(( ${total:-0} / 1048576 ))${T}"
done

command -v docker >/dev/null 2>&1 && echo "docker${T}1"
exit 0
