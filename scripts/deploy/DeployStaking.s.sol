// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Governance} from "../../contracts/governance/Governance.sol";
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
        address governance;
        address governanceImpl;
    }

    struct StakingDeployParams {
        address initialOwner;
        address[] initialValidators;
        uint256[] initialStakes;
        uint16 initialCommissionRate;
        address[] systemRewardAccounts;
        uint16[] systemRewardShares;
        uint32 governanceVotingPeriod;
        uint32 activeValidatorsLength;
        uint32 epochBlockInterval;
        uint32 misdemeanorThreshold;
        uint32 felonyThreshold;
        uint32 validatorJailEpochLength;
        uint32 undelegatePeriod;
        uint256 minValidatorStakeAmount;
        uint256 minStakingAmount;
        IERC20 stakingToken;
    }

    function _readStakingParams() internal view returns (StakingDeployParams memory p) {
        (, string memory json) = _readActiveConfig();
        p.initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        p.initialValidators = json.readAddressArray(".staking.initialValidators");
        p.initialStakes = json.readUintArray(".staking.initialStakes");
        p.initialCommissionRate = uint16(json.readUint(".staking.initialCommissionRate"));
        p.systemRewardAccounts = json.readAddressArray(".staking.systemReward.accounts");
        p.systemRewardShares = _toUint16Array(json.readUintArray(".staking.systemReward.shares"));
        p.governanceVotingPeriod = uint32(json.readUint(".governance.votingPeriod"));
        p.activeValidatorsLength = uint32(json.readUint(".staking.activeValidatorsLength"));
        p.epochBlockInterval = uint32(json.readUint(".staking.epochBlockInterval"));
        p.misdemeanorThreshold = uint32(json.readUint(".staking.misdemeanorThreshold"));
        p.felonyThreshold = uint32(json.readUint(".staking.felonyThreshold"));
        p.validatorJailEpochLength = uint32(json.readUint(".staking.validatorJailEpochLength"));
        p.undelegatePeriod = uint32(json.readUint(".staking.undelegatePeriod"));
        p.minValidatorStakeAmount = json.readUint(".staking.minValidatorStakeAmount");
        p.minStakingAmount = json.readUint(".staking.minStakingAmount");
        p.stakingToken = IERC20(vm.envOr("STAKING_TOKEN", json.readAddress(".staking.token")));

        require(p.initialValidators.length == p.initialStakes.length, "staking initial validators/stakes mismatch");
        require(p.systemRewardAccounts.length == p.systemRewardShares.length, "system reward accounts/shares mismatch");
    }

    function _toUint16Array(uint256[] memory values) internal pure returns (uint16[] memory out) {
        out = new uint16[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            require(values[i] <= type(uint16).max, "uint16 overflow");
            out[i] = uint16(values[i]);
        }
    }

    function _sum(uint256[] memory values) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < values.length; i++) {
            total += values[i];
        }
    }

    function _deployStaking(StakingDeployParams memory p) internal returns (StakingDeployment memory r) {
        uint64 nonce = vm.getNonce(tx.origin);
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(tx.origin, nonce + 1));
        ISlashingIndicator predictedSlashingIndicator =
            ISlashingIndicator(vm.computeCreateAddress(tx.origin, nonce + 3));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(tx.origin, nonce + 5));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(tx.origin, nonce + 7));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(tx.origin, nonce + 9));
        IGovernance governance = IGovernance(vm.computeCreateAddress(tx.origin, nonce + 11));

        uint256 totalInitialStakes = _sum(p.initialStakes);
        if (totalInitialStakes > 0) {
            p.stakingToken.approve(address(predictedStaking), totalInitialStakes);
        }

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            p.stakingToken
        );
        r.staking = address(
            new ERC1967Proxy(
                address(stakingImpl),
                abi.encodeCall(
                    Staking.initialize, (p.initialOwner, p.initialValidators, p.initialStakes, p.initialCommissionRate)
                )
            )
        );
        r.stakingImpl = address(stakingImpl);

        SlashingIndicator slashingIndicatorImpl = new SlashingIndicator(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            p.stakingToken
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
            predictedChainConfig,
            p.stakingToken
        );
        r.systemReward = address(
            new ERC1967Proxy(
                address(systemRewardImpl),
                abi.encodeCall(SystemReward.initialize, (p.initialOwner, p.systemRewardAccounts, p.systemRewardShares))
            )
        );
        r.systemRewardImpl = address(systemRewardImpl);

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking,
            predictedSlashingIndicator,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            p.stakingToken
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
            predictedChainConfig,
            p.stakingToken
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

        Governance governanceImpl = new Governance(predictedStaking, predictedChainConfig);
        r.governance = address(
            new ERC1967Proxy(
                address(governanceImpl),
                abi.encodeCall(Governance.initialize, (p.initialOwner, p.governanceVotingPeriod))
            )
        );
        r.governanceImpl = address(governanceImpl);
        require(r.governance == address(governance), "governance proxy prediction mismatch");
    }

    function run() external {
        TargetChain memory chain = _activeChain();
        StakingDeployParams memory p = _readStakingParams();
        string memory outputPath = vm.envOr("OUTPUT_PATH", string(""));

        console2.log("Deploying staking module");
        console2.log("  chain:", chain.chain);
        console2.log("  network:", chain.network);
        console2.log("  owner:", p.initialOwner);
        console2.log("  governance voting period:", p.governanceVotingPeriod);
        console2.log("  initial validators:", p.initialValidators.length);
        console2.log("  system reward accounts:", p.systemRewardAccounts.length);
        console2.log("  staking token:", address(p.stakingToken));

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
        console2.log("Governance deployed:", r.governance);
        console2.log("  impl:", r.governanceImpl);
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
        out = vm.serializeAddress("deployment", "governance", r.governance);
        out = vm.serializeAddress("deployment", "governance_impl", r.governanceImpl);
        vm.writeJson(out, outputPath);
    }
}
