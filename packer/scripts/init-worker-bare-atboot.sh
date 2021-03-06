#!/usr/bin/env bash
set -euo pipefail

printf "Initializing Worker for platform 'bare'...\n"

# A sed replacement by the caller will put the right Subnet CIDR here
subnet=SUBNET_PLACEHOLDER

trim() {
  sed -E 's/\s\s+//g' <("$@")
}

# Try a few times
for try in {1..10}; do
  printf "Try %s of 10 when looking for control plane...\n" "${try}"
  nmap -p8000 -- "${subnet}" \
  | grep -B4 -E '8000/tcp\s+open' \
  | grep 'scan report' \
  | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  > /tmp/netscan || {
    trim printf "\
      ERROR: Could not find any running hosts on subnet %s with open port 8000.\n" \
    "${subnet}" \
    > /dev/stderr
    continue
  }
  break
done

[[ "$(wc -l < /tmp/netscan)" -gt 0 ]]

while read -r host; do
  for filename in token hash; do
    curl -fsSL --connect-timeout 1 -o /tmp/"${filename}" "${host}":8000/"${filename}" || {
      trim printf "\
        ERROR: Could not retrieve %s from %s:8000.
        The host is probably up (since it was checked a few seconds ago), but the file isn't there.
        Either skipping this host, or exiting cleanly, so you can try again later from this node.\n" \
        "${filename}" "${host}" \
      > /dev/stderr
      continue
    }
    control_plane_ip="${host}"
  done
done < /tmp/netscan

# Keep trying to join the Cluster
until kubeadm join \
        "${control_plane_ip}":6443 \
        --token "$(cat /tmp/token)" \
        --discovery-token-ca-cert-hash "sha256:$(cat /tmp/hash)" \
; do
  printf "Unable to join cluster's control plane at %s; sleeping...\n" "${control_plane_ip}" > /dev/stderr
  sleep 15
done

# Delete the cron entry, so it only runs once ever
rm /etc/cron.d/init-k8s-worker-atboot
