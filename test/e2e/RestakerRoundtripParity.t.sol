// SPDX-License-Identifier: MIT
// E2E purpose: restaker happy-path parity on dual-fork setup.
// Flow direction: L2 restake -> L1 pegged mint (proof path) -> L2 unstake queue (authority path).
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import "../../contracts/ERC20PeggedToken.sol";
import "../../contracts/ERC20TokenFactory.sol";
import "../../contracts/RestakerGateway.sol";
import "../../contracts/mocks/DelegationManagerMock.sol";
import "../../contracts/mocks/EigenPodManagerMock.sol";
import "../../contracts/mocks/EigenPodMock.sol";
import "../../contracts/restaker/LiquidityToken.sol";
import "../../contracts/restaker/ProtocolConfig.sol";
import "../../contracts/restaker/RatioFeed.sol";
import "../../contracts/restaker/RestakingPool.sol";
import "../../contracts/restaker/interfaces/IDelegationManager.sol";
import "../../contracts/restaker/interfaces/IEigenPodManager.sol";
import "../../contracts/restaker/interfaces/IETHPOSDeposit.sol";
import "../../contracts/restaker/interfaces/ISlasher.sol";
import "../../contracts/restaker/interfaces/IStrategyManager.sol";
import "../../contracts/restaker/restaker/Restaker.sol";
import "../../contracts/restaker/restaker/RestakerDeployer.sol";
import "../../contracts/restaker/restaker/RestakerFacets.sol";
import "../../contracts/rollup/Rollup.sol";
import "./BaseDualFork.t.sol";

