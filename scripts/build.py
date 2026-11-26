#!/usr/bin/env python3
"""build.py - assemble ai-gateway.yaml (single node) and ai-gateway-cluster.yaml (cluster) from ai-gateway.yaml.in.

A line holding only one of these markers is processed, here and in included files:
  @@FILE path@@          replaced by that file's lines, indented like the marker (includes may nest)
  @@SINGLE / @@CLUSTER   the lines that follow go into that output only, until the other marker or @@END
  @@SPREAD k=v[,k=v]@@   cluster only: keeps the copies of the pods with these labels on different nodes
Usage: scripts/build.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUTS = {"single": "ai-gateway.yaml", "cluster": "ai-gateway-cluster.yaml"}
FILE = re.compile(r"^(\s*)@@FILE (\S+)@@\s*$")
SPREAD = re.compile(r"^(\s*)@@SPREAD (\S+)@@\s*$")
BLOCK = re.compile(r"^\s*@@(SINGLE|CLUSTER|END)\s*$")


def spread(labels: str) -> list:
    match = ", ".join("{}: {}".format(*kv.split("=", 1)) for kv in labels.split(","))
    return [
        "topologySpreadConstraints:",
        "  - maxSkew: 1",
        "    topologyKey: kubernetes.io/hostname",
        "    whenUnsatisfiable: DoNotSchedule",
        "    nodeTaintsPolicy: Honor          # a failed node does not count",
        "    matchLabelKeys: [pod-template-hash]",
        "    labelSelector: { matchLabels: { %s } }" % match,
    ]


def expand(text: str, mode: str, seen: tuple = ()) -> str:
    out, only = [], None
    for line in text.splitlines():
        b = BLOCK.match(line)
        if b:
            only = None if b.group(1) == "END" else b.group(1).lower()
            continue
        if only not in (None, mode):
            continue
        s = SPREAD.match(line)
        if s:
            if mode == "cluster":
                out.extend(s.group(1) + l for l in spread(s.group(2)))
            continue
        m = FILE.match(line)
        if not m:
            out.append(line)
            continue
        indent, rel = m.groups()
        if rel in seen:
            sys.exit(f"include loop: {rel}")
        body = expand((ROOT / rel).read_text(), mode, seen + (rel,))
        out.extend((indent + l) if l.strip() else l for l in body.splitlines())
    if only is not None:
        sys.exit(f"@@{only.upper()} block without @@END in {seen[-1] if seen else 'the template'}")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    template = (ROOT / "ai-gateway.yaml.in").read_text()
    for mode, name in OUTPUTS.items():
        (ROOT / name).write_text(expand(template, mode))
        print(f"wrote {name}")
