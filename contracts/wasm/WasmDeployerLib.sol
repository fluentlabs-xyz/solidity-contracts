// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LEB128Lib} from "./LEB128Lib.sol";


/**
 * @dev A library to manage WASM bytecode deployment by wrapping constructor parameters into a custom section named "input" and concatenating it with the WASM binary. Constructor parameters must be pre-encoded by the caller and will be accessible in the smart contract context as "input" in the deploy() function.
 */
library WasmDeployerLib {
    function prepare(bytes memory wasmBytecode, bytes memory constructorParams) internal pure returns (bytes memory initCode) {
        bytes memory name = bytes("input");
        bytes memory nameSize = LEB128Lib.encode(name.length);
        bytes memory sectionSize = LEB128Lib.encode(name.length + nameSize.length + constructorParams.length);
        initCode = new bytes(
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
    }

    function deploy(bytes memory wasmBytecode, bytes memory constructorParams) internal returns (address contractAddress)
    {
        bytes memory initCode = prepare(wasmBytecode, constructorParams);
        assembly {
            contractAddress := create(0, add(initCode, 0x20), mload(initCode))
            if iszero(contractAddress) {
                revert(0, 0)
            }
        }
    }
}
