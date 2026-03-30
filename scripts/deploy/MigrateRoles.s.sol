// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {FluentTimeLock} from "../../contracts/governance/FluentTimeLock.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Migrates all privileged roles from deployer EOA to timelocks.
/// @dev Timelocks must be deployed with minDelay=0. After migration, delays are set to target values.
///      Must be run by the current admin/owner of all contracts.
///
/// Environment:
///   ENV (default: testnet) — determines manifest path
///   LAYER (required: "l1" or "l2") — which chain's contracts to migrate
///   NORMAL_TIMELOCK (required) — address of normal timelock
///   EMERGENCY_TIMELOCK (required) — address of emergency timelock
///   NORMAL_DELAY (required) — target delay for normal timelock (set after migration)
///   EMERGENCY_DELAY (required) — target delay for emergency timelock
contract MigrateRoles is DeployBase {
    using stdJson for string;

    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    function run() external {
        string memory env = vm.envOr("ENV", string("testnet"));
        string memory layer = vm.envString("LAYER");
        string memory manifest = vm.readFile(string.concat("deployments/", env, "/", layer, ".json"));

        address normalTL = vm.envAddress("NORMAL_TIMELOCK");
        address emergencyTL = vm.envAddress("EMERGENCY_TIMELOCK");
        uint256 normalDelay = vm.envUint("NORMAL_DELAY");
        uint256 emergencyDelay = vm.envUint("EMERGENCY_DELAY");

        require(normalTL != address(0) && emergencyTL != address(0), "timelock addresses required");

        address bridge = _readAddr(manifest, "bridge");
        address erc20Gateway = _readAddr(manifest, "erc20_gateway");
        address nativeGateway = _readAddr(manifest, "native_gateway");
        address factory = _readAddr(manifest, "factory");

        console2.log("Migrating roles (layer: %s)", layer);

        vm.startBroadcast();

        // ── Bridge ──
        if (bridge != address(0)) {
            IAccessControl(bridge).grantRole(DEFAULT_ADMIN_ROLE, normalTL);
            IAccessControl(bridge).grantRole(PAUSER_ROLE, emergencyTL);
            console2.log("  Bridge: admin -> normalTL, pauser -> emergencyTL");
        }

        // ── Rollup + NitroVerifier (L1 only) ──
        if (keccak256(bytes(layer)) == keccak256("l1")) {
            address rollup = _readAddr(manifest, "rollup");
            address nitroVerifier = _readAddr(manifest, "nitro_verifier");

            if (rollup != address(0)) {
                IAccessControl(rollup).grantRole(DEFAULT_ADMIN_ROLE, normalTL);
                IAccessControl(rollup).grantRole(EMERGENCY_ROLE, emergencyTL);
                console2.log("  Rollup: admin -> normalTL, emergency -> emergencyTL");
            }
            if (nitroVerifier != address(0)) {
                IAccessControl(nitroVerifier).grantRole(DEFAULT_ADMIN_ROLE, normalTL);
                console2.log("  NitroVerifier: admin -> normalTL");
            }
        }

        // ── Ownable2Step contracts → normal timelock ──
        _transferOwnership2Step(erc20Gateway, normalTL, "ERC20Gateway");
        _transferOwnership2Step(nativeGateway, normalTL, "NativeGateway");
        _transferOwnership2Step(factory, normalTL, "Factory");

        // ── Ownable oracles (L2 only) → normal timelock ──
        if (keccak256(bytes(layer)) == keccak256("l2")) {
            address oracle = _readAddr(manifest, "l1_block_oracle");
            if (oracle != address(0)) {
                Ownable(oracle).transferOwnership(normalTL);
                console2.log("  L1BlockOracle: owner -> normalTL");
            }
        }

        // ── Accept ownerships via timelock (minDelay=0) ──
        _acceptViaTimelock(normalTL, erc20Gateway);
        _acceptViaTimelock(normalTL, nativeGateway);
        _acceptViaTimelock(normalTL, factory);

        // ── Set target delays ──
        _setDelay(normalTL, normalDelay);
        _setDelay(emergencyTL, emergencyDelay);
        console2.log("  Delays set: normal=%d, emergency=%d", normalDelay, emergencyDelay);

        // ── Renounce EOA admin (LAST) ──
        if (bridge != address(0)) {
            IAccessControl(bridge).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        if (keccak256(bytes(layer)) == keccak256("l1")) {
            address rollup = _readAddr(manifest, "rollup");
            address nitroVerifier = _readAddr(manifest, "nitro_verifier");
            if (rollup != address(0)) IAccessControl(rollup).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
            if (nitroVerifier != address(0)) IAccessControl(nitroVerifier).renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        console2.log("  EOA admin renounced");

        vm.stopBroadcast();
    }

    function _transferOwnership2Step(address target, address newOwner, string memory name) internal {
        if (target == address(0)) return;
        Ownable2Step(target).transferOwnership(newOwner);
        console2.log("  %s: ownership transfer initiated", name);
    }

    function _acceptViaTimelock(address timelock, address target) internal {
        if (target == address(0)) return;
        FluentTimeLock tl = FluentTimeLock(payable(timelock));
        bytes memory data = abi.encodeCall(Ownable2Step.acceptOwnership, ());
        tl.schedule(target, 0, data, bytes32(0), bytes32(0), 0);
        tl.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    function _setDelay(address timelock, uint256 delay) internal {
        FluentTimeLock tl = FluentTimeLock(payable(timelock));
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (delay));
        tl.schedule(address(tl), 0, data, bytes32(0), bytes32(0), 0);
        tl.execute(address(tl), 0, data, bytes32(0), bytes32(0));
    }
}
