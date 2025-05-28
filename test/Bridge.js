const { expect } = require("chai");
const { BigNumber, AbiCoder } = require("ethers");
const { network } = require("hardhat");
const { ethers } = require("hardhat");

describe("Bridge", function () {
  let bridge;
  let rollup;

  before(async function () {
    const VerifierContract = await ethers.getContractFactory("VerifierMock");

    let verifier = await VerifierContract.deploy();
    const accounts = await hre.ethers.getSigners();
    const RollupContract = await ethers.getContractFactory("Rollup");
    const vkKey =
      "0x00612f9d5a388df116872ff70e36bcb86c7e73b1089f32f68fc8e0d0ba7861b7";
    const genesisHash =
      "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
    rollup = await RollupContract.deploy(
      accounts[0],
      0,
      0,
      0,
      verifier.target,
      vkKey,
      genesisHash,
      "0x0000000000000000000000000000000000000000",
      2,
      10,
      0,
    );

    const BridgeContract = await ethers.getContractFactory("Bridge");


    bridge = await BridgeContract.deploy(
      accounts[0].address,
      rollup.target,
      10,
    );
    bridge = await bridge.waitForDeployment();

    rollup.setBridge(bridge.target);
  });

  it("Send message test", async function () {
    const accounts = await hre.ethers.getSigners();
    const contractWithSigner = bridge.connect(accounts[0]);
    const origin_bridge_balance = await hre.ethers.provider.getBalance(
      bridge.target,
    );

    const send_tx = await contractWithSigner.sendMessage(
      "0x1111111111111111111111111111111111111111",
      "0x0102030405",
      { value: 2000 },
    );

    await send_tx.wait();

    const events = await bridge.queryFilter("SentMessage", send_tx.blockNumber);

    expect(events.length).to.equal(1);

    expect(events[0].args.sender).to.equal(await accounts[0].getAddress());

    console.log(events);

    let messageHash = events[0].args.messageHash;

    let depositHash = hre.ethers.keccak256(messageHash);

    console.log(depositHash);

    const bridge_balance = await hre.ethers.provider.getBalance(bridge.target);

    expect(bridge_balance - origin_bridge_balance).to.be.eql(2000n);

    try {
      const commitmentBatch = [
        {
          previousBlockHash:
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          blockHash:
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          withdrawalHash:
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          depositHash:
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        },
        {
          previousBlockHash:
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          blockHash:
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          withdrawalHash:
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
          depositHash:
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        },
      ];

      const rollupContractWithSigner = rollup.connect(accounts[0]);
      let nextBatchIndex = await rollupContractWithSigner.nextBatchIndex();
      await rollupContractWithSigner.acceptNextBatch(
        nextBatchIndex,
        commitmentBatch,
        [],
      );

      const secondsToAdvance = 86400 * 2; // 2 day

      await network.provider.send("evm_increaseTime", [secondsToAdvance]);
      await network.provider.send("evm_mine");

      nextBatchIndex = await rollupContractWithSigner.nextBatchIndex();
      await rollupContractWithSigner.acceptNextBatch(
        nextBatchIndex,
        commitmentBatch,
        [],
      );
    } catch (error) {
      expect(error.toString()).to.equal(
        "Error: VM Exception while processing transaction: " +
          "reverted with reason string 'deadline is overdue. Batch have to contains deposits'",
      );
    }

    const commitmentBatch = [
      {
        previousBlockHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        blockHash:
          "0xd16eb9c9f2fd1feef3fcefb569bdd8911d38b2f9f0fb86060add20287f57908e",
        withdrawalHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash: depositHash,
      },
      {
        previousBlockHash:
          "0xd16eb9c9f2fd1feef3fcefb569bdd8911d38b2f9f0fb86060add20287f57908e",
        blockHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        withdrawalHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
    ];
    const rollupContractWithSigner = rollup.connect(accounts[0]);

    let nextBatchIndex = await rollupContractWithSigner.nextBatchIndex();

    let queueSize = await contractWithSigner.getQueueSize();

    await rollupContractWithSigner.acceptNextBatch(
      nextBatchIndex,
      commitmentBatch,
      [
        {
          blockHash:
            "0xd16eb9c9f2fd1feef3fcefb569bdd8911d38b2f9f0fb86060add20287f57908e",
          depositCount: 1,
        },
      ],
    );
    let newQueueSize = await contractWithSigner.getQueueSize();

    expect(queueSize - newQueueSize).to.be.eql(1n);
  });

  it("Receive message test", async function () {
    const accounts = await hre.ethers.getSigners();
    const contractWithSigner = bridge.connect(accounts[0]);

    const receiverAddress = await accounts[1].getAddress();

    const origin_balance =
      await hre.ethers.provider.getBalance(receiverAddress);

    let nonce = await contractWithSigner.receivedNonce();

    const receive_tx = await contractWithSigner.receiveMessage(
      "0x1111111111111111111111111111111111111111",
      receiverAddress,
      200,
      1,
      10,
      nonce,
      "0x",
    );

    await receive_tx.wait();

    console.log(receive_tx);

    const events = await bridge.queryFilter(
      "ReceivedMessage",
      receive_tx.blockNumber,
    );

    console.log("With event: ", events);
    expect(events.length).to.equal(1);
    expect(events[0].args.messageHash).to.equal(
      "0x4dce65a8d545129b58933f3c6a6644b8d067b46131ca278af94e95a69f502e69",
    );
    expect(events[0].args.successfulCall).to.equal(true);

    const new_balance = await hre.ethers.provider.getBalance(receiverAddress);
    expect(new_balance - origin_balance).to.be.eql(200n);

    let messageStatus = await bridge.receivedMessage(
      events[0].args.messageHash,
    );
    console.log("Message status: ", messageStatus);

    try {
      const repeat_receive_tx = await contractWithSigner.receiveMessage(
        "0x1111111111111111111111111111111111111111",
        receiverAddress,
        200,
        1,
        10,
        nonce,
        "0x",
      );

      await repeat_receive_tx.wait();
    } catch (error) {
      expect(error.toString()).to.equal(
        "Error: VM Exception while processing transaction: " +
          "reverted with custom error 'MessageReceivedOutOfOrder()'",
      );
    }
  });

  it("Receive message with proof test", async function () {
    const accounts = await hre.ethers.getSigners();
    const rollupContractWithSigner = rollup.connect(accounts[0]);
    const receiverAddress = await accounts[1].getAddress();

    const contractWithSigner = bridge.connect(accounts[0]);

    let nonce = await contractWithSigner.receivedNonce();

    let messageHash = hre.ethers.keccak256(
      AbiCoder.defaultAbiCoder().encode(
        [
          "address",
          "address",
          "uint256",
          "uint256",
          "uint256",
          "uint256",
          "bytes",
        ],
        [
          "0x1111111111111111111111111111111111111111",
          receiverAddress,
          100,
          1,
          11,
          nonce,
          "0x",
        ],
      ),
    );

    let messageHash2 = hre.ethers.keccak256(
      AbiCoder.defaultAbiCoder().encode(
        [
          "address",
          "address",
          "uint256",
          "uint256",
          "uint256",
          "uint256",
          "bytes",
        ],
        [
          "0x1111111111111111111111111111111111111111",
          receiverAddress,
          200,
          1,
          0,
          nonce + 1n,
          "0x",
        ],
      ),
    );

    const withdrawalRoot = ethers.keccak256(
      AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "bytes32"],
        [messageHash, messageHash2],
      ),
    );
    console.log("mess ", messageHash, messageHash2, withdrawalRoot);

    const commitmentBatch = [
      {
        previousBlockHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        blockHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        withdrawalHash: withdrawalRoot,
        depositHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
      {
        previousBlockHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        blockHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        withdrawalHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
    ];

    const hashes = commitmentBatch.map((item) => {
      return hre.ethers.keccak256(
        AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes32", "bytes32", "bytes32"],
          [
            item.previousBlockHash,
            item.blockHash,
            item.withdrawalHash,
            item.depositHash,
          ],
        ),
      );
    });

    const merkleRoot = ethers.keccak256(
      AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "bytes32"],
        [hashes[0], hashes[1]],
      ),
    );

    let nextBatchIndex = await rollupContractWithSigner.nextBatchIndex();
    await rollupContractWithSigner.acceptNextBatch(
      nextBatchIndex,
      commitmentBatch,
      [],
    );

    let batchHash =
      await rollupContractWithSigner.acceptedBatchHash(nextBatchIndex);

    expect(merkleRoot).to.equal(batchHash);

    const origin_balance =
      await hre.ethers.provider.getBalance(receiverAddress);

    let receive_tx = await contractWithSigner.receiveMessageWithProof(
      nextBatchIndex,
      commitmentBatch[0],
      "0x1111111111111111111111111111111111111111",
      receiverAddress,
      100,
      1,
      11,
      nonce,
      "0x",
      {
        nonce: 0,
        proof: messageHash2,
      },
      {
        nonce: 0,
        proof: hashes[1],
      },
    );

    await receive_tx.wait();

    let events = await bridge.queryFilter(
      "ReceivedMessage",
      receive_tx.blockNumber,
    );
    console.log("Block: ", receive_tx.blockNumber);
    expect(events.length).to.equal(1);

    expect(events[0].args.messageHash).to.equal(messageHash);
    expect(events[0].args.successfulCall).to.equal(true);

    let new_balance = await hre.ethers.provider.getBalance(receiverAddress);
    expect(new_balance - origin_balance).to.be.eql(100n);
  });

  it("Fallback message test", async function () {
    const accounts = await hre.ethers.getSigners();
    const contractWithSigner = bridge.connect(accounts[0]);

    const receiverAddress = await accounts[1].getAddress();

    const origin_balance =
      await hre.ethers.provider.getBalance(receiverAddress);

    let nonce = await contractWithSigner.receivedNonce();

    const receive_tx = await contractWithSigner.receiveMessage(
      "0x1111111111111111111111111111111111111111",
      receiverAddress,
      200,
      1,
      0,
      nonce,
      "0x",
    );

    await receive_tx.wait();

    const events = await bridge.queryFilter(
      "RollbackMessage",
      receive_tx.blockNumber,
    );

    console.log("With event: ", events);
    expect(events.length).to.equal(1);
    expect(events[0].args.messageHash).to.equal(
      "0x80286cf205ed88deff46a298b6aaf81050edb80f0d97aa555c4f3e4ae4e310c3",
    );
    expect(events[0].args.blockNumber).to.equal(14n);

    const new_balance = await hre.ethers.provider.getBalance(receiverAddress);
    expect(new_balance - origin_balance).to.be.eql(0n);

    let messageStatus = await bridge.receivedMessage(
      events[0].args.messageHash,
    );
    console.log("Message status: ", messageStatus);
  });

  it("Rollback message test", async function () {
    const accounts = await hre.ethers.getSigners();
    const contractWithSigner = bridge.connect(accounts[0]);

    const receiverAddress = await accounts[1].getAddress();

    const origin_balance =
      await hre.ethers.provider.getBalance(receiverAddress);

    const send_tx = await contractWithSigner.sendMessage(
      "0x1111111111111111111111111111111111111111",
      "0x0102030405",
      { value: 2000 },
    );
    await send_tx.wait();

    const events = await bridge.queryFilter("SentMessage", send_tx.blockNumber);

    let messageHash = events[0].args.messageHash;
    let rollbackEvent = events[0];

    let nextBatchIndex = await rollup.nextBatchIndex();

    let previousBlock = await rollup.lastBlockHashInBatch(nextBatchIndex - 1n);

    const commitmentBatch = [
      {
        previousBlockHash: previousBlock,
        blockHash:
          "0x6214372ee997ea4da68e2816fbca6442b238632d173d1f5a6d9cd6692323c398",
        withdrawalHash: messageHash,
        depositHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
      {
        previousBlockHash:
          "0x6214372ee997ea4da68e2816fbca6442b238632d173d1f5a6d9cd6692323c398",
        blockHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        withdrawalHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        depositHash:
          "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      },
    ];

    const hashes = commitmentBatch.map((item) => {
      return hre.ethers.keccak256(
        AbiCoder.defaultAbiCoder().encode(
          ["bytes32", "bytes32", "bytes32", "bytes32"],
          [
            item.previousBlockHash,
            item.blockHash,
            item.withdrawalHash,
            item.depositHash,
          ],
        ),
      );
    });
    const rollupContractWithSigner = rollup.connect(accounts[0]);

    await rollupContractWithSigner.acceptNextBatch(
      nextBatchIndex,
      commitmentBatch,
      [],
    );

    let receive_tx = await contractWithSigner.rollbackMessageWithProof(
      nextBatchIndex,
      commitmentBatch[0],
      rollbackEvent.args["sender"],
      rollbackEvent.args["to"],
      rollbackEvent.args["value"].toString(),
      rollbackEvent.args["chainId"].toString(),
      rollbackEvent.args["blockNumber"].toString(),
      rollbackEvent.args["nonce"].toString(),
      rollbackEvent.args["data"],
      {
        nonce: 0,
        proof: "0x",
      },
      {
        nonce: 0,
        proof: hashes[1],
      },
    );
  });
});
