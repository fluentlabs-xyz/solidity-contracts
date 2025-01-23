// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @dev A Solidity library for encoding integers in the Little Endian Base 128 (LEB128) format, commonly utilized in WebAssembly (WASM). This implementation is sourced from https://github.com/Shungy/leb128-nooffset. For additional information, refer to https://en.wikipedia.org/wiki/LEB128.
 */
library LEB128Lib {
    /// @dev Encodes `x` using unsigned LEB128 algorithm.
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