contract RestakerRoundtripParityTest is BaseDualFork {
    uint256 internal constant RESTAKE_AMOUNT = 32 ether;
    uint256 internal constant RATIO = 1000;
    string internal constant RESTAKER_PROVIDER = "RESTAKER_PROVIDER";

    RestakerGateway internal l2RestakerGateway;
    RestakerGateway internal l1RestakerGateway;

    ProtocolConfig internal l2ProtocolConfig;
    RatioFeed internal l2RatioFeed;
    LiquidityToken internal l2LiquidityToken;
    RestakingPool internal l2RestakingPool;

    ERC20PeggedToken internal l2RestakerPeggedImpl;
    ERC20TokenFactory internal l2RestakerFactory;
    ERC20PeggedToken internal l1RestakerPeggedImpl;
    ERC20TokenFactory internal l1RestakerFactory;

    function setUp() public {
        _setUpDualFork();
        _deployL2RestakerStack();
        _deployL1RestakerGateway();
        _linkRestakerGateways();
    }

    function test_restakerComparePeggedTokenAddresses() public {
        // Step 1: Compare deterministic pegged-token address derivation across both restaker gateways.
        _switchToL1();
        _assertOnL1();
        address peggedOnL1 = l1RestakerGateway.computePeggedTokenAddress(
            address(l2LiquidityToken)
        );

        _switchToL2();
        _assertOnL2();
        address peggedFromL2View =
            l2RestakerGateway.computeOtherSidePeggedTokenAddress(
                address(l2LiquidityToken)
            );

        assertEq(
            peggedOnL1,
            peggedFromL2View,
            "restaker pegged-token address parity mismatch"
        );
    }

    function test_restakedRoundtrip_sendClaimUnstake() public {
        // Step 1: L2 user restakes ETH through L2 restaker gateway and emits L2->L1 bridge message.
        _switchToL2();
        _assertOnL2();
        vm.deal(USER_A, RESTAKE_AMOUNT);

        vm.prank(USER_A);
        vm.recordLogs();
        l2RestakerGateway.sendRestakedTokens{value: RESTAKE_AMOUNT}(USER_B);
        VmFork.Log[] memory l2Logs = vm.getRecordedLogs();

        SentMessageData memory l2ToL1 = _findSentMessage(l2Logs, address(l2.bridge));
        uint256 mintedShares = l2LiquidityToken.balanceOf(address(l2RestakerGateway));
        assertEq(
            mintedShares,
            l2LiquidityToken.convertToShares(RESTAKE_AMOUNT),
            "unexpected minted liquidity shares on L2 gateway"
        );

        // Step 2: L1 sequencer accepts withdrawal batch with DA enabled.
        _switchToL1();
        _assertOnL1();
        bytes32 batch1BlockHash = keccak256("RESTAKER-BATCH-1");
        Rollup.BlockCommitment memory batch1Commitment = _buildCommitment(
            MOCK_GENESIS_HASH,
            batch1BlockHash,
            l2ToL1.messageHash,
            ZERO_HASH
        );
        _acceptSingleCommitmentBatchL1(
            1,
            batch1Commitment,
            new Rollup.DepositsInBlock[](0)
        );

        // Step 3: L1 processes withdrawal proof and mints pegged liquidity token.
        vm.roll(block.number + 1);
        MerkleTree.MerkleProof memory proof = _singleLeafProof();
        l1.bridge.receiveMessageWithProof(
            1,
            batch1Commitment,
            l2ToL1.sender,
            payable(l2ToL1.to),
            l2ToL1.value,
            l2ToL1.chainId,
            l2ToL1.blockNumber,
            l2ToL1.nonce,
            l2ToL1.data,
            proof,
            proof
        );

        address l1PeggedTokenAddress = l1RestakerGateway.computePeggedTokenAddress(
            address(l2LiquidityToken)
        );
        ERC20PeggedToken l1PeggedToken = ERC20PeggedToken(l1PeggedTokenAddress);
        assertEq(
            l1PeggedToken.balanceOf(USER_B),
            mintedShares,
            "L1 restaker pegged token mint mismatch"
        );
        assertEq(
            uint256(l1.bridge.receivedMessage(l2ToL1.messageHash)),
            uint256(Bridge.MessageStatus.Success),
            "L1 restaker message status should be success"
        );

        // Step 4: L1 user sends unstaking request back to L2 via restaker gateway.
        uint256 unstakeShares = mintedShares / 2;
        vm.startPrank(USER_B);
        l1PeggedToken.approve(address(l1RestakerGateway), unstakeShares);
        vm.recordLogs();
        l1RestakerGateway.sendUnstakingTokens(USER_A, unstakeShares);
        VmFork.Log[] memory l1Logs = vm.getRecordedLogs();
        vm.stopPrank();

        SentMessageData memory l1ToL2 = _findSentMessage(l1Logs, address(l1.bridge));
        assertEq(
            l1PeggedToken.balanceOf(USER_B),
            mintedShares - unstakeShares,
            "L1 pegged balance not reduced after unstake send"
        );
        assertEq(l1.bridge.getQueueSize(), 1, "L1 queue should grow by one message");

        // Step 5: L2 bridge authority executes unstake message; queue entry becomes pending unstake.
        _switchToL2();
        _assertOnL2();
        vm.prank(BRIDGE_AUTHORITY);
        l2.bridge.receiveMessage(
            l1ToL2.sender,
            l1ToL2.to,
            l1ToL2.value,
            l1ToL2.chainId,
            l1ToL2.blockNumber,
            l1ToL2.nonce,
            l1ToL2.data
        );

        uint256 expectedUnstakeAmount = l2LiquidityToken.convertToAmount(unstakeShares);
        assertEq(
            uint256(l2.bridge.receivedMessage(l1ToL2.messageHash)),
            uint256(Bridge.MessageStatus.Success),
            "L2 restaker message status should be success"
        );
        assertEq(
            l2RestakingPool.getTotalPendingUnstakes(),
            expectedUnstakeAmount,
            "pending unstake amount mismatch"
        );
        assertEq(
            l2LiquidityToken.balanceOf(address(l2RestakerGateway)),
            mintedShares - unstakeShares,
            "L2 gateway shares not burned on unstake"
        );

        // Step 6: L1 sequencer accepts deposit batch and consumes L1 bridge queue.
        _switchToL1();
        _assertOnL1();
        bytes32 batch2BlockHash = keccak256("RESTAKER-BATCH-2");
        bytes32 depositHash = keccak256(abi.encodePacked(l1ToL2.messageHash));
        Rollup.BlockCommitment memory batch2Commitment = _buildCommitment(
            batch1Commitment.blockHash,
            batch2BlockHash,
            ZERO_HASH,
            depositHash
        );

        Rollup.DepositsInBlock[] memory deposits = new Rollup.DepositsInBlock[](1);
        deposits[0] = Rollup.DepositsInBlock({
            blockHash: batch2BlockHash,
            depositCount: 1
        });
        _acceptSingleCommitmentBatchL1(2, batch2Commitment, deposits);

        assertEq(l1.bridge.getQueueSize(), 0, "L1 queue should be consumed after deposit");
        assertEq(l1.rollup.nextBatchIndex(), 3, "unexpected rollup nextBatchIndex");

        // Step 7: L2 operator distributes unstakes and recipient claims unstaked ETH.
        _switchToL2();
        _assertOnL2();
        l2RestakingPool.distributeUnstakes();
        assertEq(
            l2RestakingPool.claimableOf(USER_A),
            expectedUnstakeAmount,
            "claimable unstake amount mismatch"
        );

        uint256 userABalanceBeforeClaim = USER_A.balance;
        vm.prank(USER_A);
        l2RestakingPool.claimUnstake(USER_A);
        assertEq(
            USER_A.balance,
            userABalanceBeforeClaim + expectedUnstakeAmount,
            "unstake claim did not transfer ETH"
        );
    }

    function _deployL2RestakerStack() internal {
        // L2 deployment side effect: creates restaker pool, liquidity token, and restaker gateway that lock shares.
        _switchToL2();
        _assertOnL2();

        l2ProtocolConfig = new ProtocolConfig(address(this), address(this), address(this));
        l2RatioFeed = new RatioFeed(l2ProtocolConfig, 40_000);
        l2ProtocolConfig.setRatioFeed(l2RatioFeed);

        l2LiquidityToken = new LiquidityToken(
            l2ProtocolConfig,
            "Liquidity Token",
            "lETH"
        );
        l2RatioFeed.updateRatio(address(l2LiquidityToken), RATIO);
        l2ProtocolConfig.setLiquidityToken(l2LiquidityToken);

        l2RestakingPool = new RestakingPool(l2ProtocolConfig, 200_000, 200 ether);
        l2ProtocolConfig.setRestakingPool(l2RestakingPool);

        l2RestakerPeggedImpl = new ERC20PeggedToken();
        l2RestakerFactory = new ERC20TokenFactory(address(l2RestakerPeggedImpl));
        l2RestakerGateway = new RestakerGateway(
            address(l2.bridge),
            payable(address(l2RestakingPool)),
            address(l2RestakerFactory)
        );
        l2RestakerFactory.transferOwnership(address(l2RestakerGateway));
        l2RestakerGateway.acceptTokenFactory();

        _deployRestakerProvider();
    }

    function _deployRestakerProvider() internal {
        // L2 provider side effect: wires deployer/facets so pool can register provider restaker.
        _assertOnL2();

        EigenPodMock podImpl = new EigenPodMock(
            IETHPOSDeposit(address(0)),
            address(0),
            IEigenPodManager(address(0)),
            0
        );
        UpgradeableBeacon podBeacon = new UpgradeableBeacon(
            address(podImpl),
            address(this)
        );

        EigenPodManagerMock eigenPodManager = new EigenPodManagerMock(
            IETHPOSDeposit(address(0)),
            IBeacon(address(podBeacon)),
            IStrategyManager(address(0)),
            ISlasher(address(0))
        );
        DelegationManagerMock delegationManager = new DelegationManagerMock();

        RestakerFacets restakerFacets = new RestakerFacets(
            address(this),
            IEigenPodManager(address(eigenPodManager)),
            IDelegationManager(address(delegationManager))
        );

        Restaker restakerImpl = new Restaker();
        UpgradeableBeacon restakerBeacon = new UpgradeableBeacon(
            address(restakerImpl),
            address(this)
        );

        RestakerDeployer restakerDeployer = new RestakerDeployer(
            address(restakerBeacon),
            restakerFacets
        );

        l2ProtocolConfig.setRestakerDeployer(restakerDeployer);
        l2RestakingPool.addRestaker(RESTAKER_PROVIDER);
    }

    function _deployL1RestakerGateway() internal {
        // L1 deployment side effect: configures destination restaker gateway that mints pegged liquidity token.
        _switchToL1();
        _assertOnL1();

        l1RestakerPeggedImpl = new ERC20PeggedToken();
        l1RestakerFactory = new ERC20TokenFactory(address(l1RestakerPeggedImpl));
        l1RestakerGateway = new RestakerGateway(
            address(l1.bridge),
            payable(address(0)),
            address(l1RestakerFactory)
        );
        l1RestakerFactory.transferOwnership(address(l1RestakerGateway));
        l1RestakerGateway.acceptTokenFactory();
        l1RestakerGateway.setLiquidityToken(address(l2LiquidityToken));
    }

    function _linkRestakerGateways() internal {
        // Linking side effect: enables message routing between L1/L2 restaker gateways.
        _switchToL2();
        _assertOnL2();
        l2RestakerGateway.setOtherSide(
            address(l1RestakerGateway),
            address(l1RestakerPeggedImpl),
            address(l1RestakerFactory)
        );

        _switchToL1();
        _assertOnL1();
        l1RestakerGateway.setOtherSide(
            address(l2RestakerGateway),
            address(l2RestakerPeggedImpl),
            address(l2RestakerFactory)
        );
    }
}
