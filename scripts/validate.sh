#!/usr/bin/env bash
# validate.sh - build both stack files, then render every HelmChart in them with `helm template` (Docker only).
# Output: rendered manifests in build/rendered/<stack file>/<name>.yaml. Fails on any chart or values error.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.py"
for STACK in ai-gateway ai-gateway-cluster; do
OUT="$ROOT/build/rendered/$STACK"; mkdir -p "$OUT"
python3 -I - "$ROOT/$STACK.yaml" "$OUT" <<'PY'
import sys, yaml, pathlib
src = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2])
for d in yaml.safe_load_all(src.read_text()):
    if d and d["kind"] == "HelmChart":
        s = d["spec"]; n = d["metadata"]["name"]
        (out / f"{n}.values.yaml").write_text(s.get("valuesContent", ""))
        (out / f"{n}.meta").write_text(f"{n}|{s.get('repo','')}|{s['chart']}|{s['version']}|{s['targetNamespace']}\n")
PY
for meta in "$OUT"/*.meta; do
  IFS='|' read -r name repo chart version ns < "$meta"
  echo "==> $STACK: helm template $name ($chart $version)"
  if [ -n "$repo" ]; then SRC=(--repo "$repo" "$chart"); else SRC=("$chart"); fi
  docker run --rm -v "$OUT:/w" -w /w alpine/helm:latest template "$name" "${SRC[@]}" --version "$version" \
    --namespace "$ns" -f "/w/$name.values.yaml" --api-versions clickhouse.com/v1alpha1/ClickHouseCluster \
    > "$OUT/$name.yaml"
  echo "    $(grep -c '^kind:' "$OUT/$name.yaml") objects"
done
done
echo "OK"
