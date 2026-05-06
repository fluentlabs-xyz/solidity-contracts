// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {DeployBase} from "../../deploy/DeployBase.s.sol";

/**
 * @title Migrate_Transfer_Ownership
 * @notice Walks every address entry in `deployments/mainnet/l1.json` **or**
 *         `deployments/mainnet/l2.json` (chosen from `block.chainid`), and for each
 *         contract that exposes OpenZeppelin {IAccessControl} (via ERC-165), transfers
 *         `DEFAULT_ADMIN_ROLE` from the forge broadcaster to `NEW_DEFAULT_ADMIN`.
 *
 * @dev Run **twice** with different RPCs:
 *        - Ethereum mainnet (`chainId` 1) → processes `l1.json`
 *        - Fluent L2 mainnet (`chainId` 25363) → processes `l2.json`
 *
 * @dev For each manifest key the script:
 *        1. Resolves the address (flat or nested `.deployment.*`).
 *        2. Skips zero addresses and duplicate addresses already handled.
 *        3. If the contract does not support `IAccessControl`, logs and skips (e.g. Ownable-only
 *           gateways, blacklist, factory, beacons).
 *        4. If the broadcaster does not hold `DEFAULT_ADMIN_ROLE`, logs and skips (no revert).
 *        5. If `NEW_DEFAULT_ADMIN` already has the role and broadcaster is different, logs and skips
 *           renounce to avoid leaving two admins unintentionally — operator should fix off-chain.
 *        6. Otherwise: `grantRole(DEFAULT_ADMIN_ROLE, newAdmin)` then
 *           `renounceRole(DEFAULT_ADMIN_ROLE, broadcaster)`.
 *
 * @dev Environment:
 *        `NEW_DEFAULT_ADMIN` (required) — account that will receive `DEFAULT_ADMIN_ROLE`.
 *        `CURRENT_DEFAULT_ADMIN` (required) — must match the forge broadcast sender; used for a
 *             safety check against `vm.readCallers()` after `vm.startBroadcast()`.
 *
 * @dev Usage:
 *        # L1
 *        forge script scripts/migrations/mainnet/Migrate_Transfer_Ownership.s.sol:Migrate_Transfer_Ownership \
 *          --rpc-url "$MAINNET_RPC" --broadcast -vvvv
 *        # L2 (Fluent)
 *        forge script scripts/migrations/mainnet/Migrate_Transfer_Ownership.s.sol:Migrate_Transfer_Ownership \
 *          --rpc-url "$FLUENT_MAINNET_RPC" --broadcast -vvvv
 */
