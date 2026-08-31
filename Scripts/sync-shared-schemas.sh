#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
infra_root="${INFRA_ROOT:-$(cd "$repo_root/../fluentwork-infra" && pwd)}"

src_transport="$infra_root/schemas/transport/wss-control-frames-v1.json"
src_events="$infra_root/schemas/events/speech-observability-events-v1.json"
dst_root="$repo_root/Shared/FluentWorkCore/Resources/Schemas"

test -f "$src_transport"
test -f "$src_events"

mkdir -p "$dst_root"
cp "$src_transport" "$dst_root/wss-control-frames-v1.json"
cp "$src_events" "$dst_root/speech-observability-events-v1.json"

echo "Synced shared schema mirrors into $dst_root"
