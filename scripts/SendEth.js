/**
 * Send ETH from FLUENT_LOCAL_PRIVATE_KEY account to a recipient.
 * Usage: RECIPIENT=0x... FLUENT_RPC_URL=http://127.0.0.1:8545 FLUENT_LOCAL_PRIVATE_KEY=0x... npx hardhat run scripts/SendEth.js --network fluent-local
 * Or with amount: AMOUNT_ETH=0.01 RECIPIENT=0x... ...
 */
const { ethers } = require("hardhat");

async function main() {
    const recipient = process.env.RECIPIENT || "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const amountEth = process.env.AMOUNT_ETH || "0.01";

    const [signer] = await ethers.getSigners();
    const from = await signer.getAddress();

    const balance = await ethers.provider.getBalance(from);
    console.log("From:", from);
    console.log("Balance:", ethers.formatEther(balance), "ETH");
    console.log("To:", recipient);
    console.log("Amount:", amountEth, "ETH");

    const tx = await signer.sendTransaction({
        to: recipient,
        value: ethers.parseEther(amountEth),
    });
    console.log("Tx hash:", tx.hash);
    const receipt = await tx.wait();
    console.log("Block:", receipt.blockNumber, "Status:", receipt.status === 1 ? "ok" : "failed");

    const newBalance = await ethers.provider.getBalance(from);
    console.log("New balance:", ethers.formatEther(newBalance), "ETH");
}

main()
    .then(() => process.exit(0))
    .catch(err => {
        console.error(err);
        process.exit(1);
    });
