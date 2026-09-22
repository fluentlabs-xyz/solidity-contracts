// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DrandOracleFixture} from "./DrandOracleFixture.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandOracleV2Mock} from "../mocks/DrandOracleV2Mock.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

contract DrandOracleUpgradeTest is DrandOracleFixture {
    /// drand quicknet round 8191 is live at this timestamp, so round 1 is still retained.
    uint256 internal constant NOW = 1_692_827_937;
    /// OwnableUpgradeable's ERC-7201 slot, where the first implementation kept its owner.
    bytes32 internal constant LEGACY_OWNER_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
    /// Initializable's ERC-7201 slot: `uint64 _initialized` in the low bits.
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    DrandOracle internal oracle;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(NOW);
        oracle = _deployOracle();
    }

    function test_initialize_seatsBothRolesOnce() public {
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), oracleAdmin));
        assertTrue(oracle.hasRole(oracle.EMERGENCY_ROLE(), oracleEmergency));
        assertFalse(oracle.hasRole(oracle.EMERGENCY_ROLE(), oracleAdmin), "the roles are separate");

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(stranger, stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initializeV2(stranger, stranger);
    }

    function test_initialize_emergencyFallsBackToAdmin() public {
        address implementation = address(new DrandOracle());
        DrandOracle fresh = DrandOracle(
            address(new ERC1967Proxy(implementation, abi.encodeCall(DrandOracle.initialize, (oracleAdmin, address(0)))))
        );
        assertTrue(fresh.hasRole(fresh.EMERGENCY_ROLE(), oracleAdmin));
    }

    function test_initialize_rejectsAZeroAdmin() public {
        address implementation = address(new DrandOracle());
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.ZeroAddressNotAllowed.selector, "admin"));
        new ERC1967Proxy(implementation, abi.encodeCall(DrandOracle.initialize, (address(0), oracleEmergency)));
    }

    function test_initialize_isDisabledOnTheImplementation() public {
        DrandOracle implementation = new DrandOracle();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(oracleAdmin, oracleEmergency);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initializeV2(oracleAdmin, oracleEmergency);
    }

    /// The proxy the first implementation left behind: initialized at version 1, an owner in
    /// Ownable's slot and no roles. Only that owner may seat them, and only once.
    function test_initializeV2_seatsTheRolesForTheLegacyOwnerAlone() public {
        address legacyOwner = makeAddr("legacyOwner");
        address implementation = address(new DrandOracle());
        DrandOracle legacy = DrandOracle(address(new ERC1967Proxy(implementation, "")));
        vm.store(address(legacy), INITIALIZABLE_SLOT, bytes32(uint256(1)));
        vm.store(address(legacy), LEGACY_OWNER_SLOT, bytes32(uint256(uint160(legacyOwner))));

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        legacy.initializeV2(oracleAdmin, oracleEmergency);

        vm.prank(legacyOwner);
        legacy.initializeV2(oracleAdmin, oracleEmergency);
        assertTrue(legacy.hasRole(legacy.DEFAULT_ADMIN_ROLE(), oracleAdmin));
        assertTrue(legacy.hasRole(legacy.EMERGENCY_ROLE(), oracleEmergency));
        assertFalse(legacy.hasRole(legacy.DEFAULT_ADMIN_ROLE(), legacyOwner), "the owner is not carried over");

        vm.prank(legacyOwner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        legacy.initializeV2(stranger, stranger);
    }

    function test_upgrade_isTheAdminsAlone() public {
        address next = address(new DrandOracleV2Mock());

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0))
        );
        oracle.upgradeToAndCall(next, "");

        vm.prank(oracleEmergency);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, oracleEmergency, bytes32(0)
            )
        );
        oracle.upgradeToAndCall(next, "");
    }

    function test_upgrade_keepsThePublishedRingAndTheRoles() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1();
        oracle.publish(v.round, v.uncompressed);
        address next = address(new DrandOracleV2Mock());

        vm.prank(oracleAdmin);
        oracle.upgradeToAndCall(next, "");

        assertEq(DrandOracleV2Mock(address(oracle)).version(), 2, "the proxy now runs V2");
        assertEq(oracle.randomnessOf(v.round), v.randomness, "the ring is where V1 left it");
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), oracleAdmin), "and so are the roles");
        assertTrue(oracle.hasRole(oracle.EMERGENCY_ROLE(), oracleEmergency));
    }

    function test_upgrade_rejectsANonUUPSImplementation() public {
        address notUUPS = address(new NotUUPS());

        vm.prank(oracleAdmin);
        vm.expectRevert(abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, bytes32(0)));
        oracle.upgradeToAndCall(notUUPS, "");
    }
}

/// @dev Has code but no `proxiableUUID`, which is how a proxy would brick itself.
contract NotUUPS {
    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(0);
    }
}
