// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Clones.sol";
import "./MemeToken.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";

/// @notice ERC‑1967 / EIP‑1167 factory that deploys Meme tokens as minimal proxies
///         and handles minting with automatic Uniswap V2 liquidity provision.
contract MemeFactory {
    using Clones for address;

    /*══════════════════════════════════════════════════════════════
                                Events
    ══════════════════════════════════════════════════════════════*/

    /// @notice Emitted when a new Meme token is deployed.
    event MemeDeployed(
        address indexed token,
        address indexed deployer,
        string symbol,
        uint256 totalSupply,
        uint256 perMint,
        uint256 price
    );

    /// @notice Emitted each time someone mints a chunk.
    event Minted(
        address indexed token,
        address indexed buyer,
        uint256 amount,
        uint256 projectFee
    );

    /// @notice Emitted when liquidity is added to Uniswap V2.
    event LiquidityAdded(
        address indexed token,
        address indexed pair,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 liquidity
    );

    /// @notice Emitted when someone buys Meme tokens via Uniswap.
    event Bought(
        address indexed token,
        address indexed buyer,
        uint256 ethSpent,
        uint256 tokensReceived
    );

    /*══════════════════════════════════════════════════════════════
                            Constants
    ══════════════════════════════════════════════════════════════*/

    /// @notice Liquidity‑fee in basis points. 500 = 5 %.
    uint256 public constant PROJECT_FEE_BPS = 500;

    /// @notice Denominator for basis‑point math.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /*══════════════════════════════════════════════════════════════
                                State
    ══════════════════════════════════════════════════════════════*/

    /// @notice The single MemeToken implementation contract (never initialized).
    address public immutable implementation;

    /// @notice Address that receives the 1 % project fee on every mint.
    address public feeCollector;

    /// @notice Uniswap V2 Router contract.
    IUniswapV2Router public immutable uniswapRouter;

    /// @notice Uniswap V2 Factory contract (derived from the router).
    IUniswapV2Factory public immutable uniswapFactory;

    /// @notice Wrapped native token (WETH on Ethereum mainnet).
    address public immutable WETH;

    /*══════════════════════════════════════════════════════════════
                            Constructor
    ══════════════════════════════════════════════════════════════*/

    /// @param feeCollector_  Initial recipient of project fees.
    /// @param uniswapRouter_ Address of the Uniswap V2 Router.
    constructor(address feeCollector_, address uniswapRouter_) {
        require(feeCollector_ != address(0), "MemeFactory: feeCollector = 0");
        require(uniswapRouter_ != address(0), "MemeFactory: router = 0");

        // Deploy the implementation once. Its constructor locks it so no
        // clone can ever accidentally initialize the implementation itself.
        implementation = address(new MemeToken());
        feeCollector    = feeCollector_;

        uniswapRouter  = IUniswapV2Router(uniswapRouter_);
        uniswapFactory = IUniswapV2Factory(uniswapRouter.factory());
        WETH           = uniswapRouter.WETH();
    }

    /*══════════════════════════════════════════════════════════════
                        Deploy a Meme token
    ══════════════════════════════════════════════════════════════*/

    /// @notice Deploy a new Meme as a minimal proxy (≈ 200k gas vs 1M+).
    /// @param  symbol      ERC20 symbol (name is fixed to "Meme").
    /// @param  totalSupply Total supply to mint over time.
    /// @param  perMint     Tokens minted per call to mintMeme().
    /// @param  price       Cost in wei per perMint chunk.
    /// @return token       Address of the newly cloned proxy.
    function deployMeme(
        string calldata symbol,
        uint256 totalSupply,
        uint256 perMint,
        uint256 price
    ) external returns (address token) {
        require(bytes(symbol).length > 0, "MemeFactory: empty symbol");
        require(totalSupply > 0, "MemeFactory: totalSupply = 0");
        require(perMint > 0, "MemeFactory: perMint = 0");

        // EIP‑1167 minimal proxy — cheap as chips
        token = implementation.clone();

        // Initialise the proxy storage via delegatecall
        MemeToken(token).initialize(symbol, totalSupply, perMint, price, msg.sender);

        emit MemeDeployed(token, msg.sender, symbol, totalSupply, perMint, price);
    }

    /*══════════════════════════════════════════════════════════════
                        Mint Meme tokens
    ══════════════════════════════════════════════════════════════*/

    /// @notice Buy the next perMint chunk of a Meme token.
    /// @dev    Caller must send exactly `token.price()` wei.
    ///         — 5 % of the ETH is paired with newly minted tokens and
    ///           added as Uniswap V2 liquidity (LP tokens are burned).
    ///         — 95 % goes to the token's deployer.
    /// @param  tokenAddr Address of the Meme token proxy.
    function mintMeme(address tokenAddr) external payable {
        MemeToken token = MemeToken(tokenAddr);

        // ── Validate ──
        require(msg.value == token.price(), "MemeFactory: wrong payment");

        // ── Mint ──
        uint256 mintedAmt = token.mint(msg.sender);
        require(mintedAmt > 0, "MemeFactory: nothing minted");

        // ── Split fee ──
        uint256 liquidityFee = (msg.value * PROJECT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 deployerShare = msg.value - liquidityFee;

        // 5 % → Uniswap V2 liquidity (ETH + corresponding tokens)
        if (liquidityFee > 0) {
            _addLiquidity(tokenAddr, liquidityFee);
        }

        // 95 % → meme deployer
        (bool ok, ) = payable(token.deployer()).call{value: deployerShare}("");
        require(ok, "MemeFactory: deployer fee failed");

        emit Minted(tokenAddr, msg.sender, mintedAmt, liquidityFee);
    }

    /*══════════════════════════════════════════════════════════════
                Buy Meme tokens from Uniswap
    ══════════════════════════════════════════════════════════════*/

    /// @notice Buy Meme tokens directly from the Uniswap V2 pool.
    /// @dev    Only succeeds when the Uniswap spot price is **better**
    ///         (lower) than the token's original mint price. This gives
    ///         buyers the option to purchase at market rate when it is
    ///         favourable.
    /// @param  tokenAddr    Address of the Meme token proxy.
    /// @param  minAmountOut Minimum tokens to receive (slippage protection).
    ///                      If 0, defaults to the amount you would get at the
    ///                      original mint price.
    function buyMeme(address tokenAddr, uint256 minAmountOut) external payable {
        require(msg.value > 0, "MemeFactory: zero ETH");

        MemeToken token = MemeToken(tokenAddr);

        // ── Validate pool exists ──
        address pair = uniswapFactory.getPair(tokenAddr, WETH);
        require(pair != address(0), "MemeFactory: no liquidity pool");

        // ── Compare prices ──
        uint256 startPrice = _tokenPrice(token);
        uint256 poolPrice  = _getUniswapPrice(tokenAddr, pair);
        require(poolPrice < startPrice, "MemeFactory: pool price >= mint price");

        // ── Slippage floor ──
        uint256 minOut = minAmountOut;
        if (minOut == 0) {
            // Default: at least what you'd get at the mint price
            minOut = (msg.value * token.perMint()) / token.price();
        }

        // ── Swap ETH → tokens ──
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = tokenAddr;

        uint256[] memory amounts = uniswapRouter.swapExactETHForTokens{value: msg.value}(
            minOut,
            path,
            msg.sender,
            block.timestamp + 15 minutes
        );

        emit Bought(tokenAddr, msg.sender, msg.value, amounts[1]);
    }

    /*══════════════════════════════════════════════════════════════
                    Internal helpers
    ══════════════════════════════════════════════════════════════*/

    /// @notice Compute the token's mint price: wei per token (scaled by 1e18).
    function _tokenPrice(MemeToken token) internal view returns (uint256) {
        return (token.price() * 1e18) / token.perMint();
    }

    /// @notice Query the Uniswap V2 spot price: wei per token (scaled by 1e18).
    function _getUniswapPrice(address tokenAddr, address pair)
        internal
        view
        returns (uint256)
    {
        (uint256 r0, uint256 r1, ) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();

        if (t0 == tokenAddr) {
            // token = token0, WETH = token1  → price = r1 / r0
            return (r1 * 1e18) / r0;
        } else {
            // token = token1, WETH = token0  → price = r0 / r1
            return (r0 * 1e18) / r1;
        }
    }

    /// @notice Mint additional tokens to match `ethAmount` and add the pair
    ///         as Uniswap V2 liquidity. LP tokens are burned (sent to address(0))
    ///         so the liquidity is permanently locked.
    /// @dev    On the very first addition the ratio follows the mint price;
    ///         thereafter the current pool ratio is used to avoid arbitrage.
    function _addLiquidity(address tokenAddr, uint256 ethAmount) internal {
        MemeToken token = MemeToken(tokenAddr);
        address pair = uniswapFactory.getPair(tokenAddr, WETH);

        uint256 tokenAmount;

        if (pair == address(0)) {
            // ── First liquidity addition: use mint price as the ratio ──
            // tokenAmount = ethAmount × perMint / price
            tokenAmount = (ethAmount * token.perMint()) / token.price();
        } else {
            // ── Subsequent additions: match the current pool ratio ──
            (uint256 r0, uint256 r1, ) = IUniswapV2Pair(pair).getReserves();
            address t0 = IUniswapV2Pair(pair).token0();

            if (t0 == tokenAddr) {
                tokenAmount = (ethAmount * r0) / r1;
            } else {
                tokenAmount = (ethAmount * r1) / r0;
            }
        }
        require(tokenAmount > 0, "MemeFactory: zero token amount");

        // ── Mint the tokens to ourselves ──
        uint256 minted = token.mintForLiquidity(address(this), tokenAmount);
        if (minted == 0) {
            // Not enough supply left — send the ETH back to the deployer
            (bool ok, ) = payable(token.deployer()).call{value: ethAmount}("");
            require(ok, "MemeFactory: refund eth failed");
            return;
        }

        // ── Approve the router ──
        token.approve(address(uniswapRouter), minted);

        // ── Add liquidity (LP tokens go to address(0) → permanently locked) ──
        (uint256 usedToken, uint256 usedETH, uint256 liq) =
            uniswapRouter.addLiquidityETH{value: ethAmount}(
                tokenAddr,
                minted,
                0, // accept any slippage
                0,
                address(0), // burn LP tokens
                block.timestamp + 15 minutes
            );

        // ── Refund any leftover tokens (dust) to the deployer ──
        if (minted > usedToken) {
            require(token.transfer(token.deployer(), minted - usedToken));
        }

        emit LiquidityAdded(tokenAddr, pair, usedETH, usedToken, liq);
    }

    /*══════════════════════════════════════════════════════════════
                            Admin
    ══════════════════════════════════════════════════════════════*/

    /// @notice Update the project fee collector.
    /// @param  newCollector New address that receives the 1 % fee.
    function setFeeCollector(address newCollector) external {
        require(msg.sender == feeCollector, "MemeFactory: not feeCollector");
        require(newCollector != address(0), "MemeFactory: zero address");
        feeCollector = newCollector;
    }
}
