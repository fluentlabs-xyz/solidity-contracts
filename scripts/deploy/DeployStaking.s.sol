// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FluentGovernance} from "../../contracts/governance/FluentGovernance.sol";
import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {BLS12381Verifier} from "../../contracts/libraries/BLS12381Verifier.sol";
import {SimplexEvidenceDecoder} from "../../contracts/libraries/SimplexEvidenceDecoder.sol";
import {LivenessSlashing} from "../../contracts/staking/LivenessSlashing.sol";
import {BlendReserve} from "../../contracts/staking/BlendReserve.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
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
        address systemReward;
        address systemRewardImpl;
        address stakingPool;
        address stakingPoolImpl;
        address chainConfig;
        address chainConfigImpl;
        address governance;
        address governanceImpl;
        address livenessSlashing;
        address livenessSlashingImpl;
        address blendReserve;
        address blendReserveImpl;
        address blsVerifier;
        address evidenceDecoder;
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
        uint32 felonyThreshold;
        uint32 validatorJailEpochLength;
        uint32 undelegatePeriod;
        uint256 minValidatorStakeAmount;
        uint256 minStakingAmount;
        uint64 dposActivationBlock;
        uint256 minUndelegateBlocks;
        IERC20 stakingToken;
    }

    function _readStakingParams() internal view returns (StakingDeployParams memory p) {
        (, string memory json) = _readActiveConfig();
        p.initialOwner = vm.envOr("INITIAL_OWNER", json.readAddress(".roles.initialOwner"));
        // The initial validator set may be overridden via env (comma-delimited), the same
        // pattern as INITIAL_OWNER/STAKING_TOKEN, so a devnet (e.g. the production-soak) can
        // deploy with a narrower initial committee — leaving the remaining validators
        // UNregistered for a runtime register→activate join — without forking this shared
        // config file. Absent ⇒ the JSON config (unchanged for the production-path).
        p.initialValidators = vm.envOr("INITIAL_VALIDATORS", ",", json.readAddressArray(".staking.initialValidators"));
        p.initialStakes = vm.envOr("INITIAL_STAKES", ",", json.readUintArray(".staking.initialStakes"));
        p.initialCommissionRate = uint16(json.readUint(".staking.initialCommissionRate"));
        p.systemRewardAccounts = json.readAddressArray(".staking.systemReward.accounts");
        p.systemRewardShares = _toUint16Array(json.readUintArray(".staking.systemReward.shares"));
        p.governanceVotingPeriod = uint32(json.readUint(".governance.votingPeriod"));
        p.activeValidatorsLength =
            uint32(vm.envOr("ACTIVE_VALIDATORS_LENGTH", json.readUint(".staking.activeValidatorsLength")));
        p.epochBlockInterval = uint32(json.readUint(".staking.epochBlockInterval"));
        p.felonyThreshold = uint32(json.readUint(".staking.felonyThreshold"));
        p.validatorJailEpochLength = uint32(json.readUint(".staking.validatorJailEpochLength"));
        p.undelegatePeriod = uint32(json.readUint(".staking.undelegatePeriod"));
        p.minValidatorStakeAmount = json.readUint(".staking.minValidatorStakeAmount");
        p.minStakingAmount = json.readUint(".staking.minStakingAmount");
        // Optional: absent ⇒ 0 ⇒ absolute epoch numbering (set later via governance at migration).
        p.minUndelegateBlocks =
            vm.keyExistsJson(json, ".staking.minUndelegateBlocks") ? json.readUint(".staking.minUndelegateBlocks") : 0;
        // A non-zero activation block MUST be a multiple of epochBlockInterval (86400 on mainnet/testnet)
        // so absolute and relative epoch boundaries coincide; ChainConfig.initialize asserts this. Absent
        // ⇒ 0 (trivially aligned; absolute numbering until governance sets it at migration).
        p.dposActivationBlock = vm.keyExistsJson(json, ".staking.dposActivationBlock")
            ? uint64(json.readUint(".staking.dposActivationBlock"))
            : 0;
        p.stakingToken = IERC20(vm.envOr("STAKING_TOKEN", json.readAddress(".staking.token")));

        require(p.initialValidators.length == p.initialStakes.length, "staking initial validators/stakes mismatch");
        require(p.systemRewardAccounts.length == p.systemRewardShares.length, "system reward accounts/shares mismatch");

        // Windowed participation model: the participation-floor jail fires on the FIRST
        // below-floor epoch (no grace). `slashesCount` is per-epoch (max 1 strike) and never
        // carried forward, so `felonyThreshold > 1` is UNREACHABLE — only 1 is meaningful. The
        // old `felony <= interval/50` arithmetic assumed 50 CONSECUTIVE misses per dispatch and
        // is meaningless under the windowed model.
        require(p.felonyThreshold == 1, "felony threshold must be 1 (per-epoch participation strike; >1 unreachable)");
        require(p.validatorJailEpochLength >= 1, "jail epoch length must be >= 1");
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
        // Nonce slots after SlashingIndicator removal:
        // +2 staking, +4 systemReward, +6 stakingPool, +8 chainConfig,
        // +10 governance, +12 livenessSlashing.
        //
        // `Staking` is DELEGATECALL-linked to the `StakingDpos` library. Forge
        // auto-deploys that library through the deterministic CREATE2 deployer
        // (0x4e59...), NOT a CREATE from `tx.origin`, so it consumes no slot in
        // this sequence — these offsets are unchanged by the link. Do not bump
        // them for the library.
        //
        // F4 (GENESIS REQUIREMENT — no on-chain probe by decision): a DELEGATECALL to a code-less
        // address SUCCEEDS with empty returndata, so an absent linked library makes settleEpochStipend /
        // slashEquivocation* a SILENT no-op. Forge links them here, but the fluentbase `bootstrap.rs`
        // genesis MUST predeploy the linked libraries — StakingDpos, StakingRewards, StakingEconomics —
        // at the addresses Staking/StakingRewards are linked against. This is a documented handoff
        // invariant, verified by the fluentbase genesis integration test (see the handoff report).
        //
        // Equivocation-slashing crypto units: both are stateless with no constructor args.
        // Deployed BEFORE the nonce snapshot below so the proxy-address predictions
        // (nonce+2..+12) are unaffected, and wired into ChainConfig's initializer so
        // equivocation slashing is live at genesis. The `setBlsVerifier`/`setEvidenceDecoder`
        // setters are `onlyFromGovernance` and cannot run inside this broadcast, so genesis
        // seeding via `initialize` is the only deploy-time wiring path.
        r.blsVerifier = address(new BLS12381Verifier());
        r.evidenceDecoder = address(new SimplexEvidenceDecoder());

        uint64 nonce = vm.getNonce(tx.origin);
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(tx.origin, nonce + 2));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(tx.origin, nonce + 4));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(tx.origin, nonce + 6));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(tx.origin, nonce + 8));
        IFluentGovernance governance = IFluentGovernance(vm.computeCreateAddress(tx.origin, nonce + 10));
        address predictedLivenessSlashing = vm.computeCreateAddress(tx.origin, nonce + 12);
        // BlendReserve (nonce+14) predeploy — deployed + wired below. Settlement is folded into
        // Staking (no RewardRouter predeploy): Staking draws the stipend from BlendReserve, and
        // BlendReserve gates `disburse` to the Staking proxy — a mutual address dependency both
        // sides resolve via the pre-computed nonce predictions.
        address predictedBlendReserve = vm.computeCreateAddress(tx.origin, nonce + 14);

        uint256 totalInitialStakes = _sum(p.initialStakes);
        if (totalInitialStakes > 0) {
            p.stakingToken.approve(address(predictedStaking), totalInitialStakes);
        }

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            p.stakingToken,
            predictedLivenessSlashing,
            predictedBlendReserve
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

        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking,
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
                        p.felonyThreshold,
                        p.validatorJailEpochLength,
                        p.undelegatePeriod,
                        p.minValidatorStakeAmount,
                        p.minStakingAmount,
                        p.dposActivationBlock,
                        r.blsVerifier,
                        r.evidenceDecoder,
                        p.minUndelegateBlocks
                    )
                )
            )
        );
        r.chainConfigImpl = address(chainConfigImpl);

        // Loud fail if equivocation slashing would be dead on this deploy: the
        // NotConfigured guards in StakingDpos revert every slash while these are unset.
        require(
            IChainConfig(r.chainConfig).getBlsVerifier() == r.blsVerifier, "bls verifier not wired into chain config"
        );
        require(
            IChainConfig(r.chainConfig).getEvidenceDecoder() == r.evidenceDecoder,
            "evidence decoder not wired into chain config"
        );

        require(r.staking == address(predictedStaking), "staking proxy prediction mismatch");
        require(r.systemReward == address(predictedSystemReward), "system reward proxy prediction mismatch");
        require(r.stakingPool == address(predictedStakingPool), "staking pool proxy prediction mismatch");
        require(r.chainConfig == address(predictedChainConfig), "chain config proxy prediction mismatch");

        // F10: the per-epoch stipend share and the `totalBlendRewards` accumulator are both uint96, so the
        // MAX stipend cap MUST fit uint96 or a share cast could truncate. Couple the bound to the type — this
        // fails the deploy if ChainConfig's cap is ever raised past uint96.
        require(
            ChainConfig(r.chainConfig).MAX_BLEND_STIPEND_PER_EPOCH() <= type(uint96).max,
            "MAX_BLEND_STIPEND_PER_EPOCH exceeds uint96 (stipend cast would truncate)"
        );

        FluentGovernance governanceImpl = new FluentGovernance(predictedStaking, predictedChainConfig);
        r.governance = address(
            new ERC1967Proxy(
                address(governanceImpl),
                abi.encodeCall(FluentGovernance.initialize, (p.initialOwner, p.governanceVotingPeriod))
            )
        );
        r.governanceImpl = address(governanceImpl);
        require(r.governance == address(governance), "governance proxy prediction mismatch");

        LivenessSlashing livenessSlashingImpl = new LivenessSlashing(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            p.stakingToken
        );
        r.livenessSlashing = address(
            new ERC1967Proxy(
                address(livenessSlashingImpl), abi.encodeCall(LivenessSlashing.initialize, (p.initialOwner))
            )
        );
        r.livenessSlashingImpl = address(livenessSlashingImpl);
        require(r.livenessSlashing == predictedLivenessSlashing, "liveness slashing proxy prediction mismatch");

        // Fixed-supply-BLEND deploy-assert (G9): reject a staking token that exposes a callable open
        // mint (e.g. MockBlendToken). Reward emission MUST be reallocation from a finite pool.
        _assertFixedSupplyToken(address(p.stakingToken));

        // BlendReserve predeploy (nonce+13 impl, nonce+14 proxy). Its `disburse` caller gate is the
        // Staking proxy (settlement is folded into Staking).
        BlendReserve blendReserveImpl = new BlendReserve(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            p.stakingToken,
            address(predictedStaking)
        );
        r.blendReserve = address(
            new ERC1967Proxy(address(blendReserveImpl), abi.encodeCall(BlendReserve.initialize, (p.initialOwner)))
        );
        r.blendReserveImpl = address(blendReserveImpl);
        require(r.blendReserve == predictedBlendReserve, "blend reserve proxy prediction mismatch");

        // Wiring read-back: Staking draws the stipend from the reserve; the reserve gates disburse on
        // the Staking proxy. (Immutables aren't externally readable, so the prediction asserts above are
        // the byte-for-byte guarantee; in production `bootstrap.rs` must mirror these addrs.)
        require(BlendReserve(r.blendReserve).getStakingToken() == p.stakingToken, "reserve token mismatch");

        // Optional genesis-fund: transfer B_total to the reserve if the deployer holds BLEND and a
        // non-zero amount is configured. In production this is a seeded genesis balance (bootstrap.rs).
        uint256 reserveGenesis = vm.envOr("BLEND_RESERVE_GENESIS", uint256(0));
        if (reserveGenesis > 0) {
            p.stakingToken.transfer(r.blendReserve, reserveGenesis);
            require(
                BlendReserve(r.blendReserve).reserveBalance() == reserveGenesis, "reserve genesis-fund read-back failed"
            );
        }
    }

    /// @dev G9 hard gate (F5): the staking token MUST be the canonical fixed-supply BLEND, pinned by
    ///      ADDRESS (a positive identity proof, not the old `mint()`-revert inference which is a
    ///      false-negative sieve — access-gated / differently-signatured mints passed it while remaining
    ///      inflatable). Production BLEND is an immutable, keys-thrown-away predeploy, so an address pin is
    ///      sufficient (no codehash / supply-invariance / mint-probe). `EXPECTED_BLEND` comes from
    ///      per-network config (`.staking.expectedBlend`) or env, and MUST be byte-parity with fluentbase
    ///      `bootstrap.rs`. Enforced ONLY when set (production); unset/zero on local/devnet ⇒ skipped (the
    ///      intentionally-mintable mock BLEND is fine, and the fluentbase soak needs no fixed-supply mock).
    function _assertFixedSupplyToken(address token) internal view {
        address expectedBlend = _expectedBlend();
        if (expectedBlend == address(0)) return; // local/devnet: no canonical BLEND pinned → skip
        require(token == expectedBlend, "STAKING_TOKEN is not the canonical fixed-supply BLEND (EXPECTED_BLEND)");
    }

    /// @dev The canonical BLEND identity for the active network: env `EXPECTED_BLEND` (highest precedence,
    ///      for CI/soak parity with `bootstrap.rs`) else the config's `.staking.expectedBlend`. Absent on
    ///      local/devnet ⇒ address(0) ⇒ the G9 gate is skipped.
    function _expectedBlend() internal view returns (address expected) {
        (, string memory json) = _readActiveConfig();
        if (vm.keyExistsJson(json, ".staking.expectedBlend")) {
            expected = json.readAddress(".staking.expectedBlend");
        }
        expected = vm.envOr("EXPECTED_BLEND", expected);
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

        vm.startBroadcast(vm.envOr("DEPLOYER", address(0x390a4CEdBb65be7511D9E1a35b115376F39DbDF3)));
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
        console2.log("SystemReward deployed:", r.systemReward);
        console2.log("  impl:", r.systemRewardImpl);
        console2.log("StakingPool deployed:", r.stakingPool);
        console2.log("  impl:", r.stakingPoolImpl);
        console2.log("ChainConfig deployed:", r.chainConfig);
        console2.log("  impl:", r.chainConfigImpl);
        console2.log("Governance deployed:", r.governance);
        console2.log("  impl:", r.governanceImpl);
        console2.log("LivenessSlashing deployed:", r.livenessSlashing);
        console2.log("  impl:", r.livenessSlashingImpl);
        console2.log("BlendReserve deployed:", r.blendReserve);
        console2.log("  impl:", r.blendReserveImpl);
        console2.log("BLS12381Verifier deployed:", r.blsVerifier);
        console2.log("SimplexEvidenceDecoder deployed:", r.evidenceDecoder);
    }

    function _writeDeployment(StakingDeployment memory r, string memory outputPath) internal {
        string memory out = vm.serializeAddress("deployment", "staking", r.staking);
        out = vm.serializeAddress("deployment", "staking_impl", r.stakingImpl);
        out = vm.serializeAddress("deployment", "system_reward", r.systemReward);
        out = vm.serializeAddress("deployment", "system_reward_impl", r.systemRewardImpl);
        out = vm.serializeAddress("deployment", "staking_pool", r.stakingPool);
        out = vm.serializeAddress("deployment", "staking_pool_impl", r.stakingPoolImpl);
        out = vm.serializeAddress("deployment", "chain_config", r.chainConfig);
        out = vm.serializeAddress("deployment", "chain_config_impl", r.chainConfigImpl);
        out = vm.serializeAddress("deployment", "governance", r.governance);
        out = vm.serializeAddress("deployment", "governance_impl", r.governanceImpl);
        out = vm.serializeAddress("deployment", "liveness_slashing", r.livenessSlashing);
        out = vm.serializeAddress("deployment", "liveness_slashing_impl", r.livenessSlashingImpl);
        out = vm.serializeAddress("deployment", "blend_reserve", r.blendReserve);
        out = vm.serializeAddress("deployment", "blend_reserve_impl", r.blendReserveImpl);
        out = vm.serializeAddress("deployment", "bls_verifier", r.blsVerifier);
        out = vm.serializeAddress("deployment", "evidence_decoder", r.evidenceDecoder);
        vm.writeJson(out, outputPath);
    }
}
