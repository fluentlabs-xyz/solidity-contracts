// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {IGenericTokenFactory} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {IGenericTokenFactoryErrors} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FactoryTestBase, Vm} from "./FactoryTestBase.t.sol";

contract ERC20TokenFactoryTest is FactoryTestBase {
    bytes32 private constant TOKEN_DEPLOYED_SIG = keccak256("TokenDeployed(address,address)");

    address internal constant ATTACKER = address(0xBEEF);
    address internal constant GATEWAY = address(0x1111);
    address internal constant ORIGIN_TOKEN = address(0x2222);

    ERC20TokenFactory internal factory;
    ERC20PeggedToken internal peggedImplementation;

    function _deployViaSharedInterface(address gateway, address originToken) internal returns (address) {
        return IGenericTokenFactory(address(factory)).deployToken(abi.encode(gateway, originToken), "");
    }

    function setUp() public {
        peggedImplementation = new ERC20PeggedToken();

        ERC20TokenFactory factoryImplementation = new ERC20TokenFactory();
        bytes memory initData = abi.encodeCall(ERC20TokenFactory.initialize, (address(this), address(peggedImplementation)));
        factory = ERC20TokenFactory(address(new ERC1967Proxy(address(factoryImplementation), initData)));
    }

    function testInitializeSetsOwnerBeaconAndImplementation() public view {
        assertEq(factory.owner(), address(this), "owner mismatch");
        assertTrue(factory.beacon() != address(0), "beacon not initialized");
        assertEq(factory.implementation(), address(peggedImplementation), "implementation mismatch");
    }

    function testInitializeRevertsOnZeroImplementation() public {
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        factory.initialize(address(this), address(0));
    }

    function testComputePeggedTokenAddressMatchesDeployment() public {
        address predicted = factory.computePeggedTokenAddress(GATEWAY, ORIGIN_TOKEN);
        address deployed = _deployViaSharedInterface(GATEWAY, ORIGIN_TOKEN);

        assertEq(deployed, predicted, "deployed token address mismatch");
        assertTrue(deployed.code.length > 0, "deployed proxy has no code");
    }

    function testSharedComputePeggedTokenAddressInterfaceMatchesComputeTokenAddress() public view {
        bytes memory keyData = abi.encode(GATEWAY, ORIGIN_TOKEN);
        address fromComputeTokenAddress = factory.computeTokenAddress(keyData, "");
        address fromSharedPeggedAddress = factory.computePeggedTokenAddress(keyData, "");

        assertEq(fromSharedPeggedAddress, fromComputeTokenAddress, "shared pegged address interface mismatch");
    }

    function testDeployTokenThroughGenericInterfaceWorks() public {
        bytes memory keyData = abi.encode(GATEWAY, ORIGIN_TOKEN);
        address predicted = factory.computeTokenAddress(keyData, "");
        address deployed = IGenericTokenFactory(address(factory)).deployToken(keyData, "");

        assertEq(deployed, predicted, "generic deploy returned wrong address");
    }

    function testDeployTokenEmitsTokenDeployedEvent() public {
        vm.recordLogs();
        address deployed = _deployViaSharedInterface(GATEWAY, ORIGIN_TOKEN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(factory) && logs[i].topics.length == 3 && logs[i].topics[0] == TOKEN_DEPLOYED_SIG) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), ORIGIN_TOKEN, "origin token topic mismatch");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), deployed, "deployed token topic mismatch");
                found = true;
                break;
            }
        }

        assertTrue(found, "TokenDeployed event not emitted");
    }

    function testDeployTokenRevertsWhenAlreadyDeployed() public {
        _deployViaSharedInterface(GATEWAY, ORIGIN_TOKEN);
        vm.expectRevert(IGenericTokenFactoryErrors.TokenAlreadyDeployed.selector);
        _deployViaSharedInterface(GATEWAY, ORIGIN_TOKEN);
    }

    function testDeployTokenRevertsOnInvalidGateway() public {
        vm.expectRevert(IGenericTokenFactoryErrors.InvalidGateway.selector);
        _deployViaSharedInterface(address(0), ORIGIN_TOKEN);
    }

    function testDeployTokenRevertsOnInvalidOriginToken() public {
        vm.expectRevert(IGenericTokenFactoryErrors.InvalidOriginToken.selector);
        _deployViaSharedInterface(GATEWAY, address(0));
    }

    function testOnlyOwnerCanDeploy() public {
        bytes memory keyData = abi.encode(GATEWAY, ORIGIN_TOKEN);
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        IGenericTokenFactory(address(factory)).deployToken(keyData, "");
    }

    function testOnlyOwnerCanDeployThroughGenericInterface() public {
        bytes memory keyData = abi.encode(GATEWAY, ORIGIN_TOKEN);
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        IGenericTokenFactory(address(factory)).deployToken(keyData, "");
    }

    function testComputeOtherSidePeggedTokenAddressMatchesManualCompute() public view {
        address computed = factory.computeOtherSidePeggedTokenAddress(GATEWAY, ORIGIN_TOKEN, factory.beacon(), address(factory));
        address local = factory.computePeggedTokenAddress(GATEWAY, ORIGIN_TOKEN);

        assertEq(computed, local, "cross-side compute should match local compute with same params");
    }

    function testUpgradeToUpdatesImplementation() public {
        ERC20PeggedToken newImplementation = new ERC20PeggedToken();
        factory.upgradeTo(address(newImplementation));

        assertEq(factory.implementation(), address(newImplementation), "implementation was not upgraded");
    }

    function testOnlyOwnerCanUpgrade() public {
        ERC20PeggedToken newImplementation = new ERC20PeggedToken();
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        factory.upgradeTo(address(newImplementation));
    }
}
