// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {SlashingIndicator} from "../../contracts/staking/SlashingIndicator.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IGovernance} from "../../contracts/staking/interfaces/IGovernance.sol";
import {ISlashingIndicator} from "../../contracts/staking/interfaces/ISlashingIndicator.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";
import {DeployBase} from "./DeployBase.s.sol";

/// @notice Deploys the staking module behind UUPS-compatible ERC1967 proxies.
/// @dev Shared module dependencies are immutable constructor args on each implementation, so this script
///      predicts all proxy addresses first, deploys implementations with those proxy addresses, and then
///      deploys each ERC1967 proxy with its initializer calldata. `INITIAL_OWNER` owns every proxy and can
///      authorize future UUPS upgrades through `upgradeToAndCall`.
contract DeployStaking is DeployBase {
    using stdJson for string;

    struct StakingDeployment {
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
    }

    struct StakingDeployParams {
        address initialOwner;
        address governance;
        address systemRewardAccount;
        uint32 activeValidatorsLength;
        uint32 epochBlockInterval;
        uint32 misdemeanorThreshold;
        uint32 felonyThreshold;
        uint32 validatorJailEpochLength;
        uint32 undelegatePeriod;
        uint256 minValidatorStakeAmount;
        uint256 minStakingAmount;
    }

    function _readStakingParams() internal view returns (StakingDeployParams memory p) {
        string memory json = _readConfig(vm.envOr("NETWORK", string("testnet/l2")));
        p.initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        p.governance = vm.envOr("STAKING_GOVERNANCE", p.initialOwner);
        p.systemRewardAccount = vm.envOr("SYSTEM_REWARD_ACCOUNT", p.initialOwner);
        p.activeValidatorsLength = uint32(vm.envOr("STAKING_ACTIVE_VALIDATORS", uint256(21)));
        p.epochBlockInterval = uint32(vm.envOr("STAKING_EPOCH_BLOCK_INTERVAL", uint256(200)));
        p.misdemeanorThreshold = uint32(vm.envOr("STAKING_MISDEMEANOR_THRESHOLD", uint256(50)));
        p.felonyThreshold = uint32(vm.envOr("STAKING_FELONY_THRESHOLD", uint256(150)));
        p.validatorJailEpochLength = uint32(vm.envOr("STAKING_VALIDATOR_JAIL_EPOCH_LENGTH", uint256(7)));
        p.undelegatePeriod = uint32(vm.envOr("STAKING_UNDELEGATE_PERIOD", uint256(0)));
        p.minValidatorStakeAmount = vm.envOr("STAKING_MIN_VALIDATOR_STAKE", uint256(1 ether));
        p.minStakingAmount = vm.envOr("STAKING_MIN_STAKE", uint256(1 ether));
    }

    function _deployStaking(StakingDeployParams memory p) internal returns (StakingDeployment memory r) {
        uint64 nonce = vm.getNonce(tx.origin);
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(tx.origin, nonce + 1));
        ISlashingIndicator predictedSlashingIndicator =
            ISlashingIndicator(vm.computeCreateAddress(tx.origin, nonce + 3));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(tx.origin, nonce + 5));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(tx.origin, nonce + 7));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(tx.origin, nonce + 9));
        IGovernance governance = IGovernance(p.governance);

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig
        );
        address[] memory validators = new address[](0);
        uint256[] memory initialStakes = new uint256[](0);
        r.staking = address(
            new ERC1967Proxy(
                address(stakingImpl),
                abi.encodeCall(Staking.initialize, (p.initialOwner, validators, initialStakes, uint16(0)))
            )
        );
        r.stakingImpl = address(stakingImpl);

        SlashingIndicator slashingIndicatorImpl = new SlashingIndicator(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig
        );
        r.slashingIndicator = address(
            new ERC1967Proxy(
                address(slashingIndicatorImpl), abi.encodeCall(SlashingIndicator.initialize, (p.initialOwner))
            )
        );
        r.slashingIndicatorImpl = address(slashingIndicatorImpl);

        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig
        );
        address[] memory rewardAccounts = new address[](1);
        rewardAccounts[0] = p.systemRewardAccount;
        uint16[] memory rewardShares = new uint16[](1);
        rewardShares[0] = 10_000;
        r.systemReward = address(
            new ERC1967Proxy(
                address(systemRewardImpl),
                abi.encodeCall(SystemReward.initialize, (p.initialOwner, rewardAccounts, rewardShares))
            )
        );
        r.systemRewardImpl = address(systemRewardImpl);

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig
        );
        r.stakingPool = address(
            new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (p.initialOwner)))
        );
        r.stakingPoolImpl = address(stakingPoolImpl);

        ChainConfig chainConfigImpl = new ChainConfig(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig
        );
        r.chainConfig = address(
            new ERC1967Proxy(
                address(chainConfigImpl),
                abi.encodeCall(
                    ChainConfig.initialize,
                    (
                        p.initialOwner,
                        p.activeValidatorsLength,
                        p.epochBlockInterval,
                        p.misdemeanorThreshold,
                        p.felonyThreshold,
                        p.validatorJailEpochLength,
                        p.undelegatePeriod,
                        p.minValidatorStakeAmount,
                        p.minStakingAmount
                    )
                )
            )
        );
        r.chainConfigImpl = address(chainConfigImpl);

        require(r.staking == address(predictedStaking), "staking proxy prediction mismatch");
        require(r.slashingIndicator == address(predictedSlashingIndicator), "slashing proxy prediction mismatch");
        require(r.systemReward == address(predictedSystemReward), "system reward proxy prediction mismatch");
        require(r.stakingPool == address(predictedStakingPool), "staking pool proxy prediction mismatch");
        require(r.chainConfig == address(predictedChainConfig), "chain config proxy prediction mismatch");
    }

    function run() external {
        StakingDeployParams memory p = _readStakingParams();
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying staking module");
        console2.log("  owner:", p.initialOwner);
        console2.log("  governance:", p.governance);
        console2.log("  system reward account:", p.systemRewardAccount);

        vm.startBroadcast();
        StakingDeployment memory r = _deployStaking(p);
        vm.stopBroadcast();

        _logDeployment(r);
        if (bytes(outputPath).length != 0) {
            _writeDeployment(r, outputPath);
        }
    }

    function _logDeployment(StakingDeployment memory r) internal pure {
        console2.log("Staking deployed:", r.staking);
        console2.log("  impl:", r.stakingImpl);
        console2.log("SlashingIndicator deployed:", r.slashingIndicator);
        console2.log("  impl:", r.slashingIndicatorImpl);
        console2.log("SystemReward deployed:", r.systemReward);
        console2.log("  impl:", r.systemRewardImpl);
        console2.log("StakingPool deployed:", r.stakingPool);
        console2.log("  impl:", r.stakingPoolImpl);
        console2.log("ChainConfig deployed:", r.chainConfig);
        console2.log("  impl:", r.chainConfigImpl);
    }

    function _writeDeployment(StakingDeployment memory r, string memory outputPath) internal {
        string memory out = vm.serializeAddress("deployment", "staking", r.staking);
        out = vm.serializeAddress("deployment", "staking_impl", r.stakingImpl);
        out = vm.serializeAddress("deployment", "slashing_indicator", r.slashingIndicator);
        out = vm.serializeAddress("deployment", "slashing_indicator_impl", r.slashingIndicatorImpl);
        out = vm.serializeAddress("deployment", "system_reward", r.systemReward);
        out = vm.serializeAddress("deployment", "system_reward_impl", r.systemRewardImpl);
        out = vm.serializeAddress("deployment", "staking_pool", r.stakingPool);
        out = vm.serializeAddress("deployment", "staking_pool_impl", r.stakingPoolImpl);
        out = vm.serializeAddress("deployment", "chain_config", r.chainConfig);
        out = vm.serializeAddress("deployment", "chain_config_impl", r.chainConfigImpl);
        vm.writeJson(out, outputPath);
    }
}
