// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library LEB128Lib {
    /// @dev Encodes `x` using unsigned LEB128 algorithm.
    /// See https://en.wikipedia.org/wiki/LEB128#Encode_unsigned_integer.
    function encode(uint256 x) internal pure returns (bytes memory result) {
        if (x == 0) return result = new bytes(1);
        /// @solidity memory-safe-assembly
        assembly {
            result := mload(0x40)
            let offset := add(result, 32)
            let i := offset
            for {} 1 {} {
                let nextByte := and(x, 0x7f)
                x := shr(7, x)
                if x {
                    nextByte := or(nextByte, 0x80)
                    mstore8(i, nextByte)
                    i := add(i, 1)
                    continue
                }
                mstore8(i, nextByte)
                i := add(i, 1)
                break
            }
            mstore(result, sub(i, offset))
            mstore(0x40, i)
        }
    }

    /// @dev Encodes `x` using signed LEB128 algorithm.
    /// See https://en.wikipedia.org/wiki/LEB128#Encode_signed_integer.
    function encode(int256 x) internal pure returns (bytes memory result) {
        if (x == 0) return result = new bytes(1);
        /// @solidity memory-safe-assembly
        assembly {
            result := mload(0x40)
            let offset := add(result, 32)
            let i := offset
            for {} 1 {} {
                let nextByte := and(x, 0x7f)
                let sign := shr(6, nextByte)
                x := sar(7, x)
                if iszero(or(and(iszero(x), iszero(sign)), and(iszero(not(x)), sign))) {
                    nextByte := or(nextByte, 0x80)
                    mstore8(i, nextByte)
                    i := add(i, 1)
                    continue
                }
                mstore8(i, nextByte)
                i := add(i, 1)
                break
            }
            mstore(result, sub(i, offset))
            mstore(0x40, i)
        }
    }
}

library WasmDeployerLib {
    function deploy(bytes memory wasmBytecode, bytes memory constructorParams)
        internal
        returns (address contractAddress)
    {
        bytes memory name = bytes("input");
        bytes memory nameSize = LEB128Lib.encode(name.length);
        bytes memory sectionSize = LEB128Lib.encode(name.length + nameSize.length + constructorParams.length);
        bytes memory initCode = new bytes(
            wasmBytecode.length +    // Original WASM bytecode
            1 +                      // Custom section type indicator (0x00 for custom sections)
            sectionSize.length +     // LEB128-encoded size of the section
            nameSize.length +        // LEB128-encoded length of the section name
            name.length +            // Section name ("input")
            constructorParams.length // Encoded constructor parameters
        );
        uint256 k = 0;
        for (uint i = 0; i < wasmBytecode.length; i++) {
            initCode[k++] = wasmBytecode[i];
        }
        initCode[k++] = 0x00;
        for (uint i = 0; i < sectionSize.length; i++) {
            initCode[k++] = sectionSize[i];
        }
        for (uint i = 0; i < nameSize.length; i++) {
            initCode[k++] = nameSize[i];
        }
        for (uint i = 0; i < name.length; i++) {
            initCode[k++] = name[i];
        }
        for (uint i = 0; i < constructorParams.length; i++) {
            initCode[k++] = constructorParams[i];
        }
        assembly {
            contractAddress := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(contractAddress) {
                revert(0, 0)
            }
        }
    }
}

contract WasmDeployer {
    event WasmContractDeployed(address addr);

    function deploy(bytes memory wasmBytecode, bytes memory constructorParams) public {
        address newContract = WasmDeployerLib.deploy(wasmBytecode, constructorParams);
        emit WasmContractDeployed(newContract);
    }
}
