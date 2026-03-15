// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupBase} from "./Base.t.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {InitConfiguration} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors, IRollupEvents} from "../../contracts/interfaces/IRollup.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockSp1Verifier} from "./mocks/MockSp1Verifier.sol";

contract AdminTest is RollupBase {
    function test_emergencyRole_defaultsToAdmin() public {
        MockSp1Verifier sp1 = new MockSp1Verifier();
        InitConfiguration memory cfg = InitConfiguration({
            admin: admin,
            emergency: address(0),
            sequencer: sequencer,
            challenger: challenger,
            prover: prover,
            preconfirmationRole: preconfirmer,
            sp1Verifier: address(sp1),
            nitroVerifier: address(0),
            bridge: bridgeAddr,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            challengeDepositAmount: CHALLENGE_DEPOSIT,
            challengeWindow: CHALLENGE_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            submitBlobsWindow: SUBMIT_BLOBS_WINDOW,
            preconfirmWindow: PRECONFIRM_WINDOW
        });
        Rollup impl = new Rollup();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
        Rollup r = Rollup(address(proxy));

        assertTrue(r.hasRole(r.EMERGENCY_ROLE(), admin), "admin should have EMERGENCY_ROLE when emergency=address(0)");
    }

    function test_revert_setBridge_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, bytes32("bridge")));
        rollup.setBridge(address(0));
    }

    function test_revert_setSp1Verifier_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, bytes32("sp1Verifier")));
        rollup.setSp1Verifier(address(0));
    }

    function test_revert_setProgramVKey_zeroValue() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, bytes32("programVKey")));
        rollup.setProgramVKey(bytes32(0));
    }

    function test_revert_setNitroVerifier_zeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroAddressNotAllowed.selector, bytes32("nitroVerifier")));
        rollup.setNitroVerifier(address(0));
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

    function test_revert_init_challengeWindowExceedsFinalizationDelay() public {
        MockSp1Verifier sp1 = new MockSp1Verifier();
        InitConfiguration memory cfg = InitConfiguration({
            admin: admin,
            emergency: admin,
            sequencer: sequencer,
            challenger: challenger,
            prover: prover,
            preconfirmationRole: preconfirmer,
            sp1Verifier: address(sp1),
            nitroVerifier: address(0),
            bridge: bridgeAddr,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            challengeDepositAmount: CHALLENGE_DEPOSIT,
            challengeWindow: 300,
            finalizationDelay: 200,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            submitBlobsWindow: SUBMIT_BLOBS_WINDOW,
            preconfirmWindow: PRECONFIRM_WINDOW
        });
        Rollup impl = new Rollup();
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "challengeWindow must be less than finalizationDelay"));
        new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
    }

    function test_revert_init_preconfirmWindowLessThanSubmitBlobsWindow() public {
        MockSp1Verifier sp1 = new MockSp1Verifier();
        InitConfiguration memory cfg = InitConfiguration({
            admin: admin,
            emergency: admin,
            sequencer: sequencer,
            challenger: challenger,
            prover: prover,
            preconfirmationRole: preconfirmer,
            sp1Verifier: address(sp1),
            nitroVerifier: address(0),
            bridge: bridgeAddr,
            programVKey: PROGRAM_VKEY,
            genesisHash: GENESIS_HASH,
            challengeDepositAmount: CHALLENGE_DEPOSIT,
            challengeWindow: CHALLENGE_WINDOW,
            finalizationDelay: FINALIZATION_DELAY,
            acceptDepositDeadline: 1000,
            incentiveFee: 0.1 ether,
            submitBlobsWindow: 100,
            preconfirmWindow: 50
        });
        Rollup impl = new Rollup();
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidWindowConfig.selector, "preconfirmWindow must exceed submitBlobsWindow"));
        new ERC1967Proxy(address(impl), abi.encodeCall(Rollup.initialize, (abi.encode(cfg))));
    }
}
