// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {UniversalTokenFactory} from "../../contracts/factories/UniversalTokenFactory.sol";
import {IGenericTokenFactory} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {IGenericTokenFactoryErrors} from "../../contracts/interfaces/IGenericTokenFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FactoryTestBase} from "./FactoryTestBase.t.sol";

contract UniversalTokenFactoryHarness is UniversalTokenFactory {
    function setBridgedTokenForTest(address l1Token, address l2Token) external {
        _setBridgedToken(l1Token, l2Token);
    }

    function setTokenInfoForTest(address tokenAddress, address l1Token, uint256 chainId, bool deployed) external {
        _setTokenInfo(
            tokenAddress, IGenericTokenFactory.TokenInfo({originToken: l1Token, chainId: chainId, deployed: deployed})
        );
    }
}

contract UniversalTokenFactoryTest is FactoryTestBase {
    address internal constant ATTACKER = address(0xCAFE);

    UniversalTokenFactoryHarness internal factory;

    function setUp() public {
        UniversalTokenFactoryHarness implementation = new UniversalTokenFactoryHarness();
        bytes memory initData = abi.encodeCall(UniversalTokenFactory.initialize, (address(this)));
        factory = UniversalTokenFactoryHarness(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function testInitializeSetsOwner() public view {
        assertEq(factory.owner(), address(this), "owner mismatch");
    }

    function testComputeTokenAddressIsDeterministic() public view {
        bytes memory keyData = abi.encode(address(0x1111), block.chainid);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        address a = factory.computeTokenAddress(keyData, deployArgs);
        address b = factory.computeTokenAddress(keyData, deployArgs);

        assertEq(a, b, "compute token address should be deterministic");
        assertTrue(a != address(0), "computed address should not be zero");
    }

    function testSharedComputePeggedTokenAddressInterfaceMatchesComputeTokenAddress() public view {
        bytes memory keyData = abi.encode(address(0x1111), block.chainid);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));
        address a = factory.computeTokenAddress(keyData, deployArgs);
        address b = factory.computePeggedTokenAddress(keyData, deployArgs);

        assertEq(a, b, "shared pegged address interface mismatch");
    }

    function testComputeTokenAddressChangesWithL1Token() public view {
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));
        address a = factory.computeTokenAddress(abi.encode(address(0x1111), block.chainid), deployArgs);
        address b = factory.computeTokenAddress(abi.encode(address(0x2222), block.chainid), deployArgs);

        assertTrue(a != b, "different L1 tokens should produce different addresses");
    }

    function testComputeTokenAddressChangesWithChainId() public view {
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));
        address a = factory.computeTokenAddress(abi.encode(address(0x1111), uint256(1)), deployArgs);
        address b = factory.computeTokenAddress(abi.encode(address(0x1111), uint256(2)), deployArgs);

        assertTrue(a != b, "different chain IDs should produce different addresses");
    }

    function testDeployTokenRevertsForZeroL1Token() public {
        bytes memory keyData = abi.encode(address(0), block.chainid);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        vm.expectRevert(IGenericTokenFactoryErrors.InvalidOriginToken.selector);
        factory.deployToken(keyData, deployArgs);
    }

    function testDeployTokenRevertsForZeroChainId() public {
        bytes memory keyData = abi.encode(address(0x1111), uint256(0));
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        vm.expectRevert(IGenericTokenFactoryErrors.InvalidChainId.selector);
        factory.deployToken(keyData, deployArgs);
    }

    function testDeployTokenRevertsForWrongChainId() public {
        bytes memory keyData = abi.encode(address(0x1111), block.chainid + 1);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        vm.expectRevert(IGenericTokenFactoryErrors.WrongChainId.selector);
        factory.deployToken(keyData, deployArgs);
    }

    function testDeployTokenRevertsWhenTokenAlreadyBridged() public {
        address l1Token = address(0x1111);
        factory.setBridgedTokenForTest(l1Token, address(0x9999));
        bytes memory keyData = abi.encode(l1Token, block.chainid);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        vm.expectRevert(IGenericTokenFactoryErrors.TokenAlreadyDeployed.selector);
        factory.deployToken(keyData, deployArgs);
    }

    function testOnlyOwnerCanDeployToken() public {
        bytes memory keyData = abi.encode(address(0x1111), block.chainid);
        bytes memory deployArgs = abi.encode("Token", "TKN", uint8(18), uint256(0), address(0x1234), address(0x5678));

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        factory.deployToken(keyData, deployArgs);
    }

    function testBridgedTokensAndTokenInfoDefaultToZero() public view {
        address unknownL1 = address(0xAABB);
        address unknownL2 = address(0xCCDD);

        assertEq(factory.bridgedTokens(unknownL1), address(0), "default bridged token should be zero");

        IGenericTokenFactory.TokenInfo memory info = factory.tokenInfo(unknownL2);
        assertEq(info.originToken, address(0), "default token info origin token should be zero");
        assertEq(info.chainId, 0, "default token info chainId should be zero");
        assertEq(info.deployed, false, "default token info deployed flag should be false");
    }

    function testSetTokenInfoThroughHarnessUpdatesStorage() public {
        address tokenAddress = address(0x123456);
        address l1Token = address(0x654321);
        uint256 chainId = 31337;
        bool deployed = true;

        factory.setTokenInfoForTest(tokenAddress, l1Token, chainId, deployed);

        IGenericTokenFactory.TokenInfo memory info = factory.tokenInfo(tokenAddress);
        assertEq(info.originToken, l1Token, "token info origin token mismatch");
        assertEq(info.chainId, chainId, "token info chainId mismatch");
        assertEq(info.deployed, deployed, "token info deployed mismatch");
    }
}
