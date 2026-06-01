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
///         设置 FEE_COLLECTOR:
///            export FEE_COLLECTOR=0x...
contract Deploy is Script {
    function run() public returns (MemeFactory factory) {
        address deployer = msg.sender;  // 会根据 --private-key 或 keystore 自动设置
        address feeCollector = vm.envOr("FEE_COLLECTOR", deployer);

        vm.startBroadcast();
        factory = new MemeFactory(feeCollector);
        vm.stopBroadcast();

        console.log("MemeFactory deployed at:     ", address(factory));
        console.log("Implementation (MemeToken):  ", factory.implementation());
        console.log("Fee collector:               ", factory.feeCollector());
        console.log("Deployer:                    ", deployer);
    }
}