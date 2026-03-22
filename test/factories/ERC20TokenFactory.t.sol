// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {ERC20TokenFactory} from "../../contracts/factories/ERC20TokenFactory.sol";
import {GenericTokenFactory} from "../../contracts/factories/GenericTokenFactory.sol";
import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {IGenericTokenFactory, IGenericTokenFactoryErrors, IGenericTokenFactoryEvents} from "../../contracts/interfaces/IGenericTokenFactory.sol";

contract ERC20TokenFactoryTest is Test {
    ERC20TokenFactory internal factory;
    ERC20PeggedToken internal tokenImpl;

    address internal gateway = makeAddr("gateway");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        tokenImpl = new ERC20PeggedToken();

        ERC20TokenFactory impl = new ERC20TokenFactory();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ERC20TokenFactory.initialize, (address(this), address(tokenImpl)))
        );
        factory = ERC20TokenFactory(address(proxy));
        factory.setPaymentGateway(gateway);
    }

    function test_implementation_returnsBeaconImpl() public view {
        assertEq(factory.implementation(), address(tokenImpl), "impl mismatch");
    }

    function test_beacon_returnsSetBeacon() public view {
        assertTrue(factory.beacon() != address(0), "beacon should be set");
    }

    function test_bridgedTokens_returnsMapping() public {
        assertEq(factory.bridgedTokens(makeAddr("unknown")), address(0), "should be zero");
    }

    function test_tokenInfo_returnsStruct() public {
        GenericTokenFactory.TokenInfo memory info = factory.tokenInfo(makeAddr("unknown"));
        assertFalse(info.deployed, "should not be deployed");
    }

    function test_setBeacon_updatesAndEmits() public {
        address newBeacon = address(new UpgradeableBeacon(address(tokenImpl), address(this)));
        vm.expectEmit(true, true, false, false, address(factory));
        emit IGenericTokenFactoryEvents.BeaconSet(factory.beacon(), newBeacon);
        factory.setBeacon(newBeacon);
        assertEq(factory.beacon(), newBeacon, "beacon not updated");
    }

    function test_RevertIf_setBeacon_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(
            IGenericTokenFactoryErrors.ZeroAddressNotAllowed.selector, "Beacon"
        ));
        factory.setBeacon(address(0));
    }

    function test_RevertIf_onlyPaymentGateway_unauthorizedCaller() public {
        bytes memory args = factory.getDeployArgs("T", "T", 18);
        address origin = makeAddr("origin");
        vm.prank(stranger);
        vm.expectRevert(IGenericTokenFactoryErrors.OnlyPaymentGatewayOrOwner.selector);
        factory.deployToken(gateway, origin, args);
    }

    function test_computeTokenAddress_matchesDeploy() public {
        address originToken = makeAddr("origin");
        bytes memory args = factory.getDeployArgs("Test", "TST", 18);

        address predicted = factory.computeTokenAddress(gateway, originToken, args);

        vm.prank(gateway);
        address deployed = factory.deployToken(gateway, originToken, args);

        assertEq(deployed, predicted, "predicted address should match deployed");
    }
}
