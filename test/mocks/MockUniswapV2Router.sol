// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MockWETH.sol";
import "./MockUniswapV2Factory.sol";
import "./MockUniswapV2Pair.sol";

/// @notice Minimal Uniswap V2 Router mock for testing MemeFactory.
contract MockUniswapV2Router {
    MockWETH public immutable WETH;
    MockUniswapV2Factory public immutable factory;

    /*══════════════════════════════════════════════════════════════
              Public fields for test assertions (individual, not structs)
    ══════════════════════════════════════════════════════════════*/

    // ── last addLiquidityETH call ──
    address public lastLiqToken;
    uint256 public lastLiqAmountTokenDesired;
    uint256 public lastLiqAmountTokenMin;
    uint256 public lastLiqAmountETHMin;
    address public lastLiqTo;
    uint256 public lastLiqDeadline;
    uint256 public lastLiqEthSent;
    bool public lastLiqCalled;

    // ── last swapExactETHForTokens call ──
    uint256 public lastSwapAmountOutMin;
    address public lastSwapPath0;
    address public lastSwapPath1;
    address public lastSwapTo;
    uint256 public lastSwapDeadline;
    uint256 public lastSwapEthSent;
    uint256 public lastSwapTokensSent;
    bool public lastSwapCalled;

    /// @notice If set, swapExactETHForTokens "returns" this many tokens to `to`.
    uint256 public swapReturnAmount;

    /// @dev Allow tests to set swapReturnAmount from outside.
    function setSwapReturnAmount(uint256 amount) external {
        swapReturnAmount = amount;
    }

    constructor() {
        WETH = new MockWETH();
        factory = new MockUniswapV2Factory();
    }

    /// @notice Simulates addLiquidityETH: pulls approved tokens from caller
    ///         and records the call.
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        // Pull tokens from msg.sender (the factory)
        IERC20Minimal(token).transferFrom(msg.sender, address(this), amountTokenDesired);

        // Record call for assertions
        lastLiqToken = token;
        lastLiqAmountTokenDesired = amountTokenDesired;
        lastLiqAmountTokenMin = amountTokenMin;
        lastLiqAmountETHMin = amountETHMin;
        lastLiqTo = to;
        lastLiqDeadline = deadline;
        lastLiqEthSent = msg.value;
        lastLiqCalled = true;

        // In a real router, liquidity = sqrt(tokenAmount * ethAmount)
        liquidity = amountTokenDesired + msg.value;

        return (amountTokenDesired, msg.value, liquidity);
    }

    /// @notice Simulates swapExactETHForTokens: records the call and returns amounts.
    /// @dev    For testing purposes, actual token transfers are not needed —
    ///         we only verify that MemeFactory calls this with correct parameters.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (uint256[] memory amounts)
    {
        uint256 out = swapReturnAmount > 0 ? swapReturnAmount : msg.value * 1000;

        // Record call
        lastSwapAmountOutMin = amountOutMin;
        lastSwapPath0 = path[0];
        lastSwapPath1 = path[1];
        lastSwapTo = to;
        lastSwapDeadline = deadline;
        lastSwapEthSent = msg.value;
        lastSwapTokensSent = out;
        lastSwapCalled = true;

        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = out;

        return amounts;
    }

    /// @dev Lets tests pre-fund this router with tokens so swapExactETHForTokens works.
    function receiveTokens(address token, uint256 amount) external {
        IERC20Minimal(token).transferFrom(msg.sender, address(this), amount);
    }
}

/// @notice Minimal ERC20 subset used by the mock router.
interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
