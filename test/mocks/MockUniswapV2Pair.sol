// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Uniswap V2 Pair mock for testing.
contract MockUniswapV2Pair {
    address public token0;
    address public token1;

    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;

    function setTokens(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves()
        external
        view
        returns (uint112, uint112, uint32)
    {
        return (reserve0, reserve1, blockTimestampLast);
    }
}
