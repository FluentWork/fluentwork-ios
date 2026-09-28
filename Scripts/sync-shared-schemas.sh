#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
infra_root="${INFRA_ROOT:-$(cd "$repo_root/../fluentwork-infra" && pwd)}"
backend_root="${BACKEND_ROOT:-$(cd "$repo_root/../fluentwork-backend" && pwd)}"

src_transport_v2="$infra_root/schemas/transport/wss-control-frames-v2.json"
src_events="$infra_root/schemas/events/speech-observability-events-v1.json"
src_openapi="$backend_root/api/openapi-v1.yaml"
dst_root="$repo_root/Shared/FluentWorkCore/Resources/Schemas"

test -f "$src_transport_v2"
test -f "$src_events"
test -f "$src_openapi"

mkdir -p "$dst_root"
cp "$src_transport_v2" "$dst_root/wss-control-frames-v2.json"
cp "$src_events" "$dst_root/speech-observability-events-v1.json"
cp "$src_openapi" "$dst_root/openapi-v1.yaml"

echo "Synced shared schema mirrors into $dst_root"