contract Migrate_Transfer_Ownership is DeployBase {
    using stdJson for string;

    /// @dev OpenZeppelin `AccessControl.DEFAULT_ADMIN_ROLE`.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000000;

    string internal constant MAINNET_DEPLOY_DIR = "deployments/mainnet/";

    mapping(address => bool) private _seen;

    function run() external {
        address newAdmin = vm.envAddress("NEW_DEFAULT_ADMIN");
        address expectedBroadcaster = vm.envAddress("CURRENT_DEFAULT_ADMIN");
        require(newAdmin != address(0), "NEW_DEFAULT_ADMIN required");
        require(expectedBroadcaster != address(0), "CURRENT_DEFAULT_ADMIN required");

        string memory manifestPath = _manifestPathForChain(block.chainid);
        string memory json = vm.readFile(manifestPath);
        uint256 manifestChainId = json.readUint(".chainId");
        require(block.chainid == manifestChainId, "block.chainid != manifest chainId (wrong RPC?)");

        console2.log("== Migrate_Transfer_Ownership (DEFAULT_ADMIN_ROLE) ==");
        console2.log("manifest     :", manifestPath);
        console2.log("chainId      :", block.chainid);
        console2.log("new admin    :", newAdmin);
        console2.log("");

        vm.startBroadcast();
        (, address broadcaster, ) = vm.readCallers();
        require(broadcaster == expectedBroadcaster, "Broadcaster != CURRENT_DEFAULT_ADMIN");

        string[] memory keys = _keysForManifest(block.chainid);
        for (uint256 i = 0; i < keys.length; i++) {
            _processKey(json, keys[i], broadcaster, newAdmin);
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("== Done ==");
    }

    function _manifestPathForChain(uint256 chainId) internal view returns (string memory) {
        if (chainId == 1) return string.concat(MAINNET_DEPLOY_DIR, "l1.json");
        if (chainId == 25_363) return string.concat(MAINNET_DEPLOY_DIR, "l2.json");
        revert(string.concat("Unsupported chainId ", vm.toString(chainId), " (expected 1 or 25363)"));
    }

    /// @dev Every JSON key that resolves to an address in the mainnet manifests.
    function _keysForManifest(uint256 chainId) internal pure returns (string[] memory k) {
        if (chainId == 1) {
            k = new string[](21);
            k[0] = "bridge";
            k[1] = "bridge_impl";
            k[2] = "erc20_gateway";
            k[3] = "erc20_gateway_impl";
            k[4] = "factory";
            k[5] = "factory_beacon";
            k[6] = "factory_impl";
            k[7] = "mock_token";
            k[8] = "native_gateway";
            k[9] = "native_gateway_impl";
            k[10] = "nitro_verifier";
            k[11] = "pegged_impl";
            k[12] = "rollup";
            k[13] = "rollup_impl";
            k[14] = "timelock";
            k[15] = "fast_withdrawal_list_proxy";
            k[16] = "fast_withdrawal_list_impl";
            k[17] = "blacklist_proxy";
            k[18] = "blacklist_impl";
            k[19] = "weth_gateway_proxy";
            k[20] = "weth_gateway_impl";
            return k;
        }
        if (chainId == 25_363) {
            k = new string[](13);
            k[0] = "bridge";
            k[1] = "bridge_impl";
            k[2] = "erc20_gateway";
            k[3] = "erc20_gateway_impl";
            k[4] = "factory";
            k[5] = "factory_impl";
            k[6] = "l1_block_oracle";
            k[7] = "l1_gas_oracle";
            k[8] = "native_gateway";
            k[9] = "native_gateway_impl";
            k[10] = "pegged_impl";
            k[11] = "weth_gateway_proxy";
            k[12] = "weth_gateway_impl";
            return k;
        }
        revert("unsupported chain for keys");
    }

    function _processKey(string memory json, string memory key, address broadcaster, address newAdmin) internal {
        address target = _readAddr(json, key);
        if (target == address(0)) {
            console2.log("[skip zero     ]", key);
            return;
        }
        if (_seen[target]) {
            console2.log("[skip duplicate]", key, target);
            return;
        }
        _seen[target] = true;

        if (target.code.length == 0) {
            console2.log("[skip no code  ]", key, target);
            return;
        }

        if (!_supportsAccessControl(target)) {
            console2.log("[skip no AC     ]", key, target);
            return;
        }

        bool broadcasterIsAdmin = IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, broadcaster);
        bool newAdminIsAdmin = IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, newAdmin);

        if (!broadcasterIsAdmin) {
            console2.log("[skip not admin ]", key, target);
            return;
        }

        if (broadcaster == newAdmin) {
            console2.log("[noop same addr ]", key, target);
            return;
        }

        if (newAdminIsAdmin) {
            console2.log("[skip new already admin, fix manually]", key, target);
            return;
        }

        IAccessControl(target).grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        require(IAccessControl(target).hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "grantRole failed");
        IAccessControl(target).renounceRole(DEFAULT_ADMIN_ROLE, broadcaster);

        console2.log("[transferred    ]", key, target);
    }

    function _supportsAccessControl(address target) internal view returns (bool) {
        try IERC165(target).supportsInterface(type(IAccessControl).interfaceId) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
