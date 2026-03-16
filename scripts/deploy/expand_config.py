#!/usr/bin/env python3
"""Write a config JSON with overridden rpcUrl, blockExplorerUrl, chainId (for deployment output)."""
import json
import sys


def main() -> None:
    if len(sys.argv) != 6:
        print("Usage: expand_config.py <config_in> <config_out> <rpc_url> <block_explorer_url> <chain_id>", file=sys.stderr)
        sys.exit(1)
    config_path, out_path, rpc_url, block_explorer_url, chain_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)
    config["rpcUrl"] = rpc_url
    config["blockExplorerUrl"] = block_explorer_url
    try:
        config["chainId"] = int(chain_id)
    except ValueError:
        config["chainId"] = chain_id
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)


if __name__ == "__main__":
    main()
