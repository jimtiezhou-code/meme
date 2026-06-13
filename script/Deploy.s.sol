// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/MemeFactory.sol";

/// @notice Deploy the MemeFactory to an EVM chain.
/// @dev    Usage:
///
///         1. Keystore (推荐 for 生产环境):
///            forge script script/Deploy.s.sol \
///              --keystores default \
///              --broadcast
///            # 或指定路径:
///            forge script script/Deploy.s.sol \
///              --keystores /path/to/keystores \
///              --broadcast
///
///         2. Private key (开发测试):
///            forge script script/Deploy.s.sol \
///              --private-key 0x... \
///              --broadcast
///
///         3. Environment variable:
///            export PRIVATE_KEY=0x...
///            forge script script/Deploy.s.sol --broadcast
///
///         设置环境变量:
///            export FEE_COLLECTOR=0x...
///            export UNISWAP_ROUTER=0x...   # Uniswap V2 Router address
contract Deploy is Script {
    function run() public returns (MemeFactory factory) {
        address deployer = msg.sender;  // 会根据 --private-key 或 keystore 自动设置
        address feeCollector = vm.envOr("FEE_COLLECTOR", deployer);

        // Uniswap V2 Router — defaults to Ethereum mainnet address
        address uniswapRouter = vm.envOr(
            "UNISWAP_ROUTER",
            0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
        );

        vm.startBroadcast();
        factory = new MemeFactory(feeCollector, uniswapRouter);
        vm.stopBroadcast();

        console.log("MemeFactory deployed at:     ", address(factory));
        console.log("Implementation (MemeToken):  ", factory.implementation());
        console.log("Fee collector:               ", factory.feeCollector());
        console.log("Uniswap V2 Router:           ", address(factory.uniswapRouter()));
        console.log("Uniswap V2 Factory:          ", address(factory.uniswapFactory()));
        console.log("WETH:                        ", factory.WETH());
        console.log("Deployer:                    ", deployer);
    }
}
