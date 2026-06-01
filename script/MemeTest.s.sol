// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MemeFactory.sol";
import "../src/MemeToken.sol";

/// @notice Complete test script: deploy + mint + verify
/// @dev Usage:
///      1. Set PRIVATE_KEY: export PRIVATE_KEY=0x...
///      2. Run: forge script script/MemeTest.s.sol --rpc-url <RPC> --broadcast
contract MemeTest is Script {
    // Test params
    string constant SYMBOL = "DOGE";
    uint256 constant TOTAL_SUPPLY = 1_000_000e18;  // 1M tokens
    uint256 constant PER_MINT = 100_000e18;        // 100k per mint
    uint256 constant PRICE = 0.1 ether;            // 0.1 ETH per mint

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Optional: set feeCollector, defaults to deployer
        address feeCollector = vm.envOr("FEE_COLLECTOR", deployer);

        console.log("=== Meme Platform Test Script ===");
        console.log("Deployer:    ", deployer);
        console.log("FeeCollector:", feeCollector);
        console.log("");

        vm.startBroadcast(deployerKey);

        // 1. Deploy MemeFactory
        console.log("1. Deploy MemeFactory...");
        MemeFactory factory = new MemeFactory(feeCollector);
        console.log("   Factory addr:  ", address(factory));
        console.log("   Implementation:", factory.implementation());
        console.log("");

        // 2. Deploy Meme Token
        console.log("2. Deploy Meme Token...");
        console.log("   Symbol:      ", SYMBOL);
        console.log("   TotalSupply: ", TOTAL_SUPPLY);
        console.log("   PerMint:     ", PER_MINT);
        console.log("   Price:       ", PRICE);

        address tokenAddr = factory.deployMeme(SYMBOL, TOTAL_SUPPLY, PER_MINT, PRICE);
        console.log("   Token addr:  ", tokenAddr);
        console.log("");

        // 3. Mint Tokens
        console.log("3. Mint Tokens (mintMeme)...");
        console.log("   Payment:     ", PRICE);

        factory.mintMeme{value: PRICE}(tokenAddr);
        console.log("   Mint success!");
        console.log("");

        vm.stopBroadcast();

        // 4. Verify Results (read-only)
        console.log("=== Verification Results ===");
        _verifyToken(tokenAddr, deployer);
    }

    function _verifyToken(address tokenAddr, address deployer) internal view {
        MemeToken token = MemeToken(tokenAddr);

        console.log("Token Name:    ", token.name());
        console.log("Token Symbol:  ", token.symbol());
        console.log("Decimals:      ", token.decimals());
        console.log("Total Supply:  ", token.totalSupply());
        console.log("Per Mint:      ", token.perMint());
        console.log("Price (wei):   ", token.price());
        console.log("Deployer:      ", token.deployer());
        console.log("Minted:        ", token.minted());
        console.log("Remaining:     ", token.remaining());
        console.log("Deployer Balance:", token.balanceOf(deployer));
    }
}