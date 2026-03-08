// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {IGenericTokenFactory} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {IGenericTokenFactoryErrors} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {UniversalTokenSDK} from "../../contracts/libraries/UniversalTokenSDK.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FactoryTestBase, Vm} from "./FactoryTestBase.t.sol";

contract UniversalTokenFactoryEnhancedTest is FactoryTestBase {
    address internal constant ATTACKER = address(0xCAFE);
    address internal constant ORIGIN_TOKEN = address(0x1111);
    address internal constant PAYMENT_GATEWAY = address(0x2222);

    UniversalTokenFactory internal factory;

    function setUp() public {
        UniversalTokenFactory implementation = new UniversalTokenFactory();
        bytes memory initData = abi.encodeCall(UniversalTokenFactory.initialize, (address(this)));
        factory = UniversalTokenFactory(address(new ERC1967Proxy(address(implementation), initData)));
        factory.setPaymentGateway(PAYMENT_GATEWAY);
    }

    // ========== Initialization Tests ==========

    function testInitializeSetsOwner() public view {
        assertEq(factory.owner(), address(this), "owner mismatch");
    }

    function testInitializeRevertsOnDoubleInit() public {
        UniversalTokenFactory implementation = new UniversalTokenFactory();
        bytes memory initData = abi.encodeCall(UniversalTokenFactory.initialize, (address(this)));
        UniversalTokenFactory newFactory = UniversalTokenFactory(address(new ERC1967Proxy(address(implementation), initData)));

        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        newFactory.initialize(address(this));
    }

    // ========== Address Computation Tests ==========

    function testComputePeggedTokenAddressIsDeterministic() public view {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        address a = factory.computePeggedTokenAddress(keyData, deployArgs);
        address b = factory.computePeggedTokenAddress(keyData, deployArgs);

        assertEq(a, b, "compute token address should be deterministic");
        assertTrue(a != address(0), "computed address should not be zero");
    }

    function testComputePeggedTokenAddressMatchesOtherSide() public view {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        address thisChain = factory.computePeggedTokenAddress(keyData, deployArgs);
        address otherChain = factory.computeOtherSidePeggedTokenAddress(keyData, deployArgs);

        assertEq(thisChain, otherChain, "same factory addresses should match across chains");
    }

    function testComputeTokenAddressChangesWithOriginToken() public view {
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));
        address a = factory.computePeggedTokenAddress(abi.encode(address(0x1111)), deployArgs);
        address b = factory.computePeggedTokenAddress(abi.encode(address(0x2222)), deployArgs);

        assertTrue(a != b, "different origin tokens should produce different addresses");
    }

    function testComputeTokenAddressChangesWithDeployArgs() public view {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs1 = abi.encode("Token1", "TK1", uint8(18), uint256(0), address(0x1234), address(0x5678));
        bytes memory deployArgs2 = abi.encode("Token2", "TK2", uint8(6), uint256(100), address(0x8888), address(0x9999));

        address a = factory.computePeggedTokenAddress(keyData, deployArgs1);
        address b = factory.computePeggedTokenAddress(keyData, deployArgs2);

        assertTrue(a != b, "different deploy args should produce different addresses");
    }

    function testComputeTokenAddressStaticCallWorks() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        address computed = UniversalTokenFactory(address(factory)).computeTokenAddress(keyData, deployArgs, address(factory));
        address expected = factory.computePeggedTokenAddress(keyData, deployArgs);

        assertEq(computed, expected, "static computeTokenAddress should match computePeggedTokenAddress");
    }

    // ========== getDeployArgs Tests ==========

    function testGetDeployArgsEncodesCorrectly() public view {
        bytes memory deployArgs = factory.getDeployArgs("MyToken", "MTK", 18);

        (string memory name, string memory symbol, uint8 decimals, uint256 initialSupply, address minter, address pauser) =
            abi.decode(deployArgs, (string, string, uint8, uint256, address, address));

        assertTrue(keccak256(bytes(name)) == keccak256(bytes("MyToken")), "name mismatch");
        assertTrue(keccak256(bytes(symbol)) == keccak256(bytes("MTK")), "symbol mismatch");
        assertEq(decimals, 18, "decimals mismatch");
        assertEq(initialSupply, 0, "initial supply should be 0");
        assertEq(minter, address(this), "minter should be sender");
        assertEq(pauser, address(this), "pauser should be sender");
    }

    function testGetDeployArgsWithDifferentDecimals() public view {
        bytes memory deployArgs = factory.getDeployArgs("USDC", "USDC", 6);

        (,, uint8 decimals,,, ) = abi.decode(deployArgs, (string, string, uint8, uint256, address, address));

        assertEq(decimals, 6, "decimals should be 6");
    }

    // ========== Access Control Tests ==========

    function testOnlyPaymentGatewayCanDeploy() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        vm.prank(ATTACKER);
        vm.expectRevert(IGenericTokenFactoryErrors.OnlyPaymentGatewayOrOwner.selector);
        factory.deployToken(keyData, deployArgs);
    }

    function testOwnerCanDeploy() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        // Should not revert since we are the owner
        address deployed = factory.deployToken(keyData, deployArgs);
        assertTrue(deployed != address(0), "owner should be able to deploy");
    }

    function testPaymentGatewayCanDeploy() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), PAYMENT_GATEWAY, PAYMENT_GATEWAY);

        vm.prank(PAYMENT_GATEWAY);
        address deployed = factory.deployToken(keyData, deployArgs);
        assertTrue(deployed != address(0), "payment gateway should be able to deploy");
    }

    function testOnlyOwnerCanSetPaymentGateway() public {
        address newGateway = address(0x3333);

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        factory.setPaymentGateway(newGateway);
    }

    function testSetPaymentGatewayRevertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IGenericTokenFactoryErrors.ZeroAddressNotAllowed.selector, "PaymentGateway"));
        factory.setPaymentGateway(address(0));
    }

    function testSetPaymentGatewayEmitsEvent() public {
        address newGateway = address(0x3333);

        vm.recordLogs();
        factory.setPaymentGateway(newGateway);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("PaymentGatewaySet(address,address)")) {
                found = true;
                break;
            }
        }

        assertTrue(found, "PaymentGatewaySet event should be emitted");
        assertEq(factory.paymentGateway(), newGateway, "payment gateway should be updated");
    }

    // ========== Deployment Validation Tests ==========

    function testDeployTokenRevertsForZeroOriginToken() public {
        bytes memory keyData = abi.encode(address(0));
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        vm.expectRevert(IGenericTokenFactoryErrors.InvalidOriginToken.selector);
        factory.deployToken(keyData, deployArgs);
    }

    function testDeployTokenRevertsWhenAlreadyDeployed() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        factory.deployToken(keyData, deployArgs);

        vm.expectRevert(IGenericTokenFactoryErrors.TokenAlreadyDeployed.selector);
        factory.deployToken(keyData, deployArgs);
    }

    function testDeployTokenEmitsTokenDeployedEvent() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        vm.recordLogs();
        address deployed = factory.deployToken(keyData, deployArgs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == keccak256("TokenDeployed(address,address)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), ORIGIN_TOKEN, "origin token in event mismatch");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), deployed, "deployed token in event mismatch");
                found = true;
                break;
            }
        }

        assertTrue(found, "TokenDeployed event should be emitted");
    }

    // ========== Storage Tests ==========

    function testBridgedTokensStorageIsUpdatedAfterDeploy() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        address deployed = factory.deployToken(keyData, deployArgs);

        assertEq(factory.bridgedTokens(ORIGIN_TOKEN), deployed, "bridgedTokens mapping should be updated");
    }

    function testTokenInfoStorageIsUpdatedAfterDeploy() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        address deployed = factory.deployToken(keyData, deployArgs);

        IGenericTokenFactory.TokenInfo memory info = factory.tokenInfo(deployed);
        assertEq(info.originToken, ORIGIN_TOKEN, "tokenInfo origin token mismatch");
        assertEq(info.chainId, block.chainid, "tokenInfo chainId mismatch");
        assertTrue(info.deployed, "tokenInfo deployed flag should be true");
    }

    function testBridgedTokensDefaultsToZero() public view {
        address unknownToken = address(0xAAAA);
        assertEq(factory.bridgedTokens(unknownToken), address(0), "default bridgedTokens should be zero");
    }

    function testTokenInfoDefaultsToZero() public view {
        address unknownToken = address(0xBBBB);
        IGenericTokenFactory.TokenInfo memory info = factory.tokenInfo(unknownToken);
        assertEq(info.originToken, address(0), "default tokenInfo origin should be zero");
        assertEq(info.chainId, 0, "default tokenInfo chainId should be zero");
        assertEq(info.deployed, false, "default tokenInfo deployed should be false");
    }

    // ========== Integration Tests ==========

    function testDeploymentAddressMatchesPrediction() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        address predicted = factory.computePeggedTokenAddress(keyData, deployArgs);
        address deployed = factory.deployToken(keyData, deployArgs);

        assertEq(deployed, predicted, "deployed address should match prediction");
    }

    function testMultipleTokensWithDifferentOrigins() public {
        address origin1 = address(0x1111);
        address origin2 = address(0x2222);
        address origin3 = address(0x3333);

        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        address token1 = factory.deployToken(abi.encode(origin1), deployArgs);
        address token2 = factory.deployToken(abi.encode(origin2), deployArgs);
        address token3 = factory.deployToken(abi.encode(origin3), deployArgs);

        assertTrue(token1 != token2 && token2 != token3 && token1 != token3, "all deployed tokens should be unique");

        assertEq(factory.bridgedTokens(origin1), token1, "token1 mapping incorrect");
        assertEq(factory.bridgedTokens(origin2), token2, "token2 mapping incorrect");
        assertEq(factory.bridgedTokens(origin3), token3, "token3 mapping incorrect");
    }

    // ========== Edge Cases ==========

    function testDeployWithLongTokenName() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode(
            "VeryLongTokenNameThatExceedsNormalLength",
            "LONG",
            uint8(18),
            uint256(0),
            address(this),
            address(this)
        );

        address deployed = factory.deployToken(keyData, deployArgs);
        assertTrue(deployed != address(0), "should deploy with long name");
    }

    function testDeployWithZeroInitialSupply() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(this), address(this));

        address deployed = factory.deployToken(keyData, deployArgs);
        assertTrue(deployed != address(0), "should deploy with zero initial supply");
    }

    function testDeployWithNonZeroInitialSupply() public {
        bytes memory keyData = abi.encode(address(0x4444));
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(1000000), address(this), address(this));

        address deployed = factory.deployToken(keyData, deployArgs);
        assertTrue(deployed != address(0), "should deploy with non-zero initial supply");
    }

    function testDeployWithZeroMinterAndPauser() public {
        bytes memory keyData = abi.encode(address(0x5555));
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0), address(0));

        address deployed = factory.deployToken(keyData, deployArgs);
        assertTrue(deployed != address(0), "should deploy with zero minter and pauser");
    }

    function testDeployWithDifferentDecimals() public {
        address[] memory origins = new address[](3);
        origins[0] = address(0x6666);
        origins[1] = address(0x7777);
        origins[2] = address(0x8888);

        uint8[] memory decimalsArray = new uint8[](3);
        decimalsArray[0] = 6;
        decimalsArray[1] = 18;
        decimalsArray[2] = 8;

        for (uint256 i = 0; i < origins.length; i++) {
            bytes memory keyData = abi.encode(origins[i]);
            bytes memory deployArgs = abi.encode("Token", "TKN", decimalsArray[i], uint256(0), address(this), address(this));

            address deployed = factory.deployToken(keyData, deployArgs);
            assertTrue(deployed != address(0), "should deploy with various decimals");
        }
    }
}