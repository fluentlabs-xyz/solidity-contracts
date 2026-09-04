// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @title Pinned drand quicknet beacon vectors.
/// @notice Real rounds of chain
///         `52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971`
///         (scheme `bls-unchained-g1-rfc9380`, period 3 s, genesis 1692803367),
///         fetched from `api.drand.sh`, decompressed, and confirmed by a live
///         EIP-2537 `PAIRING` call. `randomness` is the API's own field and equals
///         `sha256(compressed)`. Synthetic signatures cannot satisfy the pairing,
///         so every drand test in this repo runs on these.
/// @dev Round 8193 shares ring slot `8193 % 8192 == 1` with round 1: it is the
///      eviction pair the retention tests use.
library DrandQuicknetVectors {
    uint64 internal constant GENESIS_TIMESTAMP = 1_692_803_367;
    uint64 internal constant PERIOD_SECONDS = 3;

    struct Vector {
        uint64 round;
        uint256 publishTime;
        bytes compressed; // 48 B zcash form — the bytes drand serves
        bytes uncompressed; // 128 B EIP-2537 G1 — the bytes `publish` takes
        bytes32 randomness; // drand's published `randomness` = sha256(compressed)
    }

    bytes internal constant ROUND_1_COMPRESSED =
        hex"b55e7cb2d5c613ee0b2e28d6750aabbb78c39dcc96bd9d38c2c2e12198df95571de8e8e402a0cc48871c7089a2b3af4b";
    bytes internal constant ROUND_1_UNCOMPRESSED =
        hex"00000000000000000000000000000000155e7cb2d5c613ee0b2e28d6750aabbb78c39dcc96bd9d38c2c2e12198df95571de8e8e402a0cc48871c7089a2b3af4b000000000000000000000000000000000fbb74ee8788264320f2501b0fa0dd56363bcec5ce4b113b2bf1de6e331116c79191af99234824f03aeb10ab1c4c7771";
    bytes32 internal constant ROUND_1_RANDOMNESS = 0x1466a6cd24e327188770752f6134001c64d6efcc590ccc26b721611ad96f165a;

    bytes internal constant ROUND_8193_COMPRESSED =
        hex"8632896dc6436e5757a55efaa7b3eea5d1027dc6ac1a0dca90dcff21504117b8a525296fa25a86a5c8b972adf7bfa366";
    bytes internal constant ROUND_8193_UNCOMPRESSED =
        hex"000000000000000000000000000000000632896dc6436e5757a55efaa7b3eea5d1027dc6ac1a0dca90dcff21504117b8a525296fa25a86a5c8b972adf7bfa36600000000000000000000000000000000040606f4a5330d47a6cd11cb9add082bd6771a1ad342f7ae79a7a33ec9ecd750d9e0603868b3af0aeeef647885cd8c36";
    bytes32 internal constant ROUND_8193_RANDOMNESS =
        0x4c0bf8e1e0091137dabdba0acdd89fddc3641deb037a4c6be948899ccfd300e5;

    bytes internal constant ROUND_10M_COMPRESSED =
        hex"a187c9f5800521e986b5658924696682071ce7ae965486e8fd08bc2c4758bdbb9ed9ecb7beee392a38214e321ecd434f";
    bytes internal constant ROUND_10M_UNCOMPRESSED =
        hex"000000000000000000000000000000000187c9f5800521e986b5658924696682071ce7ae965486e8fd08bc2c4758bdbb9ed9ecb7beee392a38214e321ecd434f0000000000000000000000000000000018612fe359547c50565157274bc00fceff8527b1fe7c6751aadfbec85d0c2411cdfe9a38c49b7fa24810517224de9f12";
    bytes32 internal constant ROUND_10M_RANDOMNESS = 0x5e6508f1a1f689accfc8b027dec7eb999b20b4f66582b2621231cabf9601bf57;

    bytes internal constant ROUND_31799517_COMPRESSED =
        hex"b7a6d29a93f17085866bf67bed95be9c3b46fd74e7cab12bbf91340f27d99ecc83bc5d46ff4b2b4c6f28aa975bf69fcc";
    bytes internal constant ROUND_31799517_UNCOMPRESSED =
        hex"0000000000000000000000000000000017a6d29a93f17085866bf67bed95be9c3b46fd74e7cab12bbf91340f27d99ecc83bc5d46ff4b2b4c6f28aa975bf69fcc00000000000000000000000000000000187382ceb6f69f7fbb17e28418753a4503e388b32ed4bda896b9b384d5eb49c8c642ee5b2315bbe16c31a99d655fb52a";
    bytes32 internal constant ROUND_31799517_RANDOMNESS =
        0x1e3f931ad3c2321e8c572135aabc96e27ce6cf1e5a807f0b4aa073622b946ada;

    function round1() internal pure returns (Vector memory) {
        return Vector(1, 1_692_803_367, ROUND_1_COMPRESSED, ROUND_1_UNCOMPRESSED, ROUND_1_RANDOMNESS);
    }

    function round8193() internal pure returns (Vector memory) {
        return Vector(8193, 1_692_827_943, ROUND_8193_COMPRESSED, ROUND_8193_UNCOMPRESSED, ROUND_8193_RANDOMNESS);
    }

    function round10M() internal pure returns (Vector memory) {
        return Vector(10_000_000, 1_722_803_364, ROUND_10M_COMPRESSED, ROUND_10M_UNCOMPRESSED, ROUND_10M_RANDOMNESS);
    }

    function round31799517() internal pure returns (Vector memory) {
        return Vector(
            31_799_517, 1_788_201_915, ROUND_31799517_COMPRESSED, ROUND_31799517_UNCOMPRESSED, ROUND_31799517_RANDOMNESS
        );
    }

    /// @notice Every pinned vector, for suites that assert the same property on all of them.
    function all() internal pure returns (Vector[] memory v) {
        v = new Vector[](4);
        v[0] = round1();
        v[1] = round8193();
        v[2] = round10M();
        v[3] = round31799517();
    }
}
