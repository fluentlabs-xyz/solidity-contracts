#!/usr/bin/env python3
"""
Helpers for deployment JSON: read a key, merge deployment files.
Usage:
  deployment_json.py get <file> <key>
  deployment_json.py merge <l1_bridge> <l1_stack> <l1_config> <l2_bridge> <l2_stack> <l2_config> <out_sepolia> <out_fluent>
  deployment_json.py merge_chain <config_path> <out_path> <file1> [file2 ...]   # merge N deployment files + config -> one chain JSON
"""
import json
import sys


def load(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def get_key(file_path: str, key: str) -> str:
    """Read a key from JSON; supports top-level or nested 'deployment' key."""
    data = load(file_path)
    value = data.get(key) or (data.get("deployment") or {}).get(key)
    return value if value is not None else ""


def _merge_deployment_into(dep: dict, path: str) -> None:
    data = load(path)
    block = data.get("deployment") or data
    for k, v in (block or {}).items():
        if v is not None and v != "":
            dep.setdefault(k, v)
    if "mock_erc20" in dep and "mock_token" not in dep:
        dep["mock_token"] = dep["mock_erc20"]


def merge_bridge_stack(bridge_path: str, stack_path: str, config_path: str, out_path: str) -> None:
    """Merge bridge JSON + stack JSON + config into one chain deployment file."""
    config = load(config_path)
    dep: dict = {}
    _merge_deployment_into(dep, bridge_path)
    _merge_deployment_into(dep, stack_path)
    out = {
        "chainId": config.get("chainId"),
        "chainName": config.get("chainName"),
        "rpcUrl": config.get("rpcUrl"),
        "blockExplorerUrl": config.get("blockExplorerUrl", ""),
        "deployment": dep,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)


# L2 Universal chain: no beacon; pegged "impl" is the precompile runtime.
L2_PEGGED_IMPL = "0x0000000000000000000000000000000000520008"
L2_FACTORY_BEACON = "0x0000000000000000000000000000000000000000"


def merge_chain(config_path: str, out_path: str, *deployment_files: str, l2_defaults: bool = False) -> None:
    """Merge N deployment JSONs + config into one chain output. mock_erc20 -> mock_token. If l2_defaults, set pegged_impl/factory_beacon for L2."""
    config = load(config_path)
    dep: dict = {}
    for path in deployment_files:
        _merge_deployment_into(dep, path)
    if l2_defaults:
        dep.setdefault("pegged_impl", L2_PEGGED_IMPL)
        dep.setdefault("factory_beacon", L2_FACTORY_BEACON)
    out = {
        "chainId": config.get("chainId"),
        "chainName": config.get("chainName"),
        "rpcUrl": config.get("rpcUrl"),
        "blockExplorerUrl": config.get("blockExplorerUrl", ""),
        "deployment": dep,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    cmd = sys.argv[1].lower()
    if cmd == "get":
        if len(sys.argv) != 4:
            print("Usage: deployment_json.py get <file> <key>", file=sys.stderr)
            sys.exit(1)
        _, file_path, key = sys.argv[1], sys.argv[2], sys.argv[3]
        print(get_key(file_path, key))
    elif cmd == "merge":
        if len(sys.argv) != 10:
            print(
                "Usage: deployment_json.py merge <l1_bridge> <l1_stack> <l1_config> <l2_bridge> <l2_stack> <l2_config> <out_sepolia> <out_fluent>",
                file=sys.stderr,
            )
            sys.exit(1)
        l1_bridge, l1_stack, l1_config, l2_bridge, l2_stack, l2_config, out_sepolia, out_fluent = sys.argv[2:10]
        merge_bridge_stack(l1_bridge, l1_stack, l1_config, out_sepolia)
        merge_bridge_stack(l2_bridge, l2_stack, l2_config, out_fluent)
    elif cmd == "merge_chain":
        if len(sys.argv) < 5:
            print("Usage: deployment_json.py merge_chain <config_path> <out_path> <file1> [file2 ...] [--l2]", file=sys.stderr)
            sys.exit(1)
        args = sys.argv[4:]
        l2_defaults = False
        if args and args[-1] == "--l2":
            args = args[:-1]
            l2_defaults = True
        config_path, out_path = sys.argv[2], sys.argv[3]
        merge_chain(config_path, out_path, *args, l2_defaults=l2_defaults)
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
