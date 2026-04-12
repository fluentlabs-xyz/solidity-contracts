// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {InitConfiguration, L2BlockHeader, BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockSp1Verifier} from "../mocks/MockSp1Verifier.sol";
import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";

contract AdminTest is RollupAssertions {
    function _defaultInitConfig(address admin_, address sequencer_) internal returns (InitConfiguration memory cfg) {
        MockSp1Verifier sp1 = new MockSp1Verifier();
        cfg.admin = admin_;
        cfg.emergency = admin_;
        cfg.sequencer = sequencer_;
        cfg.challenger = challenger;
        cfg.prover = prover;
        cfg.preconfirmationRole = preconfirmer;
        cfg.sp1Verifier = address(sp1);
        cfg.nitroVerifier = address(nitroVerifier);
        cfg.bridge = bridgeAddr;
        cfg.programVKey = PROGRAM_VKEY;

        cfg.challengeDepositAmount = CHALLENGE_DEPOSIT;
        cfg.challengeWindow = CHALLENGE_WINDOW;
        cfg.finalizationDelay = FINALIZATION_DELAY;
        cfg.incentiveFee = 0.1 ether;
        cfg.submitBlobsWindow = SUBMIT_BLOBS_WINDOW;
        cfg.preconfirmWindow = PRECONFIRM_WINDOW;
    }

    function _makeAcceptedBatch(uint256 expectedBlobsCount) internal returns (uint256 batchIndex) {
        batchIndex = _acceptBatch(GENESIS_HASH, expectedBlobsCount);
        _submitBlobs(batchIndex, expectedBlobsCount);
    }

    function test_emergencyRole_defaultsToAdmin() public {
        InitConfiguration memory cfg = _defaultInitConfig(admin, sequencer);
        cfg.emergency = address(0);
        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        Rollup r = Rollup(address(proxy));

        assertTrue(r.hasRole(r.EMERGENCY_ROLE(), admin), "admin should have EMERGENCY_ROLE when emergency=address(0)");
    }

    function test_RevertIf_setBridge_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "bridge"));
        rollup.setBridge(address(0));
    }

    function test_RevertIf_setSp1Verifier_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "sp1Verifier"));
        rollup.setSp1Verifier(address(0));
    }

    function test_RevertIf_setProgramVKey_zeroValue() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "programVKey"));
        rollup.setProgramVKey(bytes32(0));
    }

    function test_RevertIf_setGasLeft_zeroValue() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "gasLeft"));
        rollup.setGasLeft(0);
    }

    function test_RevertIf_enableNitroVerifier_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "nitroVerifier"));
        rollup.enableNitroVerifier(address(0));
    }

    function test_setBridge_emitsBridgeUpdated() public {
        address oldBridge = rollup.bridge();
        address newBridge = makeAddr("newBridge");

        vm.expectEmit(true, true, false, false, address(rollup));
        emit BridgeUpdated(oldBridge, newBridge);
        vm.prank(admin);
        rollup.setBridge(newBridge);

        assertEq(rollup.bridge(), newBridge);
    }

    function test_setProgramVKey_emitsProgramVKeyUpdated() public {
        bytes32 oldVKey = rollup.programVKey();
        bytes32 newVKey = keccak256("newVKey");

        vm.expectEmit(true, true, false, false, address(rollup));
        emit ProgramVKeyUpdated(oldVKey, newVKey);
        vm.prank(admin);
        rollup.setProgramVKey(newVKey);

        assertEq(rollup.programVKey(), newVKey);
    }

    function test_RevertIf_initialize_challengeWindowExceedsFinalizationDelay() public {
        InitConfiguration memory cfg = _defaultInitConfig(admin, sequencer);
        cfg.challengeWindow = 15000;
        cfg.finalizationDelay = 14800;
        Rollup impl = new Rollup();
        vm.expectRevert(
            abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "challengeWindow too close to finalizationDelay")
        );
        new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
    }

    function test_RevertIf_initialize_adminZeroAddress() public {
        InitConfiguration memory cfg = _defaultInitConfig(address(0), sequencer);
        Rollup impl = new Rollup();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "admin"));
        new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
    }

    function test_init_sequencerZeroFallsBackToAdmin() public {
        InitConfiguration memory cfg = _defaultInitConfig(admin, address(0));
        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        Rollup r = Rollup(address(proxy));

        assertTrue(r.hasRole(r.SEQUENCER_ROLE(), admin));
        assertFalse(r.hasRole(r.SEQUENCER_ROLE(), address(0)));
    }

    function test_disableNitroVerifier_emitsEvent() public {
        vm.expectEmit(true, true, false, false, address(rollup));
        emit NitroVerifierDisabled(address(nitroVerifier));
        vm.prank(admin);
        rollup.disableNitroVerifier(address(nitroVerifier));
    }

    function test_disableNitroVerifier_preventsPreconfirm() public {
        uint256 batchIndex = _makeAcceptedBatch(1);
        vm.prank(admin);
        rollup.disableNitroVerifier(address(nitroVerifier));
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NitroVerifierNotEnabled.selector, address(nitroVerifier)));
        vm.prank(preconfirmer);
        rollup.preconfirmBatch(address(nitroVerifier), batchIndex, DUMMY_SIGNATURE);
    }

    function test_disableNitroVerifier_revertsWhenNotEnabled() public {
        MockNitroVerifier other = new MockNitroVerifier();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NitroVerifierNotEnabled.selector, address(other)));
        rollup.disableNitroVerifier(address(other));
    }

    function test_enableNitroVerifier_emitsAndMakesPreconfirmSucceed() public {
        uint256 batchIndex = _makeAcceptedBatch(1);
        MockNitroVerifier other = new MockNitroVerifier();

        vm.expectEmit(true, true, false, false, address(rollup));
        emit NitroVerifierEnabled(address(other));
        vm.prank(admin);
        rollup.enableNitroVerifier(address(other));

        vm.prank(preconfirmer);
        rollup.preconfirmBatch(address(other), batchIndex, DUMMY_SIGNATURE);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));
    }

    function test_enableNitroVerifier_revertsWhenAlreadyEnabled() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NitroVerifierAlreadyEnabled.selector, address(nitroVerifier)));
        rollup.enableNitroVerifier(address(nitroVerifier));
    }

    function test_setSp1Verifier_updatesAndEmits() public {
        address oldVerifier = rollup.sp1Verifier();
        MockSp1Verifier newVerifier = new MockSp1Verifier();

        vm.expectEmit(true, true, false, false, address(rollup));
        emit SP1VerifierUpdated(oldVerifier, address(newVerifier));
        vm.prank(admin);
        rollup.setSp1Verifier(address(newVerifier));

        assertEq(rollup.sp1Verifier(), address(newVerifier));
    }

    function test_setSubmitBlobsWindow_updatesAndEmits() public {
        uint24 newWindow = 90;
        uint24 prev = uint24(rollup.submitBlobsWindow());

        vm.expectEmit(true, false, false, true, address(rollup));
        emit SubmitBlobsWindowUpdated(prev, newWindow);
        vm.prank(admin);
        rollup.setSubmitBlobsWindow(newWindow);

        assertEq(rollup.submitBlobsWindow(), newWindow);
    }

    function test_setChallengeWindow_updatesAndEmits() public {
        uint24 newWindow = 7450;
        uint24 prev = uint24(rollup.challengeWindow());

        vm.expectEmit(true, false, false, true, address(rollup));
        emit ChallengeWindowUpdated(prev, newWindow);
        vm.prank(admin);
        rollup.setChallengeWindow(newWindow);

        assertEq(rollup.challengeWindow(), newWindow);
    }

    function test_setFinalizationDelay_updatesAndEmits() public {
        uint24 newDelay = 14900;
        uint24 prev = uint24(rollup.finalizationDelay());

        vm.expectEmit(true, false, false, true, address(rollup));
        emit FinalizationDelayUpdated(prev, newDelay);
        vm.prank(admin);
        rollup.setFinalizationDelay(newDelay);

        assertEq(rollup.finalizationDelay(), newDelay);
    }

    function test_setChallengeDepositAmount_updatesAndEmits() public {
        uint256 newDeposit = 2 ether;
        uint256 prev = rollup.challengeDepositAmount();

        vm.expectEmit(true, false, false, true, address(rollup));
        emit ChallengeDepositAmountUpdated(prev, newDeposit);
        vm.prank(admin);
        rollup.setChallengeDepositAmount(newDeposit);

        assertEq(rollup.challengeDepositAmount(), newDeposit);
    }

    function test_setIncentiveFee_updatesAndEmits() public {
        uint256 newFee = 0.2 ether;
        uint256 prev = rollup.incentiveFee();

        vm.expectEmit(true, false, false, true, address(rollup));
        emit IncentiveFeeUpdated(prev, newFee);
        vm.prank(admin);
        rollup.setIncentiveFee(newFee);

        assertEq(rollup.incentiveFee(), newFee);
    }

    function test_setGasLeft_updatesValue() public {
        vm.prank(admin);
        rollup.setGasLeft(type(uint32).max);
    }

    // ============ Additional admin revert tests ============

    function test_RevertIf_setSp1Verifier_notAContract() public {
        address eoa = makeAddr("eoa");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NotAContract.selector, "sp1Verifier"));
        rollup.setSp1Verifier(eoa);
    }

    function test_RevertIf_enableNitroVerifier_notAContract() public {
        address eoa = makeAddr("eoa");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NotAContract.selector, "nitroVerifier"));
        rollup.enableNitroVerifier(eoa);
    }

    function test_RevertIf_disableNitroVerifier_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, "verifier"));
        rollup.disableNitroVerifier(address(0));
    }

    function test_RevertIf_setChallengeWindow_tooCloseToFinalizationDelay() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "challengeWindow too close to finalizationDelay"));
        rollup.setChallengeWindow(uint24(FINALIZATION_DELAY));
    }

    function test_RevertIf_setFinalizationDelay_tooCloseToChallengeWindow() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "finalizationDelay too close to challengeWindow"));
        rollup.setFinalizationDelay(uint24(CHALLENGE_WINDOW));
    }

    function test_RevertIf_setChallengeDepositAmount_zero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "challengeDepositAmount"));
        rollup.setChallengeDepositAmount(0);
    }

    function test_RevertIf_initialize_submitBlobsWindowRange() public {
        InitConfiguration memory cfg = _defaultInitConfig(admin, sequencer);
        cfg.submitBlobsWindow = uint256(type(uint24).max) + 1;
        Rollup impl = new Rollup();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "submitBlobsWindow out of range"));
        new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
    }

    // ============ setPreconfirmWindow ============

    function test_setPreconfirmWindow_updatesAndEmits() public {
        uint24 newWindow = 3750;
        uint24 prev = uint24(rollup.preconfirmWindow());

        vm.expectEmit(true, false, false, true, address(rollup));
        emit PreconfirmWindowUpdated(prev, newWindow);
        vm.prank(admin);
        rollup.setPreconfirmWindow(newWindow);

        assertEq(rollup.preconfirmWindow(), newWindow);
    }

    function test_RevertIf_setPreconfirmWindow_tooCloseToSubmitBlobsWindow() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "preconfirmWindow too close to submitBlobsWindow"));
        rollup.setPreconfirmWindow(uint24(SUBMIT_BLOBS_WINDOW + 100));
    }

    // ============ Cross-parameter window validation ============

    function test_RevertIf_setSubmitBlobsWindow_exceedsPreconfirmWindow() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "submitBlobsWindow >= preconfirmWindow"));
        rollup.setSubmitBlobsWindow(uint24(PRECONFIRM_WINDOW));
    }

    function test_RevertIf_setChallengeWindow_tooCloseToPreconfirmWindow() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "challengeWindow too close to preconfirmWindow"));
        rollup.setChallengeWindow(uint24(PRECONFIRM_WINDOW + 100));
    }
}
