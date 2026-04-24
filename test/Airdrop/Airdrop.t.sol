// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test}           from "forge-std/Test.sol";
import {Airdrop}        from "../../contracts/airdrop/Airdrop.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";
import {EthRejecter}    from "../mocks/EthRejecter.sol";

abstract contract AirdropBase is Test {
    address internal owner    = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");

    MockERC20Token internal tok;
    uint256 internal constant ETH_PER = 0.001 ether;

    function setUp() public virtual {
        tok = new MockERC20Token("Tok", "TOK", 1_000_000 ether, owner);
        vm.label(address(tok), "TOK");
    }

    function _deploy(address[] memory recipients, uint96[] memory amounts)
        internal
        returns (Airdrop airdrop)
    {
        vm.prank(owner);
        airdrop = new Airdrop(tok, ETH_PER, recipients, amounts);
        vm.label(address(airdrop), "Airdrop");
    }

    function _fund(Airdrop airdrop, uint256 tokens, uint256 ethAmt) internal {
        vm.prank(owner);
        tok.transfer(address(airdrop), tokens);
        vm.deal(address(airdrop), ethAmt);
    }

    function _trio() internal view returns (address[] memory r, uint96[] memory a) {
        r = new address[](3);
        a = new uint96[](3);
        r[0] = alice; a[0] = 100 ether;
        r[1] = bob;   a[1] = 200 ether;
        r[2] = carol; a[2] = 300 ether;
    }
}

