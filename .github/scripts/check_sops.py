#!/usr/bin/env python3
"""Fail if a secret could land in Git unencrypted.

Rules:
- every *.sops.yaml / *.sops.yml has a sops block, and every value under
  data/stringData is an ENC[...] string
- every secrets.sops.env value is ENC[...] (sops_* metadata keys excepted)
- no other tracked YAML holds a Secret with data or stringData, unless every
  stringData value is a Flux ${var} placeholder that Flux fills in from the
  Terraform-written cluster-secrets-tf Secret
"""
import re
import subprocess
import sys

import yaml


def tracked():
    out = subprocess.run(["git", "ls-files"], check=True, capture_output=True, text=True)
    return [p for p in out.stdout.splitlines() if p]


def enc(v):
    return isinstance(v, str) and v.startswith("ENC[")


PLACEHOLDER = re.compile(r"\$\{[a-z0-9_]+\}")


def placeholders_only(doc):
    string_data = doc.get("stringData") or {}
    return (
        not doc.get("data")
        and bool(string_data)
        and all(isinstance(v, str) and PLACEHOLDER.fullmatch(v) for v in string_data.values())
    )


def check_sops_yaml(path, errors):
    with open(path) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    if not docs:
        errors.append(f"{path}: empty")
    for i, doc in enumerate(docs):
        if "sops" not in doc:
            errors.append(f"{path}[{i}]: no sops metadata, file is not encrypted")
        for field in ("data", "stringData"):
            for k, v in (doc.get(field) or {}).items():
                if not enc(v):
                    errors.append(f"{path}[{i}]: {field}.{k} is plaintext")


def check_sops_env(path, errors):
    seen_meta = False
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, val = line.partition("=")
            if key.startswith("sops_"):
                seen_meta = True
            elif not enc(val):
                errors.append(f"{path}:{n}: {key} is plaintext")
    if not seen_meta:
        errors.append(f"{path}: no sops metadata, file is not encrypted")


def check_plain_yaml(path, errors):
    try:
        with open(path) as f:
            docs = list(yaml.safe_load_all(f))
    except yaml.YAMLError:
        # Templated files (Helm, etc.) may not parse. kubeconform covers real manifests.
        return
    for i, doc in enumerate(docs):
        if isinstance(doc, dict) and doc.get("kind") == "Secret":
            if (doc.get("data") or doc.get("stringData")) and not placeholders_only(doc):
                errors.append(f"{path}[{i}]: Secret with data outside a *.sops.yaml file")


def main():
    errors = []
    for p in tracked():
        name = p.rsplit("/", 1)[-1]
        if name in (".sops.yaml", ".sops.yml"):
            continue  # sops creation rules, not a secret
        if name.endswith((".sops.yaml", ".sops.yml")):
            check_sops_yaml(p, errors)
        elif p.endswith("secrets.sops.env"):
            check_sops_env(p, errors)
        elif p.endswith((".yaml", ".yml")):
            check_plain_yaml(p, errors)
    for e in errors:
        print(f"::error::{e}")
    if errors:
        return 1
    print("sops check: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
