// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ChainConfig} from "../../contracts/staking/ChainConfig.sol";
import {Staking} from "../../contracts/staking/Staking.sol";
import {SYSTEM_CALLER} from "../../contracts/staking/StakingContext.sol";
import {BLS12381Verifier} from "../../contracts/libraries/BLS12381Verifier.sol";
import {StakingPool} from "../../contracts/staking/StakingPool.sol";
import {SystemReward} from "../../contracts/staking/SystemReward.sol";
import {MockBlendToken} from "../../contracts/staking/mocks/MockBlendToken.sol";
import {IChainConfig} from "../../contracts/staking/interfaces/IChainConfig.sol";
import {IFluentGovernance} from "../../contracts/staking/interfaces/IFluentGovernance.sol";
import {IStaking} from "../../contracts/staking/interfaces/IStaking.sol";
import {IStakingPool} from "../../contracts/staking/interfaces/IStakingPool.sol";
import {ISystemReward} from "../../contracts/staking/interfaces/ISystemReward.sol";

/// @notice Finding B regression lock: permissionless roster-scan DoS on the committee-commit hot path.
///
/// Bug (pre-fix): `registerValidator` is permissionless and its `_addValidator(Pending)` UNCONDITIONALLY
/// pushed the validator onto `_selectionRoster`, which `getValidatorsAt` (→ `commitEpochCommittee`, a
/// must-succeed per-epoch system call) scans O(rosterLen). A never-activated Pending registrant is
/// selection-INVISIBLE at every queryable epoch (it never enters the top-k sort), so it only bloated the
/// scan — enough permissionless registrations brick the commit and stall the chain.
///
/// Fix: decouple the visibility STAMP (always seeded) from the roster PUSH (only on the FIRST Active
/// transition — genesis / gov addValidator at creation, or a Pending registrant's first activateValidator
/// via `ensureRostered`, guarded by a `rostered` flag so re-enable/readmit never double-pushes). The
/// getValidatorsAt(E) output SET is byte-identical before/after for every reachable E (Pending registrants
/// were already invisible), so off-chain executor derivation is unchanged.
contract AuditFindingBTest is Test {
    uint256 internal constant ONE = 1 ether;
    uint32 internal constant EPOCH_INTERVAL = 10;
    uint32 internal constant ACTIVE_LEN = 51;

    Staking internal staking;
    ChainConfig internal chainConfig;
    MockBlendToken internal blend;

    // PoP vector (chain_id 20994), address-agnostic — valid registration for any validator. Mirrors the
    // StakingEpochCommittee/BLS conformance corpus; these tests only care about roster/selection, not BLS.
    bytes internal constant PK_UNC =
        hex"000000000000000000000000000000000727ef1c60e48042142f7bcc8b6382305cd50c5a4542c44ec72a4de6640c194f8ef36bea1dbed168ab6fd8681d910d550000000000000000000000000000000012b050b6fbe80695b5d56835e978918e37c8707a7fad09a01ae782d4c3170c9baa4c2c196b36eac6b78ceb210b287aeb000000000000000000000000000000000f9da5ef5089f62dc55ec91c2459f6ed3fd9981f8d4926ad90dca0314603ae4af86c8fa12bdd2569867f05a24908b7fc0000000000000000000000000000000009ac1ba2c6341d99ba0d6bfab8ea6a3a58726e787ab22b899cd95acfec350c1fc09f5fcbbef992106b61e45eb9158354";
    bytes internal constant SIG_UNC_VALID =
        hex"00000000000000000000000000000000027ecd57f1889127d81b2a3c46e1905c419302192ebc90f818c7d272b38a6495337f7dde0733d0d431fc1338e8caf62e00000000000000000000000000000000109a4722abb94b2ffb8685abe75b4fc8336d2f6534b64fee49baa07ab7357de65036fb93ee119860768cc65daa4c7b1e";

    function setUp() public {
        blend = new MockBlendToken();
        _deployStack(new address[](0), new uint256[](0), 0);
    }

    /// @dev Deploy the full staking stack. `genesisVals`/`genesisStakes` seed Active@0 genesis validators
    ///      via `initialize`; `activationBlock` sets the DPoS activation. Returns nothing (sets fields).
    function _deployStack(address[] memory genesisVals, uint256[] memory genesisStakes, uint64 activationBlock)
        internal
    {
        uint64 nonce = vm.getNonce(address(this));
        IStaking predictedStaking = IStaking(vm.computeCreateAddress(address(this), nonce + 1));
        ISystemReward predictedSystemReward = ISystemReward(vm.computeCreateAddress(address(this), nonce + 3));
        IStakingPool predictedStakingPool = IStakingPool(vm.computeCreateAddress(address(this), nonce + 5));
        IChainConfig predictedChainConfig = IChainConfig(vm.computeCreateAddress(address(this), nonce + 7));
        IFluentGovernance governance = IFluentGovernance(address(this));

        // Genesis stakes are self-delegated by initialize (pulls stToken), so fund + approve up front.
        uint256 totalGenesis = 0;
        for (uint256 i = 0; i < genesisStakes.length; i++) {
            totalGenesis += genesisStakes[i];
        }
        if (totalGenesis > 0) {
            blend.mint(address(this), totalGenesis);
        }

        Staking stakingImpl = new Staking(
            predictedStaking,
            predictedSystemReward,
            predictedStakingPool,
            governance,
            predictedChainConfig,
            blend,
            address(0),
            address(0)
        );
        // Approve BEFORE the proxy runs initialize (which pulls the genesis stakes). The proxy is the
        // next CREATE (nonce+1 == predictedStaking); pre-approve that address.
        blend.approve(address(predictedStaking), type(uint256).max);
        staking = Staking(
            payable(
                address(
                    new ERC1967Proxy(
                        address(stakingImpl),
                        abi.encodeCall(Staking.initialize, (address(this), genesisVals, genesisStakes, uint16(0)))
                    )
                )
            )
        );

        SystemReward systemRewardImpl = new SystemReward(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend
        );
        new ERC1967Proxy(
            address(systemRewardImpl),
            abi.encodeCall(SystemReward.initialize, (address(this), _singleton(address(this)), _singleton16(10_000)))
        );

        StakingPool stakingPoolImpl = new StakingPool(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend
        );
        new ERC1967Proxy(address(stakingPoolImpl), abi.encodeCall(StakingPool.initialize, (address(this))));

        ChainConfig chainConfigImpl = new ChainConfig(
            predictedStaking, predictedSystemReward, predictedStakingPool, governance, predictedChainConfig, blend
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
                            uint32(150),
                            uint32(7),
                            uint32(7),
                            uint256(ONE),
                            uint256(ONE),
                            activationBlock,
                            address(0),
                            address(0),
                            uint256(0)
                        )
                    )
                )
            )
        );
        assertEq(address(staking), address(predictedStaking));
        assertEq(address(chainConfig), address(predictedChainConfig));

        chainConfig.setBlsVerifier(address(new BLS12381Verifier()));
        vm.chainId(20994);
    }

    /// @dev Permissionlessly register a funded Pending validator (no key, not activated).
    function _registerPending(string memory label) internal returns (address v) {
        v = makeAddr(label);
        blend.mint(v, 100 * ONE);
        vm.startPrank(v);
        blend.approve(address(staking), 100 * ONE);
        staking.registerValidator(v, 0, 100 * ONE);
        vm.stopPrank();
    }

    /// @dev Register a Pending validator, key it, and governance-activate it (Pending -> Active).
    function _registerAndActivate(string memory label, bytes32 peerPubkey) internal returns (address v) {
        v = _registerPending(label);
        vm.prank(v);
        staking.setConsensusKeys(v, PK_UNC, SIG_UNC_VALID, peerPubkey);
        staking.activateValidator(v); // governance == address(this)
    }

    /// @dev Governance Active-at-creation validator (addValidator), keyed. Rostered at creation.
    function _addActive(string memory label, bytes32 peerPubkey) internal returns (address v) {
        v = makeAddr(label);
        staking.addValidator(v);
        vm.prank(v);
        staking.setConsensusKeys(v, PK_UNC, SIG_UNC_VALID, peerPubkey);
    }

    function _rollToEpoch(uint64 epoch) internal {
        vm.roll(uint256(epoch) * EPOCH_INTERVAL);
        assertEq(staking.currentEpoch(), epoch, "epoch roll mismatch");
    }

    // ------------------------------------------------------------------
    // B-a: never-activated Pending registrants do NOT inflate the scan.
    // ------------------------------------------------------------------

    /// The O(rosterLen) getValidatorsAt scan cost must be FLAT in the number of permissionless Pending
    /// registrations. Pre-fix each registration pushed onto the roster (~linear gas growth → DoS).
    function test_pendingRegistrantsDoNotInflateScanGas() public {
        _addActive("active", bytes32(uint256(0x10))); // one real (rostered, visible) member
        _rollToEpoch(2);

        uint256 baseline = _measureScanGas(2);

        // 200 permissionless Pending registrations. Post-fix: none rostered → scan length unchanged.
        for (uint256 i = 0; i < 200; i++) {
            _registerPending(string.concat("spam", vm.toString(i)));
        }

        uint256 afterSpam = _measureScanGas(2);

        // Post-fix delta is pure call-noise (a few hundred gas). Pre-fix it would be ~200 * ~4700 ≈ 940k.
        assertLt(afterSpam, baseline + 20_000, "Pending registrations must not grow the getValidatorsAt scan");
        // And the returned member SET is unchanged by the spam (they were always selection-invisible).
        (address[] memory addrs,) = staking.getValidatorsWithKeysAt(2);
        assertEq(addrs.length, 1, "only the one Active member is selection-visible");
    }

    function _measureScanGas(uint64 epoch) internal view returns (uint256 used) {
        uint256 g0 = gasleft();
        (address[] memory addrs,) = staking.getValidatorsWithKeysAt(epoch);
        used = g0 - gasleft();
        // Consume the result so the call is not optimized away.
        require(addrs.length <= ACTIVE_LEN, "sanity");
    }

    // ------------------------------------------------------------------
    // B-b: an activated validator IS rostered and selected.
    // ------------------------------------------------------------------

    /// A Pending registrant that is keyed and governance-activated at epoch `cur0` becomes selection-visible
    /// at exactly `cur0 + 1` and appears in the selection view / committed committee from then on.
    function test_activatedRegistrantIsSelected() public {
        _rollToEpoch(3);
        address v = _registerAndActivate("late", bytes32(uint256(0x20))); // activated at epoch 3 → visible from 4

        // Not yet visible at selEpoch 3 (activation takes effect +1).
        (address[] memory at3,) = staking.getValidatorsWithKeysAt(3);
        assertEq(at3.length, 0, "not visible at activation epoch");

        // Visible from selEpoch 4 onward — proving the ensureRostered push landed.
        (address[] memory at4,) = staking.getValidatorsWithKeysAt(4);
        assertEq(at4.length, 1, "activated validator rostered + visible at +1");
        assertEq(at4[0], v);

        // And it commits into committee[6] (selection epoch = 6 - 2 = 4, the first to see v).
        _rollToEpoch(6);
        while (staking.nextEpochToCommit() <= 6) {
            uint64 t = staking.nextEpochToCommit();
            uint64 selEpoch = t < 2 ? 0 : t - 2;
            (address[] memory sel,) = staking.getValidatorsWithKeysAt(selEpoch);
            vm.prank(SYSTEM_CALLER);
            staking.commitEpochCommittee(sel); // sel is empty until selEpoch 4, then {v}
        }
        assertEq(staking.getEpochCommittee(6).length, 1, "activated validator committed");
        assertEq(staking.getEpochCommittee(6)[0], v);
    }

    // ------------------------------------------------------------------
    // B-c: genesis committee unchanged (Active@0 → rostered from epoch 0).
    // ------------------------------------------------------------------

    function test_genesisValidatorsRosteredFromEpochZero() public {
        address g1 = makeAddr("g1");
        address g2 = makeAddr("g2");
        address[] memory gvals = new address[](2);
        gvals[0] = g1;
        gvals[1] = g2;
        uint256[] memory gstakes = new uint256[](2);
        gstakes[0] = 100 * ONE;
        gstakes[1] = 100 * ONE;
        _deployStack(gvals, gstakes, 0);

        vm.prank(g1);
        staking.setConsensusKeys(g1, PK_UNC, SIG_UNC_VALID, bytes32(uint256(0x10)));
        vm.prank(g2);
        staking.setConsensusKeys(g2, PK_UNC, SIG_UNC_VALID, bytes32(uint256(0x20)));

        // Genesis Active@0 validators are rostered from epoch 0 (Active-creation push branch).
        (address[] memory at0,) = staking.getValidatorsWithKeysAt(0);
        assertEq(at0.length, 2, "both genesis validators selection-visible at epoch 0");

        // committee[0] commits the genesis set (ascending peerPubkey: g1 0x10, g2 0x20).
        address[] memory committee = new address[](2);
        committee[0] = g1;
        committee[1] = g2;
        vm.prank(SYSTEM_CALLER);
        staking.commitEpochCommittee(committee);
        assertEq(staking.getEpochCommittee(0).length, 2, "genesis committee committed unchanged");
    }

    // ------------------------------------------------------------------
    // B-d: disable -> re-enable does NOT double-push (ensureRostered guard).
    // ------------------------------------------------------------------

    /// A validator activated once (rostered) then disabled (kept in roster) then re-activated must appear in
    /// the selection view EXACTLY once — a duplicate roster entry would produce two equal committee members
    /// and break the strictly-ascending commit order (chain halt). Exercises the `rostered`-flag guard.
    function test_disableReenableNoDoublePush() public {
        _rollToEpoch(2);
        address v = _registerAndActivate("reenable", bytes32(uint256(0x30))); // activated epoch 2, rostered

        _rollToEpoch(3);
        staking.disableValidator(v); // Active -> Pending; roster membership KEPT (only removeValidator pops)

        _rollToEpoch(4);
        staking.activateValidator(v); // re-activate: ensureRostered must be a no-op (already rostered)

        _rollToEpoch(6);
        (address[] memory at6,) = staking.getValidatorsWithKeysAt(6);
        assertEq(at6.length, 1, "re-activated validator appears exactly once (no duplicate roster entry)");
        assertEq(at6[0], v);
    }

    /// A Pending registrant activated for the FIRST time is pushed exactly once (single roster entry).
    function test_firstActivationSinglePush() public {
        _rollToEpoch(1);
        address v = _registerAndActivate("once", bytes32(uint256(0x40)));
        _rollToEpoch(3);
        (address[] memory at3,) = staking.getValidatorsWithKeysAt(3);
        assertEq(at3.length, 1, "single roster entry after first activation");
        assertEq(at3[0], v);
    }

    function _singleton(address value) internal pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value;
    }

    function _singleton16(uint16 value) internal pure returns (uint16[] memory values) {
        values = new uint16[](1);
        values[0] = value;
    }
}
