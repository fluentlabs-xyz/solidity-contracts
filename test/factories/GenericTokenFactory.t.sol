// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {GenericTokenFactory} from "../../contracts/factories/GenericTokenFactory.sol";
import {IGenericTokenFactory} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {IGenericTokenFactoryErrors} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {FactoryTestBase, Vm} from "./FactoryTestBase.t.sol";

// Concrete implementation for testing
contract TestTokenImplementation {
    string public name;
    uint8 public decimals;

    function initialize(string memory _name, uint8 _decimals) external {
        name = _name;
        decimals = _decimals;
    }
}

// Minimal concrete factory for testing abstract base
contract TestGenericTokenFactory is GenericTokenFactory {
    function initialize(address _initialOwner, address _beacon) external initializer {
        __GenericTokenFactory_init(_initialOwner);
        _setBeacon(_beacon);
    }

    function deployToken(bytes calldata keyData, bytes calldata deployArgs) external override onlyPaymentGateway returns (address) {
        (address deployed, address origin) = _deployToken(keyData, deployArgs);
        _afterDeployToken(deployed, origin);
        emit TokenDeployed(origin, deployed);
        return deployed;
    }

    function _deployToken(bytes calldata keyData, bytes calldata deployArgs) internal override returns (address, address) {
        address origin = abi.decode(keyData, (address));
        require(origin != address(0), "zero origin");

        bytes32 salt = keccak256(abi.encodePacked(origin, deployArgs));
        bytes memory bytecode = _beaconProxyBytecode(beacon());

        address deployed = address(new BeaconProxy{salt: salt}(beacon(), ""));
        return (deployed, origin);
    }

    function _computeTokenAddress(bytes calldata keyData, bytes calldata deployArgs) internal view override returns (address) {
        address origin = abi.decode(keyData, (address));
        bytes32 salt = keccak256(abi.encodePacked(origin, deployArgs));
        bytes32 bytecodeHash = keccak256(_beaconProxyBytecode(beacon()));

        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            bytecodeHash
        )))));
    }

    function getDeployArgs(
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals
    ) external pure override returns (bytes memory) {
        return abi.encode(tokenName, tokenSymbol, decimals);
    }
}

