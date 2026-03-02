// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {UniversalTokenSDK} from "../../contracts/libraries/UniversalTokenSDK.sol";
import {IUniversalToken} from "../../contracts/interfaces/IUniversalToken.sol";
import {FactoryTestBase} from "./FactoryTestBase.t.sol";

contract UniversalTokenSDKHarness {
    function createDeploymentData(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) external pure returns (bytes memory) {
        return UniversalTokenSDK.createDeploymentData(name, symbol, decimals, initialSupply, minter, pauser);
    }

    function stringToBytes32(string memory value) external pure returns (bytes32) {
        return UniversalTokenSDK.stringToBytes32(value);
    }

    function bytes32ToString(bytes32 value) external pure returns (string memory) {
        return UniversalTokenSDK.bytes32ToString(value);
    }

    function computeBridgeTokenSalt(address l1Token, uint256 chainId) external pure returns (bytes32) {
        return UniversalTokenSDK.computeBridgeTokenSalt(l1Token, chainId);
    }

    function deployToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 initialSupply,
        address minter,
        address pauser
    ) external returns (address) {
        return UniversalTokenSDK.deployToken(name, symbol, decimals, initialSupply, minter, pauser);
    }
}

contract UniversalTokenSDKTest is FactoryTestBase {
    UniversalTokenSDKHarness internal harness;

    function setUp() public {
        harness = new UniversalTokenSDKHarness();
    }

    function testCreateDeploymentDataHasMagicPrefixAndExpectedLength() public view {
        bytes memory data = harness.createDeploymentData("Token", "TKN", 18, 123, address(0x1111), address(0x2222));
        assertEq(data.length, 2180, "deployment payload length mismatch");

        bytes4 magic;
        assembly {
            magic := mload(add(data, 0x20))
        }
        require(magic == UniversalTokenSDK.UNIVERSAL_TOKEN_MAGIC_BYTES, "invalid magic bytes prefix");
    }

    function testStringToBytes32RoundTripForShortString() public view {
        bytes32 encoded = harness.stringToBytes32("HELLO");
        string memory decoded = harness.bytes32ToString(encoded);
        require(keccak256(bytes(decoded)) == keccak256(bytes("HELLO")), "round-trip conversion mismatch");
    }

    function testStringToBytes32TruncatesLongStringsTo32Bytes() public view {
        string memory longValue = "abcdefghijklmnopqrstuvwxyz1234567890LONG_SUFFIX";
        bytes32 encoded = harness.stringToBytes32(longValue);
        bytes memory original = bytes(longValue);
        bytes memory truncated = new bytes(32);

        for (uint256 i = 0; i < 32; i++) {
            truncated[i] = original[i];
        }

        require(encoded == bytes32(truncated), "string should be truncated to first 32 bytes");
    }

    function testComputeBridgeTokenSaltIsDeterministicAndDistinct() public view {
        address l1Token = address(0x1234);
        bytes32 saltA = harness.computeBridgeTokenSalt(l1Token, 1);
        bytes32 saltB = harness.computeBridgeTokenSalt(l1Token, 1);
        bytes32 saltC = harness.computeBridgeTokenSalt(l1Token, 2);
        bytes32 saltD = harness.computeBridgeTokenSalt(address(0x5678), 1);

        require(saltA == saltB, "same inputs must produce same salt");
        require(saltA != saltC, "different chain IDs must produce distinct salts");
        require(saltA != saltD, "different L1 tokens must produce distinct salts");
    }

    function testDeployTokenViaPrecompileRuntime() public {
        // This integration path is only executable when running against a Fluent runtime
        // where the Universal Token precompile behavior is available.
        if (UniversalTokenSDK.UNIVERSAL_TOKEN_RUNTIME.code.length == 0) return;

        string memory name = "SDK Token";
        string memory symbol = "SDK";
        uint8 decimals = 18;
        uint256 initialSupply = 1_000;
        address minter = address(this);
        address pauser = address(this);

        address token = harness.deployToken(name, symbol, decimals, initialSupply, minter, pauser);
        assertTrue(token != address(0), "deployment returned zero address");
        assertTrue(token.code.length > 0, "deployed token has no code");

        IUniversalToken universal = IUniversalToken(token);
        require(keccak256(bytes(universal.name())) == keccak256(bytes(name)), "name mismatch");
        require(keccak256(bytes(universal.symbol())) == keccak256(bytes(symbol)), "symbol mismatch");
        assertEq(uint256(universal.decimals()), uint256(decimals), "decimals mismatch");
        assertEq(universal.totalSupply(), initialSupply, "total supply mismatch");
    }
}
