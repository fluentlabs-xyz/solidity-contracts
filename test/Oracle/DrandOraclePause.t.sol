// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DrandOracleFixture} from "./DrandOracleFixture.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

/// The emergency lever: publishing stops, everything else goes on, and only the emergency
/// role holds it.
contract DrandOraclePauseTest is DrandOracleFixture {
    /// drand quicknet round 8191 is live at this timestamp, so round 1 is still retained.
    uint256 internal constant NOW = 1_692_827_937;

    DrandOracle internal oracle;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(NOW);
        oracle = _deployOracle();
    }

    function test_pause_stopsPublishingAndNothingElse() public {
        DrandQuicknetVectors.Vector memory one = DrandQuicknetVectors.round1();
        DrandQuicknetVectors.Vector memory thousand = DrandQuicknetVectors.round1000();
        oracle.publish(one.round, one.uncompressed);

        vm.prank(oracleEmergency);
        oracle.pause();
        assertTrue(oracle.paused());

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        oracle.publish(thousand.round, thousand.uncompressed);
        uint64[] memory rounds = new uint64[](1);
        rounds[0] = thousand.round;
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        oracle.publishBatch(rounds, thousand.uncompressed);

        assertEq(oracle.randomnessOf(one.round), one.randomness, "reads go on");
        assertEq(oracle.verifyRound(thousand.round, thousand.uncompressed), thousand.randomness, "so does verifying");
        vm.prank(stranger);
        assertEq(oracle.commit(), oracle.currentRound() + oracle.minFutureRounds(), "and committing");

        vm.prank(oracleEmergency);
        oracle.unpause();
        oracle.publish(thousand.round, thousand.uncompressed);
        assertEq(oracle.randomnessOf(thousand.round), thousand.randomness, "publishing resumes");
    }

    function test_pause_isTheEmergencyRolesAlone() public {
        bytes32 role = oracle.EMERGENCY_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        oracle.pause();

        vm.prank(oracleAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, oracleAdmin, role)
        );
        oracle.pause();

        vm.prank(oracleEmergency);
        oracle.pause();
        vm.prank(oracleAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, oracleAdmin, role)
        );
        oracle.unpause();
    }

    /// The admin administers the roles: it can seat an emergency account and unseat one,
    /// which is what lets a timelock rotate the emergency key without an upgrade.
    function test_admin_administersTheEmergencyRole() public {
        bytes32 role = oracle.EMERGENCY_ROLE();
        address next = makeAddr("nextEmergency");

        vm.prank(oracleAdmin);
        oracle.grantRole(role, next);
        vm.prank(oracleAdmin);
        oracle.revokeRole(role, oracleEmergency);

        vm.prank(next);
        oracle.pause();
        vm.prank(oracleEmergency);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, oracleEmergency, role)
        );
        oracle.unpause();
    }
}
