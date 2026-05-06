// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Blacklist} from "../../../contracts/blacklist/Blacklist.sol";
import {ERC20Gateway} from "../../../contracts/gateways/ERC20Gateway.sol";
import {NativeGateway} from "../../../contracts/gateways/NativeGateway.sol";

import {DeployBase} from "../../deploy/DeployBase.s.sol";

/**
 * @title MigrateL1_Blacklist
 * @notice One-shot L1 mainnet migration that:
 *           1. Deploys a fresh {Blacklist} (UUPS proxy).
 *           2. Seeds it with the EVM addresses listed in
 *              `scripts/config/blacklist/black_list_eth.txt` via
 *              {Blacklist.setBlacklistedBatch}.
 *           3. Wires the new blacklist into the {ERC20Gateway} and {NativeGateway}
 *              recorded in `deployments/mainnet/l1.json` via
 *              {GatewayBase.setBlacklistRegistry}.
 *
 * @dev All three steps run inside a single `vm.startBroadcast()` block so the migration
 *      is atomic at the operator-script level. The signing key MUST simultaneously be:
 *        - the freshly minted {Blacklist}'s `Ownable2StepUpgradeable` owner
 *          (because step 2 calls the owner-only {Blacklist.setBlacklistedBatch}), AND
 *        - the existing owner of both gateways
 *          (because step 3 calls the owner-only {GatewayBase.setBlacklistRegistry}).
 *      In production both should be the same admin / multisig anyway. If they aren't,
 *      run this script with `WIRE_GATEWAYS=false` to skip step 3, then have the gateway
 *      owner call `setBlacklistRegistry(<deployed-blacklist>)` from a separate broadcast.
 *
 * @dev What this script does NOT do:
 *        - It does not transfer the new {Blacklist}'s ownership. Whatever address is
 *          passed via `BLACKLIST_OWNER` is left as the two-step Ownable owner. If
 *          `BLACKLIST_OWNER` was a deployer EOA, transfer to the production multisig
 *          (and have the multisig accept) before going live.
 *        - It does not update `deployments/mainnet/l1.json`. The operator copies the
 *          logged proxy + impl addresses into the manifest after the run.
 *
 * @dev Environment:
 *        BLACKLIST_OWNER (required) — initial Ownable owner of the new {Blacklist}; should
 *                                     match the gateway owner so steps 2 + 3 share a key.
 *        BLACKLIST_FILE  (optional) — path to the address list, one `0x…` per line.
 *                                     Defaults to `scripts/config/blacklist/black_list_eth.txt`.
 *        WIRE_GATEWAYS   (optional) — `true` (default) or `false`. When `false`, skips
 *                                     step 3 — useful when blacklist owner ≠ gateway owner
 *                                     and gateway wiring needs to happen from a different key.
 *
 * @dev Address-file format: one EOA per line, leading `0x` (or `0X`) required, trailing
 *      newline OK. Lines that aren't a canonical 42-char `0x` + 40-hex EVM address are
 *      skipped silently so operators can mix non-EVM entries (e.g. Bitcoin addresses
 *      copied from sanctions lists), comments, or blank lines into the source file
 *      without a separate sanitiser.
 */
