#!/usr/bin/env bash
# ph-bench SSH_ARGS... — laptop -> Pi (NAT) -> uplink -> Cloudflare. Prints Mbit/s per run and Pi CPU busy% during the runs.
set -u
SSH=("$@")
cpu() { ssh "${SSH[@]}" "head -1 /proc/stat"; }
a=$(cpu)
for i in 1 2 3; do
  curl -s -o /dev/null --interface enp3s0 -w "down %{speed_download}\n" "https://speed.cloudflare.com/__down?bytes=40000000"
done | awk '{printf "%s %.1f Mbit/s\n",$1,$2*8/1e6}'
for i in 1 2 3; do
  head -c 15000000 /dev/urandom | curl -s -o /dev/null --interface enp3s0 -w "up %{speed_upload}\n" --data-binary @- "https://speed.cloudflare.com/__up"
done | awk '{printf "%s %.1f Mbit/s\n",$1,$2*8/1e6}'
b=$(cpu)
python3 -c "
a=list(map(int,'$a'.split()[1:])); b=list(map(int,'$b'.split()[1:]))
d=[y-x for x,y in zip(a,b)]; idle=d[3]+d[4]
print(f'pi cpu busy {100*(sum(d)-idle)/sum(d):.1f}% (softirq {100*d[6]/sum(d):.1f}%) over the runs')"
for i in 1 2 3 4 5; do curl -s -o /dev/null --interface enp3s0 -w "%{time_connect}\n" https://speed.cloudflare.com/__down?bytes=0; done | awk '{s+=$1} END {printf "tcp connect avg %.0f ms\n", s/NR*1000}'