contract GenericTokenFactoryTest is FactoryTestBase {
    address internal constant ATTACKER = address(0xBAD);
    address internal constant PAYMENT_GATEWAY = address(0x1234);
    address internal constant ORIGIN_TOKEN = address(0x5678);

    TestGenericTokenFactory internal factory;
    TestTokenImplementation internal implementation;
    UpgradeableBeacon internal beacon;

    function setUp() public {
        implementation = new TestTokenImplementation();
        beacon = new UpgradeableBeacon(address(implementation), address(this));

        TestGenericTokenFactory factoryImpl = new TestGenericTokenFactory();
        bytes memory initData = abi.encodeCall(TestGenericTokenFactory.initialize, (address(this), address(beacon)));
        factory = TestGenericTokenFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));

        factory.setPaymentGateway(PAYMENT_GATEWAY);
    }

    // ========== Initialization Tests ==========

    function testInitializeSetsOwnerAndBeacon() public view {
        assertEq(factory.owner(), address(this), "owner should be set");
        assertEq(factory.beacon(), address(beacon), "beacon should be set");
        assertEq(factory.implementation(), address(implementation), "implementation should match beacon");
    }

    function testInitializeRevertsOnDoubleInit() public {
        TestGenericTokenFactory factoryImpl = new TestGenericTokenFactory();
        bytes memory initData = abi.encodeCall(TestGenericTokenFactory.initialize, (address(this), address(beacon)));
        TestGenericTokenFactory newFactory = TestGenericTokenFactory(address(new ERC1967Proxy(address(factoryImpl), initData)));

        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        newFactory.initialize(address(this), address(beacon));
    }

    // ========== Beacon Management Tests ==========

    function testSetBeaconUpdatesBeacon() public {
        UpgradeableBeacon newBeacon = new UpgradeableBeacon(address(implementation), address(this));

        factory.setBeacon(address(newBeacon));

        assertEq(factory.beacon(), address(newBeacon), "beacon should be updated");
    }

    function testSetBeaconRevertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IGenericTokenFactoryErrors.ZeroAddressNotAllowed.selector, "Beacon"));
        factory.setBeacon(address(0));
    }

    function testSetBeaconEmitsEvent() public {
        UpgradeableBeacon newBeacon = new UpgradeableBeacon(address(implementation), address(this));

        vm.recordLogs();
        factory.setBeacon(address(newBeacon));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("BeaconSet(address,address)")) {
                found = true;
                break;
            }
        }

        assertTrue(found, "BeaconSet event should be emitted");
    }

    function testOnlyOwnerCanSetBeacon() public {
        UpgradeableBeacon newBeacon = new UpgradeableBeacon(address(implementation), address(this));

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        factory.setBeacon(address(newBeacon));
    }

    // ========== Implementation Upgrade Tests ==========

    function testUpgradeToUpdatesImplementation() public {
        TestTokenImplementation newImpl = new TestTokenImplementation();

        factory.upgradeTo(address(newImpl));

        assertEq(factory.implementation(), address(newImpl), "implementation should be updated");
    }

    function testOnlyOwnerCanUpgrade() public {
        TestTokenImplementation newImpl = new TestTokenImplementation();

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        factory.upgradeTo(address(newImpl));
    }

    // ========== Payment Gateway Tests ==========

    function testSetPaymentGatewayUpdatesGateway() public {
        address newGateway = address(0x9999);

        factory.setPaymentGateway(newGateway);

        assertEq(factory.paymentGateway(), newGateway, "payment gateway should be updated");
    }

    function testSetPaymentGatewayRevertsOnZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IGenericTokenFactoryErrors.ZeroAddressNotAllowed.selector, "PaymentGateway"));
        factory.setPaymentGateway(address(0));
    }

    function testSetPaymentGatewayEmitsEvent() public {
        address newGateway = address(0x9999);

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
    }

    function testOnlyOwnerCanSetPaymentGateway() public {
        address newGateway = address(0x9999);

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        factory.setPaymentGateway(newGateway);
    }

    // ========== Access Control Tests ==========

    function testOnlyPaymentGatewayCanDeployToken() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        vm.prank(ATTACKER);
        vm.expectRevert(IGenericTokenFactoryErrors.OnlyPaymentGatewayOrOwner.selector);
        factory.deployToken(keyData, deployArgs);
    }

    function testOwnerCanDeployToken() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        address deployed = factory.deployToken(keyData, deployArgs);
        assertTrue(deployed != address(0), "owner should be able to deploy");
    }

    function testPaymentGatewayCanDeployToken() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        vm.prank(PAYMENT_GATEWAY);
        address deployed = factory.deployToken(keyData, deployArgs);
        assertTrue(deployed != address(0), "payment gateway should be able to deploy");
    }

    // ========== Storage Tests ==========

    function testBridgedTokensStorageAfterDeploy() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        address deployed = factory.deployToken(keyData, deployArgs);

        assertEq(factory.bridgedTokens(ORIGIN_TOKEN), deployed, "bridgedTokens should be set");
    }

    function testTokenInfoStorageAfterDeploy() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        address deployed = factory.deployToken(keyData, deployArgs);

        IGenericTokenFactory.TokenInfo memory info = factory.tokenInfo(deployed);
        assertEq(info.originToken, ORIGIN_TOKEN, "origin token should be set");
        assertEq(info.chainId, block.chainid, "chainId should be set");
        assertTrue(info.deployed, "deployed flag should be true");
    }

    function testBridgedTokensDefaultsToZero() public view {
        assertEq(factory.bridgedTokens(address(0x1111)), address(0), "default should be zero");
    }

    function testTokenInfoDefaultsToEmpty() public view {
        IGenericTokenFactory.TokenInfo memory info = factory.tokenInfo(address(0x2222));
        assertEq(info.originToken, address(0), "default origin should be zero");
        assertEq(info.chainId, 0, "default chainId should be zero");
        assertEq(info.deployed, false, "default deployed should be false");
    }

    // ========== Token Deployment Tests ==========

    function testDeployTokenEmitsEvent() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        vm.recordLogs();
        address deployed = factory.deployToken(keyData, deployArgs);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == keccak256("TokenDeployed(address,address)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), ORIGIN_TOKEN, "origin in event mismatch");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), deployed, "deployed in event mismatch");
                found = true;
                break;
            }
        }

        assertTrue(found, "TokenDeployed event should be emitted");
    }

    function testComputePeggedTokenAddressMatchesDeployment() public {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        address predicted = factory.computePeggedTokenAddress(keyData, deployArgs);
        address deployed = factory.deployToken(keyData, deployArgs);

        assertEq(deployed, predicted, "deployed address should match prediction");
    }

    function testComputeOtherSidePeggedTokenAddressMatchesLocal() public view {
        bytes memory keyData = abi.encode(ORIGIN_TOKEN);
        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        address thisChain = factory.computePeggedTokenAddress(keyData, deployArgs);
        address otherChain = factory.computeOtherSidePeggedTokenAddress(keyData, deployArgs);

        assertEq(thisChain, otherChain, "cross-chain addresses should match for same factory");
    }

    // ========== Multiple Deployments ==========

    function testMultipleTokenDeployments() public {
        address origin1 = address(0x1111);
        address origin2 = address(0x2222);
        address origin3 = address(0x3333);

        bytes memory deployArgs = abi.encode("Test", "TST", uint8(18));

        address token1 = factory.deployToken(abi.encode(origin1), deployArgs);
        address token2 = factory.deployToken(abi.encode(origin2), deployArgs);
        address token3 = factory.deployToken(abi.encode(origin3), deployArgs);

        assertTrue(token1 != token2 && token2 != token3 && token1 != token3, "all tokens should be unique");
        assertEq(factory.bridgedTokens(origin1), token1, "token1 mapping incorrect");
        assertEq(factory.bridgedTokens(origin2), token2, "token2 mapping incorrect");
        assertEq(factory.bridgedTokens(origin3), token3, "token3 mapping incorrect");
    }

    // ========== Edge Cases ==========

    function testGetDeployArgsEncoding() public view {
        bytes memory args = factory.getDeployArgs("MyToken", "MTK", 18);

        (string memory name, string memory symbol, uint8 decimals) = abi.decode(args, (string, string, uint8));

        assertTrue(keccak256(bytes(name)) == keccak256(bytes("MyToken")), "name mismatch");
        assertTrue(keccak256(bytes(symbol)) == keccak256(bytes("MTK")), "symbol mismatch");
        assertEq(decimals, 18, "decimals mismatch");
    }

    function testBeaconProxyBytecodeGeneration() public view {
        bytes memory bytecode = factory.beacon().code;
        assertTrue(bytecode.length > 0, "beacon should have code");
    }

    function testImplementationReturnsCorrectAddress() public view {
        address impl = factory.implementation();
        assertEq(impl, address(implementation), "implementation should match");
    }
}