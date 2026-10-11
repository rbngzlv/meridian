#!/bin/sh
# Run as the deploy user in the disposable recipe VM after a Go deployment.
# Args: fixture directory, active Go upstream (container:8080).
set -eu
case "$(hostname)" in lima-meridian-e2e-*) ;; *) echo "Requires an isolated Meridian E2E VM" >&2; exit 1;; esac
fixture=$1
upstream=$2
config=.config/containers/meridian-caddy
host_ip=$(ip -4 route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1);exit}}')
backup=$(mktemp -d "$config/tls-test.XXXXXX")
cp "$config/Caddyfile" "$backup/Caddyfile"
cleanup() {
    status=$?
    trap - EXIT
    cp "$backup/Caddyfile" "$config/Caddyfile"
    rm -f "$config/routes/socket-test.caddy"
    podman exec meridian-caddy caddy reload --config /config/Caddyfile --adapter caddyfile --address unix//config/admin.sock
    podman rm -f --ignore meridian-pebble
    exit "$status"
}
trap cleanup EXIT
podman run -d --name meridian-pebble --network=meridian-proxy --network-alias=pebble \
    --add-host="sockets.example.test:$host_ip" \
    -e PEBBLE_VA_NOSLEEP=1 -e PEBBLE_WFE_NONCEREJECT=0 -e PEBBLE_AUTHZREUSE=0 \
    -v "$fixture/pebble.json:/test/meridian.json:ro" \
    ghcr.io/letsencrypt/pebble:2.8.0 -config /test/meridian.json
podman cp meridian-pebble:/test/certs/pebble.minica.pem "$config/pebble.minica.pem"
awk -v storage="/config/${backup##*/}/storage" 'NR==1 {print; print "\tstorage file_system {\n\t\troot " storage "\n\t}\n\tacme_ca https://pebble:14000/dir\n\tacme_ca_root /config/pebble.minica.pem\n\trenew_interval 1s\n\trenewal_window_ratio 0.5"; next} {print}' \
    "$backup/Caddyfile" > "$config/Caddyfile"
printf 'sockets.example.test {\n\treverse_proxy %s\n}\n' "$upstream" > "$config/routes/socket-test.caddy"
podman exec meridian-caddy caddy reload --config /config/Caddyfile --adapter caddyfile --address unix//config/admin.sock

serial() {
    openssl s_client -connect 127.0.0.1:443 -servername sockets.example.test </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null
}
for attempt in $(seq 1 90); do
    if first=$(serial); then break; fi
    sleep 1
done
[ -n "${first:-}" ] || { podman logs meridian-caddy; exit 1; }
echo "ACME issued $first"
redirect=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: sockets.example.test' http://127.0.0.1/client-ip)
[ "$redirect" = 308 ]
for protocol in --http1.1 --http2; do
    result=$(curl -ksS --fail "$protocol" -w ' %{http_version}' --interface 127.0.0.2 --resolve sockets.example.test:443:127.0.0.1 \
        -H 'X-Forwarded-For: 203.0.113.99' https://sockets.example.test/client-ip)
    case "$protocol" in --http1.1) expected='127.0.0.2 1.1';; --http2) expected='127.0.0.2 2';; esac
    [ "$result" = "$expected" ] || { echo "Unexpected XFF/protocol: $result"; exit 1; }
    echo "$protocol preserved 127.0.0.2 and rejected spoofed XFF"
done
http3=$(podman run --rm --network=host localhost/meridian-http3-test:latest)
[ "$http3" = 'HTTP/3.0 127.0.0.1' ] || { echo "Unexpected QUIC result: $http3"; exit 1; }
echo "$http3"
for attempt in $(seq 1 150); do
    next=$(serial) || next=$first
    if [ "$next" != "$first" ]; then echo "ACME renewed $first -> $next"; exit 0; fi
    sleep 1
done
echo "ACME renewal did not occur" >&2
podman logs meridian-caddy
exit 1