contract MigrateL1_Blacklist is DeployBase {
    /// @dev Default location for the L1 (Ethereum mainnet) blacklist.
    string internal constant DEFAULT_LIST_PATH = "scripts/config/blacklist/black_list_eth.txt";
    /// @dev Manifest containing the deployed gateway addresses to wire.
    string internal constant L1_MANIFEST_PATH = "deployments/mainnet/l1.json";

    function run() external {
        address owner = vm.envAddress("INITIAL_OWNER");
        require(owner != address(0), "INITIAL_OWNER required");

        string memory listPath = vm.envOr("BLACKLIST_FILE", DEFAULT_LIST_PATH);
        bool wireGateways = vm.envOr("WIRE_GATEWAYS", true);

        address[] memory entries = _loadAddresses(listPath);
        require(entries.length > 0, "blacklist file produced zero addresses; refusing to deploy");

        // Read gateway addresses up-front so we abort *before* deploying anything if the
        // manifest is missing them and `WIRE_GATEWAYS=true` (operator typo prevention).
        address erc20Gateway;
        address nativeGateway;
        if (wireGateways) {
            string memory manifest = vm.readFile(L1_MANIFEST_PATH);
            erc20Gateway = _readAddr(manifest, "erc20_gateway");
            nativeGateway = _readAddr(manifest, "native_gateway");
            require(erc20Gateway != address(0), "erc20_gateway missing in deployments/mainnet/l1.json");
            require(nativeGateway != address(0), "native_gateway missing in deployments/mainnet/l1.json");
        }

        _logPlan(listPath, owner, entries.length, wireGateways, erc20Gateway, nativeGateway);

        vm.startBroadcast();

        // 1. Deploy implementation + UUPS proxy. The proxy is initialized with `owner` as
        //    the two-step Ownable2StepUpgradeable owner.
        Blacklist impl = new Blacklist();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Blacklist.initialize, (owner)));
        Blacklist blacklist = Blacklist(address(proxy));
        console2.log("Blacklist proxy:", address(blacklist));
        console2.log("Blacklist impl :", address(impl));

        // 2. Seed the list. {setBlacklistedBatch} is `onlyOwner`; the deployer is the
        //    current owner because the proxy was just initialised with `owner`. The broadcast
        //    tx must be signed by that key — operator is responsible for keeping
        //    `--private-key` (or wallet) in sync with `BLACKLIST_OWNER`.
        blacklist.setBlacklistedBatch(entries, true);
        console2.log("Seeded", entries.length, "addresses via setBlacklistedBatch");

        // 3. Wire the new blacklist into both L1 gateways. Each `setBlacklistRegistry`
        //    is `onlyOwner` on the gateway, so the same broadcaster key must own them too.
        //    A single failed wiring leaves the previous two steps committed — re-run with
        //    `WIRE_GATEWAYS=false` and the operator can finish wiring manually with the
        //    gateway-owner key.
        if (wireGateways) {
            ERC20Gateway(payable(erc20Gateway)).setBlacklistRegistry(address(blacklist));
            console2.log("ERC20Gateway.setBlacklistRegistry:  ", erc20Gateway, "<-", address(blacklist));
            NativeGateway(payable(nativeGateway)).setBlacklistRegistry(address(blacklist));
            console2.log("NativeGateway.setBlacklistRegistry: ", nativeGateway, "<-", address(blacklist));
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("== Migration complete ==");
        if (!wireGateways) {
            console2.log("Gateway wiring skipped (WIRE_GATEWAYS=false). Run as gateway owner:");
            console2.log("  ERC20Gateway(...).setBlacklistRegistry(", address(blacklist), ")");
            console2.log("  NativeGateway(...).setBlacklistRegistry(", address(blacklist), ")");
        }
        console2.log("Update deployments/mainnet/l1.json:");
        console2.log("  blacklist      ->", address(blacklist));
        console2.log("  blacklist_impl ->", address(impl));
    }

    /// @dev Reads `path` and parses every canonical "0x" + 40-hex line into an
    ///      `address[]`. Non-EVM entries (e.g. Bitcoin `bc1…`), comments, and blank lines
    ///      are skipped so operators can mix them into the source file without a separate
    ///      sanitiser. {vm.parseAddress} reverts on malformed `0x…` input, which intentionally
    ///      aborts the whole script — preferable to silently dropping a typo.
    function _loadAddresses(string memory path) internal view returns (address[] memory entries) {
        string memory text = vm.readFile(path);
        string[] memory lines = vm.split(text, "\n");

        // First pass: count valid lines so we can size the output array exactly. Doing two
        // passes is cheaper than allocating a worst-case array and copying.
        uint256 count;
        for (uint256 i = 0; i < lines.length; i++) {
            if (_isEvmAddressLine(lines[i])) count++;
        }
        entries = new address[](count);

        // Second pass: parse.
        uint256 idx;
        for (uint256 i = 0; i < lines.length; i++) {
            if (!_isEvmAddressLine(lines[i])) continue;
            entries[idx++] = vm.parseAddress(lines[i]);
        }
    }

    /// @dev True iff `line` is exactly 42 characters and starts with `0x` or `0X`. The
    ///      hex-character validity of the remaining 40 chars is left to {vm.parseAddress}
    ///      so a typo in an otherwise-EVM-shaped line still aborts loudly.
    function _isEvmAddressLine(string memory line) internal pure returns (bool) {
        bytes memory b = bytes(line);
        if (b.length != 42) return false;
        if (b[0] != bytes1("0")) return false;
        if (b[1] != bytes1("x") && b[1] != bytes1("X")) return false;
        return true;
    }

    function _logPlan(
        string memory listPath,
        address owner,
        uint256 entries,
        bool wireGateways,
        address erc20Gateway,
        address nativeGateway
    ) internal pure {
        console2.log("== MigrateL1_Blacklist ==");
        console2.log("Source file:   ", listPath);
        console2.log("Owner:         ", owner);
        console2.log("Entries to add:", entries);
        console2.log("Wire gateways: ", wireGateways);
        if (wireGateways) {
            console2.log("  ERC20Gateway: ", erc20Gateway);
            console2.log("  NativeGateway:", nativeGateway);
        }
        console2.log("");
    }
}
