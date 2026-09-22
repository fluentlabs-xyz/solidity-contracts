// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DrandOracleFixture} from "./DrandOracleFixture.sol";

import {IDrandOracle} from "../../contracts/interfaces/oracles/IDrandOracle.sol";
import {DrandOracle} from "../../contracts/oracles/DrandOracle.sol";
import {DrandQuicknetVectors} from "../bls/DrandQuicknetVectors.sol";

contract DrandOraclePublishBatchTest is DrandOracleFixture {
    /// drand quicknet round 1010 is live at this timestamp: rounds 1000–1004 are public
    /// and inside the retention window.
    uint256 internal constant NOW = 1_692_803_367 + 1_009 * 3;

    DrandOracle internal oracle;
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        vm.warp(NOW);
        oracle = _deployOracle();
    }

    function _batch(DrandQuicknetVectors.Vector[] memory vectors)
        internal
        pure
        returns (uint64[] memory rounds, bytes memory signatures)
    {
        rounds = new uint64[](vectors.length);
        for (uint256 i = 0; i < vectors.length; ++i) {
            rounds[i] = vectors[i].round;
            signatures = bytes.concat(signatures, vectors[i].uncompressed);
        }
    }

    /// Every round lands, in order, with drand's own value, and the call reports the count.
    function test_publishBatch_storesEveryRound() public {
        DrandQuicknetVectors.Vector[] memory vectors = DrandQuicknetVectors.consecutive();
        (uint64[] memory rounds, bytes memory signatures) = _batch(vectors);

        for (uint256 i = 0; i < vectors.length; ++i) {
            vm.expectEmit(true, true, false, true, address(oracle));
            emit IDrandOracle.RoundPublished(vectors[i].round, anyone, vectors[i].randomness);
        }
        vm.prank(anyone);
        uint256 published = oracle.publishBatch(rounds, signatures);

        assertEq(published, vectors.length, "every round is written");
        for (uint256 i = 0; i < vectors.length; ++i) {
            assertEq(oracle.randomnessOf(vectors[i].round), vectors[i].randomness, "stored value is drand's");
        }
    }

    /// A round somebody already published is passed over, and its value does not change.
    function test_publishBatch_skipsRoundsAlreadyPublished() public {
        DrandQuicknetVectors.Vector[] memory vectors = DrandQuicknetVectors.consecutive();
        DrandQuicknetVectors.Vector memory early = vectors[2];
        oracle.publish(early.round, early.uncompressed);

        (uint64[] memory rounds, bytes memory signatures) = _batch(vectors);
        uint256 published = oracle.publishBatch(rounds, signatures);

        assertEq(published, vectors.length - 1, "the published round is skipped");
        for (uint256 i = 0; i < vectors.length; ++i) {
            assertEq(oracle.randomnessOf(vectors[i].round), vectors[i].randomness, "every round reads back");
        }
    }

    function test_RevertIf_publishBatch_everyRoundAlreadyPublished() public {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());
        oracle.publishBatch(rounds, signatures);

        vm.expectRevert(IDrandOracle.NothingToPublish.selector);
        oracle.publishBatch(rounds, signatures);
    }

    /// A batch of one is `publish` by another name.
    function test_publishBatch_ofOneMatchesPublish() public {
        DrandQuicknetVectors.Vector memory v = DrandQuicknetVectors.round1000();
        uint64[] memory rounds = new uint64[](1);
        rounds[0] = v.round;

        assertEq(oracle.publishBatch(rounds, v.uncompressed), 1, "one round written");
        assertEq(oracle.randomnessOf(v.round), v.randomness, "stored value is drand's");
    }

    function test_RevertIf_publishBatch_roundsNotAscending() public {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());

        uint64[] memory repeated = rounds;
        repeated[2] = repeated[1];
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundsNotAscending.selector, rounds[1], rounds[1]));
        oracle.publishBatch(repeated, signatures);

        (uint64[] memory descending, bytes memory sameSignatures) = _batch(DrandQuicknetVectors.consecutive());
        (descending[1], descending[2]) = (descending[2], descending[1]);
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundsNotAscending.selector, descending[1], descending[2]));
        oracle.publishBatch(descending, sameSignatures);
    }

    /// The window is checked on both ends, and the tail's revert names the chain's clock.
    function test_RevertIf_publishBatch_tailIsAheadOfTheClock() public {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());
        uint64 last = rounds[rounds.length - 1];
        vm.warp(oracle.publishTimeOf(last - 1));
        assertEq(oracle.currentRound(), last - 1, "the clock sits one round short of the tail");

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundInFuture.selector, last, last - 1));
        oracle.publishBatch(rounds, signatures);
    }

    function test_RevertIf_publishBatch_headIsBelowTheWindow() public {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());
        uint64 first = rounds[0];
        vm.warp(oracle.publishTimeOf(first + oracle.RING_ROUNDS()));
        assertEq(oracle.oldestRetainedRound(), first + 1, "the window floor sits one round past the head");

        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.RoundTooOld.selector, first, first + 1));
        oracle.publishBatch(rounds, signatures);
    }

    function test_RevertIf_publishBatch_isEmpty() public {
        vm.expectRevert(IDrandOracle.EmptyBatch.selector);
        oracle.publishBatch(new uint64[](0), "");
    }

    function test_RevertIf_publishBatch_isTooLarge() public {
        uint256 tooMany = oracle.MAX_BATCH_ROUNDS() + 1;
        uint64[] memory rounds = new uint64[](tooMany);
        for (uint256 i = 0; i < tooMany; ++i) {
            rounds[i] = uint64(1000 + i);
        }
        vm.expectRevert(abi.encodeWithSelector(IDrandOracle.BatchTooLarge.selector, tooMany, tooMany - 1));
        oracle.publishBatch(rounds, new bytes(tooMany * 128));
    }

    function test_RevertIf_publishBatch_signatureLengthDisagrees() public {
        (uint64[] memory rounds, bytes memory signatures) = _batch(DrandQuicknetVectors.consecutive());
        bytes memory longer = bytes.concat(signatures, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(IDrandOracle.InvalidSignatureLength.selector, longer.length, signatures.length)
        );
        oracle.publishBatch(rounds, longer);
    }

    /// One wrong signature fails the whole batch, and nothing — not even the right ones —
    /// is written.
    function test_RevertIf_publishBatch_signatureDoesNotVerify_storesNothing() public {
        DrandQuicknetVectors.Vector[] memory vectors = DrandQuicknetVectors.consecutive();
        (vectors[1].uncompressed, vectors[2].uncompressed) = (vectors[2].uncompressed, vectors[1].uncompressed);
        (uint64[] memory rounds, bytes memory signatures) = _batch(vectors);

        vm.expectRevert(IDrandOracle.InvalidBatchSignature.selector);
        oracle.publishBatch(rounds, signatures);

        for (uint256 i = 0; i < rounds.length; ++i) {
            assertFalse(oracle.isPublished(rounds[i]), "a failed batch writes nothing");
        }
    }
}
