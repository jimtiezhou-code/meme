// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Clones.sol";
import "./MemeToken.sol";

/// @notice ERC‑1967 / EIP‑1167 factory that deploys Meme tokens as minimal proxies
///         and handles minting with automatic fee splitting.
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

    /*══════════════════════════════════════════════════════════════
                            Constants
    ══════════════════════════════════════════════════════════════*/

    /// @notice Project fee in basis points. 100 = 1%.
    uint256 public constant PROJECT_FEE_BPS = 100;

    /// @notice Denominator for basis-point math.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /*══════════════════════════════════════════════════════════════
                                State
    ══════════════════════════════════════════════════════════════*/

    /// @notice The single MemeToken implementation contract (never initialized).
    address public immutable implementation;

    /// @notice Address that receives the 1 % project fee on every mint.
    address public feeCollector;

    /*══════════════════════════════════════════════════════════════
                            Constructor
    ══════════════════════════════════════════════════════════════*/

    /// @param feeCollector_ Initial recipient of project fees.
    constructor(address feeCollector_) {
        require(feeCollector_ != address(0), "MemeFactory: feeCollector = 0");

        // Deploy the implementation once. Its constructor locks it so no
        // clone can ever accidentally initialize the implementation itself.
        implementation = address(new MemeToken());
        feeCollector    = feeCollector_;
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
    ///         — 1 % is forwarded to the platform feeCollector
    ///         — 99 % goes to the token's deployer.
    /// @param  tokenAddr Address of the Meme token proxy.
    function mintMeme(address tokenAddr) external payable {
        MemeToken token = MemeToken(tokenAddr);

        // ── Validate ──
        require(msg.value == token.price(), "MemeFactory: wrong payment");

        // ── Mint ──
        uint256 mintedAmt = token.mint(msg.sender);
        require(mintedAmt > 0, "MemeFactory: nothing minted");

        // ── Split fee ──
        uint256 projectFee = (msg.value * PROJECT_FEE_BPS) / BPS_DENOMINATOR;
        uint256 deployerShare = msg.value - projectFee;

        // 1 % → project
        (bool ok1, ) = payable(feeCollector).call{value: projectFee}("");
        require(ok1, "MemeFactory: project fee failed");

        // 99 % → meme deployer
        (bool ok2, ) = payable(token.deployer()).call{value: deployerShare}("");
        require(ok2, "MemeFactory: deployer fee failed");

        emit Minted(tokenAddr, msg.sender, mintedAmt, projectFee);
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