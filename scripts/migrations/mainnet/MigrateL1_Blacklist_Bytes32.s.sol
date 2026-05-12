// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";

import {Blacklist} from "../../../contracts/blacklist/Blacklist.sol";
import {DeployBase} from "../../deploy/DeployBase.s.sol";

interface IUUPSUpgradeable {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IBlacklistBytes32Batch {
    function setBlacklistedBatch(bytes32[] calldata accounts, bool status) external;
}

/**
 * @title MigrateL1_Blacklist_Bytes32
 * @notice Prepares the L1 mainnet Blacklist ERC-7201 slot fix for multisig execution.
 *
 * @dev What this script does:
 *        1. Reads the existing Blacklist proxy from `deployments/mainnet/l1.json`
 *           (`blacklist`) unless `BLACKLIST_PROXY` is provided.
 *        2. Deploys a fresh {Blacklist} implementation with the corrected bytes32
 *           ERC-7201 storage location.
 *        3. Writes a Safe Transaction Builder JSON batch with:
 *             - `upgradeToAndCall(newImpl, "")`;
 *             - `setBlacklistedBatch(bytes32[] entries, true)`.
 *
 *      The proxy initializer is intentionally not called again: OpenZeppelin's
 *      initializer version is already consumed on the proxy and {Ownable2StepUpgradeable}
 *      state is stored in OpenZeppelin's own namespace. The migration "initializes" the
 *      moved blacklist mapping by replaying the configured entries into the new slot
 *      from the multisig batch.
 *
 * @dev The broadcasting key only deploys the implementation and writes the JSON file.
 *      The Safe owner executes both privileged calls.
 *
 * @dev Environment:
 *        BLACKLIST_PROXY (optional) — existing Blacklist proxy. Defaults to manifest key
 *                                     `blacklist` in deployments/mainnet/l1.json.
 *        BLACKLIST_FILE  (optional) — one EVM address per line. Defaults to
 *                                     scripts/config/blacklist/black_list_eth.txt.
 *        SAFE_ADDRESS    (optional) — Safe address for Transaction Builder metadata.
 *                                     Defaults to the current Blacklist owner.
 *        SAFE_BATCH_PATH (optional) — output JSON path. Defaults to
 *                                     deployments/mainnet/blacklist-bytes32-safe-batch.json.
 */
contract MigrateL1_Blacklist_Bytes32 is DeployBase {
    /// @dev Default location for the L1 Ethereum blacklist source file.
    string internal constant DEFAULT_LIST_PATH = "scripts/config/blacklist/black_list_eth.txt";
    /// @dev Manifest containing the deployed L1 Blacklist proxy address.
    string internal constant L1_MANIFEST_PATH = "deployments/mainnet/l1.json";
    /// @dev Default Safe Transaction Builder output path.
    string internal constant DEFAULT_SAFE_BATCH_PATH = "deployments/mainnet/blacklist-bytes32-safe-batch.json";

    function run() external {
        address blacklistProxy = vm.envOr("BLACKLIST_PROXY", address(0));
        if (blacklistProxy == address(0)) {
            string memory manifest = vm.readFile(L1_MANIFEST_PATH);
            blacklistProxy = _readAddr(manifest, "blacklist");
            if (blacklistProxy == address(0)) {
                blacklistProxy = _readAddr(manifest, "blacklist_proxy");
            }
        }
        require(blacklistProxy != address(0), "blacklist proxy missing");

        string memory listPath = vm.envOr("BLACKLIST_FILE", DEFAULT_LIST_PATH);
        bytes32[] memory entries = _loadKeys(listPath);
        require(entries.length > 0, "blacklist file produced zero addresses; refusing to migrate");

        address currentOwner = Blacklist(blacklistProxy).owner();
        address safe = vm.envOr("SAFE_ADDRESS", currentOwner);
        require(safe != address(0), "SAFE_ADDRESS/current owner missing");
        require(safe == currentOwner, "SAFE_ADDRESS must match Blacklist owner");
        string memory safeBatchPath = vm.envOr("SAFE_BATCH_PATH", DEFAULT_SAFE_BATCH_PATH);

        _logPlan(blacklistProxy, currentOwner, safe, listPath, safeBatchPath, entries.length);

        vm.startBroadcast();

        address newImpl = address(new Blacklist());
        console2.log("Blacklist new impl:", newImpl);

        vm.stopBroadcast();

        bytes memory upgradeData = abi.encodeCall(IUUPSUpgradeable.upgradeToAndCall, (newImpl, ""));
        bytes memory setupData = abi.encodeCall(IBlacklistBytes32Batch.setBlacklistedBatch, (entries, true));
        SafeTransaction[] memory transactions = new SafeTransaction[](2);
        transactions[0] = SafeTransaction({
            to: blacklistProxy,
            value: 0,
            data: upgradeData,
            contractMethod: _upgradeToAndCallMethodJson(),
            contractInputsValues: _upgradeToAndCallInputsJson(newImpl)
        });
        transactions[1] = SafeTransaction({
            to: blacklistProxy,
            value: 0,
            data: setupData,
            contractMethod: _setBlacklistedBatchMethodJson(),
            contractInputsValues: _setBlacklistedBatchInputsJson(entries)
        });
        _writeSafeBatch(
            safeBatchPath,
            safe,
            "MigrateL1_Blacklist_Bytes32",
            "Upgrade L1 Blacklist implementation and seed bytes32 blacklist storage.",
            transactions
        );

        console2.log("");
        console2.log("== Migration prepared ==");
        console2.log("blacklist proxy:", blacklistProxy);
        console2.log("new impl:       ", newImpl);
        console2.log("safe batch:     ", safeBatchPath);
        console2.log("");
        console2.log("After Safe execution, update deployments/mainnet/l1.json:");
        console2.log("  blacklist_impl ->", newImpl);
    }

    /// @dev Reads `path` and converts every canonical EVM address line into the
    ///      bytes32 key consumed by {Blacklist}. Non-EVM lines, comments, and blank
    ///      lines are skipped so the source file can contain mixed sanctions-list data.
    function _loadKeys(string memory path) internal view returns (bytes32[] memory entries) {
        string memory text = vm.readFile(path);
        string[] memory lines = vm.split(text, "\n");

        uint256 count;
        for (uint256 i; i < lines.length; i++) {
            if (_isEvmAddressLine(lines[i])) count++;
        }

        entries = new bytes32[](count);
        uint256 idx;
        for (uint256 i; i < lines.length; i++) {
            if (!_isEvmAddressLine(lines[i])) continue;
            entries[idx++] = _toKey(vm.parseAddress(lines[i]));
        }
    }

    /// @dev True iff `line` is exactly 42 characters and starts with `0x` or `0X`.
    ///      Hex-character validation is left to {vm.parseAddress}, so typos in
    ///      EVM-shaped lines abort the migration loudly.
    function _isEvmAddressLine(string memory line) internal pure returns (bool) {
        bytes memory b = bytes(line);
        if (b.length != 42) return false;
        if (b[0] != bytes1("0")) return false;
        if (b[1] != bytes1("x") && b[1] != bytes1("X")) return false;
        return true;
    }

    function _toKey(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _logPlan(
        address blacklistProxy,
        address currentOwner,
        address safe,
        string memory listPath,
        string memory safeBatchPath,
        uint256 entries
    ) internal pure {
        console2.log("== MigrateL1_Blacklist_Bytes32 ==");
        console2.log("Blacklist proxy:", blacklistProxy);
        console2.log("Current owner:  ", currentOwner);
        console2.log("Safe:           ", safe);
        console2.log("Source file:    ", listPath);
        console2.log("Safe batch path:", safeBatchPath);
        console2.log("Entries to seed:", entries);
        console2.log("");
    }

    function _upgradeToAndCallMethodJson() internal pure returns (string memory) {
        return string.concat(
            "{",
            '"inputs":[{"internalType":"address","name":"newImplementation","type":"address"},',
            '{"internalType":"bytes","name":"data","type":"bytes"}],',
            '"name":"upgradeToAndCall",',
            '"payable":true',
            "}"
        );
    }

    function _upgradeToAndCallInputsJson(address newImpl) internal pure returns (string memory) {
        return string.concat(
            "{",
            '"newImplementation":"',
            _addressToHex(newImpl),
            '",',
            '"data":"0x"',
            "}"
        );
    }

    function _setBlacklistedBatchMethodJson() internal pure returns (string memory) {
        return string.concat(
            "{",
            '"inputs":[{"internalType":"bytes32[]","name":"accounts","type":"bytes32[]"},',
            '{"internalType":"bool","name":"status","type":"bool"}],',
            '"name":"setBlacklistedBatch",',
            '"payable":false',
            "}"
        );
    }

    function _setBlacklistedBatchInputsJson(bytes32[] memory entries) internal pure returns (string memory) {
        return string.concat("{", '"accounts":', _bytes32ArrayJson(entries), ",", '"status":"true"', "}");
    }

    function _bytes32ArrayJson(bytes32[] memory values) internal pure returns (string memory json) {
        json = "[";
        for (uint256 i; i < values.length; i++) {
            json = string.concat(json, '"', _toHex(abi.encodePacked(values[i])), '"');
            if (i + 1 < values.length) json = string.concat(json, ",");
        }
        json = string.concat(json, "]");
    }
}