contract AirdropTest is AirdropBase {
    // ─── Constructor ────────────────────────────────────────────────────

    function test_constructor_populatesEntriesAndOwner() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);

        assertEq(airdrop.entriesLength(), 3, "entries length");
        (address r0, uint96 a0) = airdrop.entries(0);
        assertEq(r0, alice, "entry 0 recipient");
        assertEq(uint256(a0), 100 ether, "entry 0 amount");
        assertEq(airdrop.owner(), owner, "owner");
        assertEq(address(airdrop.token()), address(tok), "token");
        assertEq(airdrop.ethPerRecipient(), ETH_PER, "ethPerRecipient");
    }

    function test_RevertIf_constructor_lengthMismatch() public {
        address[] memory r = new address[](2);
        uint96[]  memory a = new uint96[](3);
        r[0] = alice; r[1] = bob;
        a[0] = 1; a[1] = 2; a[2] = 3;

        vm.expectRevert(Airdrop.LengthMismatch.selector);
        new Airdrop(tok, ETH_PER, r, a);
    }

    function test_RevertIf_constructor_emptyArrays() public {
        address[] memory r = new address[](0);
        uint96[]  memory a = new uint96[](0);

        vm.expectRevert(Airdrop.EmptyEntries.selector);
        new Airdrop(tok, ETH_PER, r, a);
    }

    function test_RevertIf_constructor_zeroRecipient() public {
        address[] memory r = new address[](2);
        uint96[]  memory a = new uint96[](2);
        r[0] = alice; r[1] = address(0);
        a[0] = 1;     a[1] = 2;

        vm.expectRevert(abi.encodeWithSelector(Airdrop.ZeroAddress.selector, uint256(1)));
        new Airdrop(tok, ETH_PER, r, a);
    }

    function test_RevertIf_constructor_zeroAmount() public {
        address[] memory r = new address[](2);
        uint96[]  memory a = new uint96[](2);
        r[0] = alice; r[1] = bob;
        a[0] = 1;     a[1] = 0;

        vm.expectRevert(abi.encodeWithSelector(Airdrop.ZeroAmount.selector, uint256(1)));
        new Airdrop(tok, ETH_PER, r, a);
    }

    // ─── _send guard ────────────────────────────────────────────────────

    function test_RevertIf_send_callerNotSelf() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);

        vm.expectRevert(Airdrop.NotSelf.selector);
        airdrop._send(alice, 1, 1);
    }

    // ─── Views ──────────────────────────────────────────────────────────

    function test_views_initialState() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);

        assertEq(airdrop.entriesLength(), 3, "length");
        assertFalse(airdrop.isDistributed(0), "bit 0 clear");
        assertFalse(airdrop.isDistributed(2), "bit 2 clear");
        assertEq(airdrop.totalTokensRequired(), 600 ether, "total tokens");
        assertEq(airdrop.totalEthRequired(), 3 * ETH_PER, "total eth");
    }

    // ─── distribute happy path ──────────────────────────────────────────

    function test_distribute_transfersTokensAndEth() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 600 ether, 3 * ETH_PER);

        vm.prank(owner);
        airdrop.distribute();

        assertEq(tok.balanceOf(alice), 100 ether, "alice tokens");
        assertEq(tok.balanceOf(bob),   200 ether, "bob tokens");
        assertEq(tok.balanceOf(carol), 300 ether, "carol tokens");
        assertEq(alice.balance, ETH_PER, "alice eth");
        assertEq(bob.balance,   ETH_PER, "bob eth");
        assertEq(carol.balance, ETH_PER, "carol eth");
        assertEq(tok.balanceOf(address(airdrop)), 0, "airdrop token balance");
        assertEq(address(airdrop).balance, 0, "airdrop eth balance");
    }

    function test_distribute_setsDistributedBitmap() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 600 ether, 3 * ETH_PER);

        vm.prank(owner);
        airdrop.distribute();

        assertTrue(airdrop.isDistributed(0), "bit 0");
        assertTrue(airdrop.isDistributed(1), "bit 1");
        assertTrue(airdrop.isDistributed(2), "bit 2");
        assertEq(airdrop.totalTokensRequired(), 0, "no tokens pending");
        assertEq(airdrop.totalEthRequired(),    0, "no eth pending");
    }

    function test_distribute_emitsAirdroppedPerEntry() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 600 ether, 3 * ETH_PER);

        vm.expectEmit(true, true, false, true, address(airdrop));
        emit Airdrop.Airdropped(0, alice, 100 ether, ETH_PER);
        vm.expectEmit(true, true, false, true, address(airdrop));
        emit Airdrop.Airdropped(1, bob, 200 ether, ETH_PER);
        vm.expectEmit(true, true, false, true, address(airdrop));
        emit Airdrop.Airdropped(2, carol, 300 ether, ETH_PER);

        vm.prank(owner);
        airdrop.distribute();
    }

    // ─── distribute reverts ─────────────────────────────────────────────

    function test_RevertIf_distribute_insufficientTokens() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 500 ether, 3 * ETH_PER);

        vm.expectRevert(
            abi.encodeWithSelector(
                Airdrop.InsufficientTokenBalance.selector,
                uint256(500 ether), uint256(600 ether)
            )
        );
        vm.prank(owner);
        airdrop.distribute();
    }

    function test_RevertIf_distribute_insufficientEth() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 600 ether, 2 * ETH_PER);

        vm.expectRevert(
            abi.encodeWithSelector(
                Airdrop.InsufficientEthBalance.selector,
                uint256(2 * ETH_PER), uint256(3 * ETH_PER)
            )
        );
        vm.prank(owner);
        airdrop.distribute();
    }

    function test_RevertIf_distribute_callerNotOwner() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 600 ether, 3 * ETH_PER);

        vm.prank(stranger);
        vm.expectRevert();
        airdrop.distribute();
    }

    // ─── Failure isolation ──────────────────────────────────────────────

    function test_distribute_ethRejecterEmitsFailureOthersSucceed() public {
        EthRejecter rejecter = new EthRejecter();
        vm.label(address(rejecter), "EthRejecter");

        address[] memory r = new address[](3);
        uint96[]  memory a = new uint96[](3);
        r[0] = alice;             a[0] = 100 ether;
        r[1] = address(rejecter); a[1] = 200 ether;
        r[2] = carol;             a[2] = 300 ether;

        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 600 ether, 3 * ETH_PER);

        vm.expectEmit(true, true, false, true, address(airdrop));
        emit Airdrop.Airdropped(0, alice, 100 ether, ETH_PER);
        vm.expectEmit(true, true, false, false, address(airdrop));
        emit Airdrop.AirdropFailed(1, address(rejecter));
        vm.expectEmit(true, true, false, true, address(airdrop));
        emit Airdrop.Airdropped(2, carol, 300 ether, ETH_PER);

        vm.prank(owner);
        airdrop.distribute();

        assertEq(tok.balanceOf(alice), 100 ether, "alice tokens");
        assertEq(tok.balanceOf(address(rejecter)), 0, "rejecter tokens rolled back");
        assertEq(tok.balanceOf(carol), 300 ether, "carol tokens");
        assertEq(address(rejecter).balance, 0, "rejecter eth");

        assertTrue(airdrop.isDistributed(0),  "bit 0");
        assertFalse(airdrop.isDistributed(1), "bit 1 clear");
        assertTrue(airdrop.isDistributed(2),  "bit 2");

        assertEq(tok.balanceOf(address(airdrop)), 200 ether, "unspent tokens");
        assertEq(address(airdrop).balance, ETH_PER, "unspent eth");
    }

    function test_distribute_afterReplacingRejecterSucceeds() public {
        EthRejecter rejecter = new EthRejecter();

        address[] memory r = new address[](3);
        uint96[]  memory a = new uint96[](3);
        r[0] = alice;             a[0] = 100 ether;
        r[1] = address(rejecter); a[1] = 200 ether;
        r[2] = carol;             a[2] = 300 ether;

        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 600 ether, 3 * ETH_PER);

        vm.prank(owner);
        airdrop.distribute();

        // Turn the rejecter into an EOA-style account that accepts ETH.
        vm.etch(address(rejecter), "");

        vm.prank(owner);
        airdrop.distribute();

        assertEq(tok.balanceOf(address(rejecter)), 200 ether, "rejecter tokens after retry");
        assertEq(address(rejecter).balance, ETH_PER, "rejecter eth after retry");
        assertTrue(airdrop.isDistributed(1), "bit 1 set after retry");
    }

    // ─── Idempotence ────────────────────────────────────────────────────

    function test_distribute_secondCallIsNoop() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, 600 ether, 3 * ETH_PER);

        vm.prank(owner);
        airdrop.distribute();

        uint256 aliceTokBefore = tok.balanceOf(alice);
        uint256 aliceEthBefore = alice.balance;

        _fund(airdrop, 600 ether, 3 * ETH_PER);
        uint256 airdropTokBefore = tok.balanceOf(address(airdrop));
        uint256 airdropEthBefore = address(airdrop).balance;

        vm.prank(owner);
        airdrop.distribute();

        assertEq(tok.balanceOf(alice), aliceTokBefore, "alice tokens unchanged");
        assertEq(alice.balance, aliceEthBefore, "alice eth unchanged");
        assertEq(tok.balanceOf(address(airdrop)), airdropTokBefore, "airdrop tokens unchanged");
        assertEq(address(airdrop).balance, airdropEthBefore, "airdrop eth unchanged");
    }

    // ─── distributeRange ────────────────────────────────────────────────

    function test_RevertIf_distributeRange_callerNotOwner() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);

        vm.prank(stranger);
        vm.expectRevert();
        airdrop.distributeRange(0, 3);
    }

    function test_RevertIf_distributeRange_rangeInvalid() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);

        vm.startPrank(owner);

        vm.expectRevert(Airdrop.RangeInvalid.selector);
        airdrop.distributeRange(2, 2);

        vm.expectRevert(Airdrop.RangeInvalid.selector);
        airdrop.distributeRange(0, 4);

        vm.expectRevert(Airdrop.RangeInvalid.selector);
        airdrop.distributeRange(3, 1);

        vm.stopPrank();
    }

    function test_distributeRange_splitIntoTwoCallsCoversAll() public {
        uint256 N = 200;
        address[] memory r = new address[](N);
        uint96[]  memory a = new uint96[](N);
        for (uint256 i = 0; i < N; ++i) {
            r[i] = address(uint160(0x10000 + i));
            a[i] = 1 ether;
        }

        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, N * 1 ether, N * ETH_PER);

        vm.startPrank(owner);
        airdrop.distributeRange(0,   100);
        airdrop.distributeRange(100, 200);
        vm.stopPrank();

        for (uint256 i = 0; i < N; ++i) {
            assertTrue(airdrop.isDistributed(i), "bit set");
            assertEq(tok.balanceOf(r[i]), 1 ether, "tokens");
            assertEq(r[i].balance, ETH_PER, "eth");
        }
        assertEq(tok.balanceOf(address(airdrop)), 0, "airdrop drained");
    }

    // ─── rescue ─────────────────────────────────────────────────────────

    function test_rescue_ethSweepsBalance() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        vm.deal(address(airdrop), 5 ether);

        address payable sink = payable(makeAddr("sink"));

        vm.expectEmit(true, true, false, true, address(airdrop));
        emit Airdrop.Rescued(address(0), sink, 5 ether);

        vm.prank(owner);
        airdrop.rescue(address(0), sink);

        assertEq(sink.balance, 5 ether, "sink eth");
        assertEq(address(airdrop).balance, 0, "airdrop drained");
    }

    function test_rescue_tokenSweepsBalance() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);
        vm.prank(owner);
        tok.transfer(address(airdrop), 700 ether);

        address sink = makeAddr("sink");

        vm.expectEmit(true, true, false, true, address(airdrop));
        emit Airdrop.Rescued(address(tok), sink, 700 ether);

        vm.prank(owner);
        airdrop.rescue(address(tok), sink);

        assertEq(tok.balanceOf(sink), 700 ether, "sink tokens");
        assertEq(tok.balanceOf(address(airdrop)), 0, "airdrop drained");
    }

    function test_RevertIf_rescue_callerNotOwner() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);

        vm.prank(stranger);
        vm.expectRevert();
        airdrop.rescue(address(0), stranger);
    }

    function test_RevertIf_rescue_zeroDestination() public {
        (address[] memory r, uint96[] memory a) = _trio();
        Airdrop airdrop = _deploy(r, a);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Airdrop.ZeroAddress.selector, uint256(0)));
        airdrop.rescue(address(0), address(0));
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────

    function testFuzz_distribute_variableEntryCountAndAmounts(uint8 rawN, uint96 baseAmt) public {
        uint256 n = bound(uint256(rawN), 1, 250);
        // Keep n * amt below the owner's mint (1,000,000 ether).
        uint96  amt = uint96(bound(uint256(baseAmt), 1, (1_000_000 ether) / n));

        address[] memory r = new address[](n);
        uint96[]  memory a = new uint96[](n);
        uint256 totalTokens;
        for (uint256 i = 0; i < n; ++i) {
            r[i] = address(uint160(0x20000 + i));
            a[i] = amt;
            totalTokens += amt;
        }

        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, totalTokens, n * ETH_PER);

        vm.prank(owner);
        airdrop.distribute();

        for (uint256 i = 0; i < n; ++i) {
            assertEq(tok.balanceOf(r[i]), amt, "recipient tokens");
            assertEq(r[i].balance, ETH_PER, "recipient eth");
            assertTrue(airdrop.isDistributed(i), "bit set");
        }
        assertEq(tok.balanceOf(address(airdrop)), 0, "airdrop drained");
    }

    // ─── Gas ────────────────────────────────────────────────────────────

    function test_distribute_gas_200entries() public {
        uint256 N = 200;
        address[] memory r = new address[](N);
        uint96[]  memory a = new uint96[](N);
        for (uint256 i = 0; i < N; ++i) {
            r[i] = address(uint160(0x30000 + i));
            a[i] = 1 ether;
        }

        Airdrop airdrop = _deploy(r, a);
        _fund(airdrop, N * 1 ether, N * ETH_PER);

        vm.prank(owner);
        vm.startSnapshotGas("Airdrop_distribute_200");
        airdrop.distribute();
        uint256 gasUsed = vm.stopSnapshotGas();

        assertLt(gasUsed, 50_000_000, "distribute 200 under 50M gas");
    }
}
