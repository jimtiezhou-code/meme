// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ERC20.sol";

/// @notice MemeToken implementation — deployed once, cloned via EIP‑1167.
///         Storage is held in the clone (proxy), so each clone is independent.
contract MemeToken is ERC20 {
    error AlreadyInitialized();
    error ZeroAddress();

    /*══════════════════════════════════════════════════════════════
                            State (proxy storage)
    ══════════════════════════════════════════════════════════════*/

    address public factory;         // MemeFactory that deployed this proxy
    address public deployer;        // fee recipient on mints
    uint256 public perMint;         // tokens minted per call
    uint256 public price;           // wei charged per perMint chunk
    uint256 public minted;          // total tokens already minted
    bool    private _initialized;

    /*══════════════════════════════════════════════════════════════
                            Modifiers
    ══════════════════════════════════════════════════════════════*/

    modifier onlyFactory() {
        require(msg.sender == factory, "MemeToken: not factory");
        _;
    }

    /*══════════════════════════════════════════════════════════════
                            Constructor (implementation only)
    ══════════════════════════════════════════════════════════════*/

    /// @notice Constructor locks the implementation — nobody can initialize it.
    constructor() {
        _initialized = true;
    }

    /*══════════════════════════════════════════════════════════════
                            Initializer (proxy only)
    ══════════════════════════════════════════════════════════════*/

    /// @notice Initializes a clone. Called once via delegatecall from the proxy.
    function initialize(
        string calldata symbol_,
        uint256 totalSupply_,
        uint256 perMint_,
        uint256 price_,
        address deployer_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (deployer_ == address(0)) revert ZeroAddress();
        _initialized = true;

        name   = "Meme";
        symbol = symbol_;
        totalSupply = totalSupply_;
        perMint    = perMint_;
        price      = price_;
        deployer   = deployer_;
        factory    = msg.sender;     // the MemeFactory that is delegatecall-ing this initializer
    }

    /*══════════════════════════════════════════════════════════════
                                Views
    ══════════════════════════════════════════════════════════════*/

    function remaining() public view returns (uint256) {
        return totalSupply - minted;
    }

    /*══════════════════════════════════════════════════════════════
                                Mint
    ══════════════════════════════════════════════════════════════*/

    /// @notice Mints the next chunk (up to perMint) to `to`.
    /// @return amountActuallyMinted  Number of tokens minted (may be < perMint
    ///                               if it's the last chunk).
    function mint(address to) external onlyFactory returns (uint256 amountActuallyMinted) {
        uint256 left = remaining();
        if (left == 0) revert("MemeToken: fully minted");

        uint256 mintAmount = perMint < left ? perMint : left;
        _mint(to, mintAmount);
        minted += mintAmount;
        return mintAmount;
    }

    /// @notice Mints an arbitrary amount of tokens for liquidity provision.
    /// @dev    Only callable by the factory. Tokens are minted to the factory
    ///         so it can add them as Uniswap V2 liquidity.
    ///         Returns 0 instead of reverting when the supply is exhausted.
    /// @param  to     Recipient of the minted tokens (typically the factory).
    /// @param  amount Desired token amount to mint.
    /// @return mintedAmount  Number of tokens actually minted (capped by remaining, may be 0).
    function mintForLiquidity(address to, uint256 amount)
        external
        onlyFactory
        returns (uint256 mintedAmount)
    {
        uint256 left = remaining();
        if (left == 0) return 0;

        mintedAmount = amount < left ? amount : left;
        _mint(to, mintedAmount);
        minted += mintedAmount;
    }
}