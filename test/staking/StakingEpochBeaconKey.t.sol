// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {SYSTEM_CALLER} from "../../contracts/staking/StakingContext.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

/// @title Per-epoch randomness-beacon group-key (`PK_epoch`) commit tests
/// @notice Covers `commitEpochBeaconKey` / `getEpochBeaconKey` / `beaconAssurance`
///         / `nextEpochForBeaconKey` — the L2 publication of the DKG outcome.
contract StakingEpochBeaconKeyTest is Test {
    uint32 internal constant EPOCH_INTERVAL = 10; // ChainConfig.epochBlockInterval below
    uint32 internal constant ACTIVE_LEN = 51;

    Staking internal staking;
    StakingPool internal stakingPool;
    ChainConfig internal chainConfig;
    SystemReward internal systemReward;
    MockBlendToken internal blend;

    // 96-byte MinSig group public key (G2) — opaque to the contract; any bytes.
    bytes internal constant PK_EPOCH = hex"abcdef0123456789";

    event EpochBeaconKeyCommitted(uint64 indexed epoch, bool assured);

    function setUp() public {
        blend = new MockBlendToken();

        uint64 nonce = vm.getNonce(address(this));
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 3));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 5));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 7));
        IFluentGovernance governance = IFluentGovernance(address(this));

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend,
            address(0)
        );
        staking = Staking(
            payable(address(
                    new ERC1967Proxy(
                        address(stakingImpl),
                        abi.encodeCall(
                            Staking.initialize, (address(this), new address[](0), new uint256[](0), uint16(0))
                        )
                    )
                ))
        );

        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend
        );
        systemReward = SystemReward(
            payable(address(
                    new ERC1967Proxy(
                        address(systemRewardImpl),
                        abi.encodeCall(
                            SystemReward.initialize, (address(this), _singleton(address(this)), _singleton16(10_000))
                        )
                    )
                ))
        );

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend
        );
        stakingPool = StakingPool(
            payable(address(
                    new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (address(this))))
                ))
        );

        ChainConfig chainConfigImpl = new ChainConfig(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend, 0
        );
        chainConfig = ChainConfig(
            address(
                new ERC1967Proxy(
                    address(chainConfigImpl),
                    abi.encodeCall(
                        ChainConfig.initialize,
                        (
                            address(this),
                            ACTIVE_LEN,
                            EPOCH_INTERVAL,
                            uint32(50),
                            uint32(150),
                            uint32(7),
                            uint32(7),
                            uint256(1 ether),
                            uint256(1 ether),
                            uint64(0)
                        )
                    )
                )
            )
        );

        assertEq(address(staking), address(predictedStaking));
        assertEq(address(chainConfig), address(predictedChainConfig));
    }

    function _singleton(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleton16(uint16 value) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }

    function _rollToEpoch(uint64 epoch) internal {
        vm.roll(uint256(epoch) * EPOCH_INTERVAL);
        assertEq(staking.currentEpoch(), epoch, "epoch roll mismatch");
    }

    function _commit(bytes memory key) internal {
        vm.prank(SYSTEM_CALLER);
        staking.commitEpochBeaconKey(key);
    }

    function test_commit_storesKeyAndAdvancesCursor() public {
        assertEq(staking.nextEpochForBeaconKey(), 0, "genesis cursor");
        _commit(PK_EPOCH); // commits epoch 0
        assertEq(staking.nextEpochForBeaconKey(), 1);
        assertEq(staking.getEpochBeaconKey(0), PK_EPOCH);
        assertTrue(staking.beaconAssurance(0));

        _rollToEpoch(1);
        _commit(PK_EPOCH); // commits epoch 1
        assertEq(staking.nextEpochForBeaconKey(), 2);
        assertEq(staking.getEpochBeaconKey(1), PK_EPOCH);
    }

    function test_emptyKey_isFallbackEpoch_noAssurance() public {
        _commit(hex""); // commits epoch 0 with no threshold randomness
        assertEq(staking.getEpochBeaconKey(0).length, 0);
        assertFalse(staking.beaconAssurance(0), "empty key means fallback epoch, no assurance");
        assertEq(staking.nextEpochForBeaconKey(), 1, "cursor advances even on fallback");
    }

    function test_emitsEpochBeaconKeyCommitted() public {
        vm.expectEmit(true, false, false, true, address(staking));
        emit EpochBeaconKeyCommitted(0, true);
        _commit(PK_EPOCH);
    }

    function test_RevertIf_nonSystemCaller() public {
        vm.expectRevert(abi.encodeWithSignature("OnlySystemCall()"));
        staking.commitEpochBeaconKey(PK_EPOCH);
    }

    function test_RevertIf_targetBeyondNextEpoch() public {
        // cur = 0: committing epoch 0 (target 0 ≤ 1) then epoch 1 (target 1 ≤ 1)
        // is fine; a third commit targets epoch 2 > cur + 1 = 1 ⇒ revert.
        _commit(PK_EPOCH);
        _commit(PK_EPOCH);
        vm.expectRevert(abi.encodeWithSignature("EpochNotYetCommittable(uint64,uint64)", uint64(2), uint64(0)));
        _commit(PK_EPOCH);
    }
}
