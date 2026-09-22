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
///      eviction pair the retention tests use. Rounds 1000–1004 are the consecutive
///      span the batch tests use.
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

    bytes internal constant ROUND_1000_COMPRESSED =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";
    bytes internal constant ROUND_1000_UNCOMPRESSED =
        hex"00000000000000000000000000000000144679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e390000000000000000000000000000000011f92e4521ef54f047b64b85fa98db2d46f0f44add1f60b93f8a0dbddd63b34f238657c2d93aed18b90bddd60a01b6d2";
    bytes32 internal constant ROUND_1000_RANDOMNESS =
        0xfe290beca10872ef2fb164d2aa4442de4566183ec51c56ff3cd603d930e54fdd;

    bytes internal constant ROUND_1001_COMPRESSED =
        hex"b33bf3667cbd5a82de3a24b4e0e9fe5513cc1a0e840368c6e31f5fcfa79bea03f73896b25883abf2853d10337fb8fa41";
    bytes internal constant ROUND_1001_UNCOMPRESSED =
        hex"00000000000000000000000000000000133bf3667cbd5a82de3a24b4e0e9fe5513cc1a0e840368c6e31f5fcfa79bea03f73896b25883abf2853d10337fb8fa410000000000000000000000000000000015725954c8f0c9afc82902f9f39d202a4fbe48d7cd5ed3ab26c458f6773b385639e980a4fe3073672572fa77fbdbded0";
    bytes32 internal constant ROUND_1001_RANDOMNESS =
        0xb0a591ad1b9002cfc372ac6e30abd3da8d3088d4caae026961743474fb94235f;

    bytes internal constant ROUND_1002_COMPRESSED =
        hex"ab066f9c12dd6de1336fca0f925192fb0c72a771c3e4c82ede1fd362c1a770f9eb05843c6308ce2530b53a99c0281a6e";
    bytes internal constant ROUND_1002_UNCOMPRESSED =
        hex"000000000000000000000000000000000b066f9c12dd6de1336fca0f925192fb0c72a771c3e4c82ede1fd362c1a770f9eb05843c6308ce2530b53a99c0281a6e000000000000000000000000000000001311d877209ccf4e919ca24e5c2875844e1a77ab175b445f621b1f5b82ac19638e740205dfb8c075dd4ca8c55de03261";
    bytes32 internal constant ROUND_1002_RANDOMNESS =
        0x339d3f0e702ed27d36966c6ee85a2bc762a24e178e7e5c835d9b5a7509cb920c;

    bytes internal constant ROUND_1003_COMPRESSED =
        hex"b104c82771698f45fd8dcfead083d482694c31ab519bcef077f126f3736fe98c8392fd5d45d88aeb76b56ccfcb0296d7";
    bytes internal constant ROUND_1003_UNCOMPRESSED =
        hex"000000000000000000000000000000001104c82771698f45fd8dcfead083d482694c31ab519bcef077f126f3736fe98c8392fd5d45d88aeb76b56ccfcb0296d7000000000000000000000000000000000e9c397e1019389a95510880d20c04efcc296374fe4b4ed48ae7c4498e8ec713f4522ad6b4b3ebbcb6766e763343ede5";
    bytes32 internal constant ROUND_1003_RANDOMNESS =
        0x758f0c906d8c5296a032a66f0d96c6e0eeea4291e8fc9830bbfb19a2ba8610a9;

    bytes internal constant ROUND_1004_COMPRESSED =
        hex"a40658b820c0f8c10207524179a2031ba9537688a0d04e4851b58026be9a341fee3b96fb48ffad28483d84b40a5864aa";
    bytes internal constant ROUND_1004_UNCOMPRESSED =
        hex"00000000000000000000000000000000040658b820c0f8c10207524179a2031ba9537688a0d04e4851b58026be9a341fee3b96fb48ffad28483d84b40a5864aa0000000000000000000000000000000016d3a4f4e84b9bebe85f38361fa413055274577cab901490039f536e25cdd0e30d7f95aabcc174f8683974311ef40906";
    bytes32 internal constant ROUND_1004_RANDOMNESS =
        0x58af22b3402d77c3a0549dcc8a0ea36445b5c6e09dcdd1868e225c64d190a4f7;

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

    function round1000() internal pure returns (Vector memory) {
        return Vector(1000, 1_692_806_364, ROUND_1000_COMPRESSED, ROUND_1000_UNCOMPRESSED, ROUND_1000_RANDOMNESS);
    }

    function round1001() internal pure returns (Vector memory) {
        return Vector(1001, 1_692_806_367, ROUND_1001_COMPRESSED, ROUND_1001_UNCOMPRESSED, ROUND_1001_RANDOMNESS);
    }

    function round1002() internal pure returns (Vector memory) {
        return Vector(1002, 1_692_806_370, ROUND_1002_COMPRESSED, ROUND_1002_UNCOMPRESSED, ROUND_1002_RANDOMNESS);
    }

    function round1003() internal pure returns (Vector memory) {
        return Vector(1003, 1_692_806_373, ROUND_1003_COMPRESSED, ROUND_1003_UNCOMPRESSED, ROUND_1003_RANDOMNESS);
    }

    function round1004() internal pure returns (Vector memory) {
        return Vector(1004, 1_692_806_376, ROUND_1004_COMPRESSED, ROUND_1004_UNCOMPRESSED, ROUND_1004_RANDOMNESS);
    }

    /// @notice Every pinned vector, for suites that assert the same property on all of them.
    function all() internal pure returns (Vector[] memory v) {
        Vector[] memory run = consecutive();
        v = new Vector[](4 + run.length);
        v[0] = round1();
        v[1] = round8193();
        v[2] = round10M();
        v[3] = round31799517();
        for (uint256 i = 0; i < run.length; ++i) {
            v[4 + i] = run[i];
        }
    }

    /// @notice Rounds 1000–1004, consecutive and inside one retention window: the span
    ///         `publishBatch` is exercised on. Same rounds as the publisher's fixtures
    ///         (`crates/beacon/fixtures/quicknet_rounds.json` in `fluentlabs-xyz/drand-publisher`).
    function consecutive() internal pure returns (Vector[] memory v) {
        v = new Vector[](5);
        v[0] = round1000();
        v[1] = round1001();
        v[2] = round1002();
        v[3] = round1003();
        v[4] = round1004();
    }
}
