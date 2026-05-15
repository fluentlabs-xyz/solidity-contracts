// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockStaking} from "../../contracts/staking/mocks/MockStaking.sol";
import {MockSystemReward} from "../../contracts/staking/mocks/MockSystemReward.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {ISlashingIndicator} from "../../contracts/staking/interfaces/ISlashingIndicator.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

/// @notice Replaces deployed L2 staking module implementations with test mock implementations.
/// @dev Reads the staking manifest from deployments/<env>/staking.json by default.
///      Env:
///        CHAIN=L2_TESTNET|L2_MAINNET (default: L2_TESTNET)
///        STAKING_MANIFEST=<path> (optional)
///        UPDATE_STAKING_MANIFEST=true (optional; writes new impl addresses)
contract ReplaceStakingWithMocks is Script {
    using stdJson for string;

    struct StakingAddresses {
        address staking;
        address stakingImpl;
        address slashingIndicator;
        address slashingIndicatorImpl;
        address systemReward;
        address systemRewardImpl;
        address stakingPool;
        address stakingPoolImpl;
        address chainConfig;
        address chainConfigImpl;
        address governance;
        address governanceImpl;
    }

    function run() external {
        (string memory envName, string memory network) = _activeL2Network();
        string memory configPath = string.concat("scripts/config/", network, ".json");
        string memory config = vm.readFile(configPath);
        require(block.chainid == config.readUint(".chainId"), "wrong RPC: block.chainid != config chainId");

        string memory manifestPath =
            vm.envOr("STAKING_MANIFEST", string.concat("deployments/", envName, "/staking.json"));
        string memory manifest = vm.readFile(manifestPath);
        StakingAddresses memory a = _readStakingAddresses(manifest);
        IERC20 stakingToken = IERC20(config.readAddress(".staking.token"));

        _assertHasCode(a.staking, "staking proxy");
        _assertHasCode(a.systemReward, "system reward proxy");
        _assertHasCode(a.slashingIndicator, "slashing indicator proxy");
        _assertHasCode(a.stakingPool, "staking pool proxy");
        _assertHasCode(a.chainConfig, "chain config proxy");
        _assertHasCode(a.governance, "governance proxy");

        console2.log("Replacing staking implementations with mocks");
        console2.log("  network:", network);
        console2.log("  manifest:", manifestPath);
        console2.log("  staking proxy:", a.staking);
        console2.log("  system reward proxy:", a.systemReward);
        console2.log("  staking token:", address(stakingToken));

        vm.startBroadcast();

        MockStaking mockStaking = new MockStaking(
            IStaking(a.staking),
            ISlashingIndicator(a.slashingIndicator),
            ISystemReward(a.systemReward),
            IStakingPool(a.stakingPool),
            IFluentGovernance(a.governance),
            IChainConfig(a.chainConfig),
            stakingToken
        );
        _upgradeToAndCall(a.staking, address(mockStaking));

        MockSystemReward mockSystemReward = new MockSystemReward(
            IStaking(a.staking),
            ISlashingIndicator(a.slashingIndicator),
            ISystemReward(a.systemReward),
            IStakingPool(a.stakingPool),
            IFluentGovernance(a.governance),
            IChainConfig(a.chainConfig),
            stakingToken
        );
        _upgradeToAndCall(a.systemReward, address(mockSystemReward));

        vm.stopBroadcast();

        a.stakingImpl = address(mockStaking);
        a.systemRewardImpl = address(mockSystemReward);

        console2.log("MockStaking impl:", a.stakingImpl);
        console2.log("MockSystemReward impl:", a.systemRewardImpl);

        if (vm.envOr("UPDATE_STAKING_MANIFEST", false)) {
            _writeStakingAddresses(a, manifestPath);
            console2.log("Updated manifest:", manifestPath);
        }
    }

    function _activeL2Network() internal view returns (string memory envName, string memory network) {
        string memory chain = vm.envOr("CHAIN", string("L2_TESTNET"));
        bytes32 h = keccak256(bytes(chain));
        if (h == keccak256("L2_TESTNET")) return ("testnet", "testnet/l2");
        if (h == keccak256("L2_MAINNET")) return ("mainnet", "mainnet/l2");
        revert(string.concat("Unsupported CHAIN for staking mock replacement: ", chain));
    }

    function _readStakingAddresses(string memory json) internal pure returns (StakingAddresses memory a) {
        a.staking = json.readAddress(".staking");
        a.stakingImpl = json.readAddress(".staking_impl");
        a.slashingIndicator = json.readAddress(".slashing_indicator");
        a.slashingIndicatorImpl = json.readAddress(".slashing_indicator_impl");
        a.systemReward = json.readAddress(".system_reward");
        a.systemRewardImpl = json.readAddress(".system_reward_impl");
        a.stakingPool = json.readAddress(".staking_pool");
        a.stakingPoolImpl = json.readAddress(".staking_pool_impl");
        a.chainConfig = json.readAddress(".chain_config");
        a.chainConfigImpl = json.readAddress(".chain_config_impl");
        a.governance = json.readAddress(".governance");
        a.governanceImpl = json.readAddress(".governance_impl");
    }

    function _upgradeToAndCall(address proxy, address implementation) internal {
        require(implementation.code.length != 0, "implementation has no code");
        (bool ok, bytes memory data) =
            proxy.call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implementation, ""));
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    function _assertHasCode(address target, string memory label) internal view {
        require(target != address(0), string.concat(label, " is zero"));
        require(target.code.length != 0, string.concat(label, " has no code"));
    }

    function _writeStakingAddresses(StakingAddresses memory a, string memory outputPath) internal {
        string memory out = vm.serializeAddress("stakingDeployment", "staking", a.staking);
        out = vm.serializeAddress("stakingDeployment", "staking_impl", a.stakingImpl);
        out = vm.serializeAddress("stakingDeployment", "slashing_indicator", a.slashingIndicator);
        out = vm.serializeAddress("stakingDeployment", "slashing_indicator_impl", a.slashingIndicatorImpl);
        out = vm.serializeAddress("stakingDeployment", "system_reward", a.systemReward);
        out = vm.serializeAddress("stakingDeployment", "system_reward_impl", a.systemRewardImpl);
        out = vm.serializeAddress("stakingDeployment", "staking_pool", a.stakingPool);
        out = vm.serializeAddress("stakingDeployment", "staking_pool_impl", a.stakingPoolImpl);
        out = vm.serializeAddress("stakingDeployment", "chain_config", a.chainConfig);
        out = vm.serializeAddress("stakingDeployment", "chain_config_impl", a.chainConfigImpl);
        out = vm.serializeAddress("stakingDeployment", "governance", a.governance);
        out = vm.serializeAddress("stakingDeployment", "governance_impl", a.governanceImpl);
        vm.writeJson(out, outputPath);
    }
}
