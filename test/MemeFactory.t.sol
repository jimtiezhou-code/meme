// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MemeFactory.sol";
import "../src/MemeToken.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockUniswapV2Factory.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockWETH.sol";

contract MemeFactoryTest is Test {
    /*══════════════════════════════════════════════════════════════
                        Events (duplicated for assertion)
    ══════════════════════════════════════════════════════════════*/
    event MemeDeployed(
        address indexed token,
        address indexed deployer,
        string symbol,
        uint256 totalSupply,
        uint256 perMint,
        uint256 price
    );
    event Minted(
        address indexed token,
        address indexed buyer,
        uint256 amount,
        uint256 projectFee
    );
    event LiquidityAdded(
        address indexed token,
        address indexed pair,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 liquidity
    );
    event Bought(
        address indexed token,
        address indexed buyer,
        uint256 ethSpent,
        uint256 tokensReceived
    );

    /*══════════════════════════════════════════════════════════════
                            Fixtures
    ══════════════════════════════════════════════════════════════*/
    MemeFactory factory;
    MockUniswapV2Router router;
    MockUniswapV2Factory uniswapFactory;
    address projectFeeRecipient;

    address deployer = makeAddr("deployer");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");

    string constant SYMBOL       = "RACC";
    uint256 constant TOTAL_SUPPLY = 1_000_000e18;  // 1M tokens
    uint256 constant PER_MINT     = 100_000e18;     // 100k per chunk
    uint256 constant PRICE        = 1 ether;         // 1 ETH per chunk

    function setUp() public {
        projectFeeRecipient = makeAddr("feeCollector");

        // Deploy mock Uniswap V2 infrastructure
        router = new MockUniswapV2Router();

        factory = new MemeFactory(projectFeeRecipient, address(router));
        uniswapFactory = router.factory();

        deal(deployer, 10 ether);
        deal(alice,    10 ether);
        deal(bob,      10 ether);
    }

    /*══════════════════════════════════════════════════════════════
                        1) deployMeme
    ══════════════════════════════════════════════════════════════*/

    function test_DeployMeme() public {
        vm.prank(deployer);
        address token = factory.deployMeme(SYMBOL, TOTAL_SUPPLY, PER_MINT, PRICE);

        MemeToken t = MemeToken(token);
        assertEq(t.name(), "Meme");
        assertEq(t.symbol(), SYMBOL);
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), TOTAL_SUPPLY);
        assertEq(t.perMint(), PER_MINT);
        assertEq(t.price(), PRICE);
        assertEq(t.deployer(), deployer);
        assertEq(t.remaining(), TOTAL_SUPPLY);
        assertEq(t.minted(), 0);

        assertEq(t.balanceOf(deployer), 0);
        assertEq(t.balanceOf(address(factory)), 0);
    }

    function test_DeployMeme_EmitsEvent() public {
        vm.prank(deployer);
        factory.deployMeme(SYMBOL, TOTAL_SUPPLY, PER_MINT, PRICE);
    }

    function test_DeployMeme_RevertWhen_EmptySymbol() public {
        vm.prank(deployer);
        vm.expectRevert("MemeFactory: empty symbol");
        factory.deployMeme("", TOTAL_SUPPLY, PER_MINT, PRICE);
    }

    function test_DeployMeme_RevertWhen_ZeroTotalSupply() public {
        vm.prank(deployer);
        vm.expectRevert("MemeFactory: totalSupply = 0");
        factory.deployMeme(SYMBOL, 0, PER_MINT, PRICE);
    }

    function test_DeployMeme_RevertWhen_ZeroPerMint() public {
        vm.prank(deployer);
        vm.expectRevert("MemeFactory: perMint = 0");
        factory.deployMeme(SYMBOL, TOTAL_SUPPLY, 0, PRICE);
    }

    /*══════════════════════════════════════════════════════════════
                        2) mintMeme (5 % fee → liquidity)
    ══════════════════════════════════════════════════════════════*/

    function _deploy() internal returns (address) {
        vm.prank(deployer);
        return factory.deployMeme(SYMBOL, TOTAL_SUPPLY, PER_MINT, PRICE);
    }

    function test_MintMeme_Success() public {
        address token = _deploy();

        uint256 depBalanceBefore = deployer.balance;
        uint256 aliceBalanceBefore = alice.balance;

        // Expected values
        uint256 expectedLiquidityFee = (PRICE * 500) / 10_000; // 5% = 0.05 ETH
        uint256 expectedDeployerShare = PRICE - expectedLiquidityFee; // 0.95 ETH

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Minted(token, alice, PER_MINT, expectedLiquidityFee);
        factory.mintMeme{value: PRICE}(token);

        MemeToken t = MemeToken(token);
        assertEq(t.balanceOf(alice), PER_MINT);
        // perMint (100k) + liquidity tokens (5k) = 105k minted
        uint256 liquidityTokens = (expectedLiquidityFee * PER_MINT) / PRICE;
        assertEq(t.minted(), PER_MINT + liquidityTokens);
        assertEq(t.remaining(), TOTAL_SUPPLY - PER_MINT - liquidityTokens);

        // Alice paid PRICE
        assertEq(alice.balance, aliceBalanceBefore - PRICE);

        // 95 % → deployer
        assertEq(deployer.balance, depBalanceBefore + expectedDeployerShare);

        // Verify liquidity was added via the router
        assertTrue(router.lastLiqCalled());
        assertEq(router.lastLiqToken(), token);
        assertEq(router.lastLiqEthSent(), expectedLiquidityFee);
        assertEq(router.lastLiqAmountTokenDesired(), liquidityTokens);
    }

    function test_MintMeme_LiquidityTokensMinted() public {
        address token = _deploy();

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        // Liquidity tokens should have been minted to the factory
        uint256 expectedLiqTokens = (PRICE * 500 / 10_000) * PER_MINT / PRICE;
        // After addLiquidity, tokens were transferred to router, so factory balance = 0
        // (minus any dust refund — unlikely with exact math here)

        MemeToken t = MemeToken(token);
        // Verify total minted includes liquidity tokens
        assertEq(t.minted(), PER_MINT + expectedLiqTokens);
    }

    function test_MintMeme_MultipleMints() public {
        address token = _deploy();

        // Alice mints 3 chunks
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            factory.mintMeme{value: PRICE}(token);
        }

        MemeToken t = MemeToken(token);
        assertEq(t.balanceOf(alice), 3 * PER_MINT);
        // Each mint also adds liquidity tokens
        uint256 liquidityTokensPerMint = (PRICE * 500 / 10_000) * PER_MINT / PRICE;
        assertEq(t.minted(), 3 * (PER_MINT + liquidityTokensPerMint));
    }

    function test_MintMeme_LastChunkPartial() public {
        // total = 250k, perMint = 100k.
        // Each full mint: 100k to user + 5k to LP = 105k total.
        // 2 full mints = 210k, remaining = 40k (not 50k, because LP consumed 10k).
        // 3rd mint: user gets 40k (capped), LP gets 0 (supply exhausted),
        //            liquidity ETH is refunded to deployer.
        uint256 total = 250_000e18;
        uint256 per   = 100_000e18;

        vm.prank(deployer);
        address token = factory.deployMeme("PART", total, per, PRICE);

        // Mint 2 full chunks
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(alice);
            factory.mintMeme{value: PRICE}(token);
        }

        MemeToken t = MemeToken(token);
        uint256 liquidityTokensPerMint = (PRICE * 500 / 10_000) * per / PRICE;
        assertEq(t.balanceOf(alice), 200_000e18);
        assertEq(t.minted(), 2 * (per + liquidityTokensPerMint)); // 210k

        // Third mint: user gets remaining 40k (no LP tokens left)
        uint256 aliceBalBefore = alice.balance;
        uint256 depBefore      = deployer.balance;

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        // Alice gets 40k (not 50k because 10k went to LP in first 2 mints)
        assertEq(t.balanceOf(alice), 240_000e18);
        assertEq(t.remaining(), 0);
        // Alice still pays full PRICE
        assertEq(alice.balance, aliceBalBefore - PRICE);
        // Deployer gets 95% + the 5% liquidity refund = 100% of PRICE
        assertEq(deployer.balance, depBefore + PRICE);
    }

    function test_MintMeme_RevertWhen_WrongPrice() public {
        address token = _deploy();
        vm.prank(alice);
        vm.expectRevert("MemeFactory: wrong payment");
        factory.mintMeme{value: PRICE - 1}(token);
    }

    function test_MintMeme_RevertWhen_FullyMinted() public {
        address token = _deploy();

        // total is 1M tokens, each mint uses tokens for user + liquidity.
        // Liquidity per mint = 5k tokens, so each full mint uses 105k.
        // 9 full mints = 945k minted, remaining = 55k.
        // 10th mint: user gets 55k (capped), LP gets 0 (exhausted).
        // 1M / 105k = 9.52 → 10 mints before fully depleted:
        //   9 mints with LP + 1 mint without LP (capped user mint only)
        uint256 liqTokensPerMint = (PRICE * 500 / 10_000) * PER_MINT / PRICE;
        uint256 totalPerMint = PER_MINT + liqTokensPerMint;
        uint256 fullMints = TOTAL_SUPPLY / totalPerMint; // 9

        // 9 full mints (each with LP)
        for (uint256 i = 0; i < fullMints; i++) {
            vm.prank(alice);
            factory.mintMeme{value: PRICE}(token);
        }

        // 1 partial mint (LP skipped because supply exhausted)
        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        // Now fully minted — next one should fail
        vm.prank(bob);
        vm.expectRevert("MemeToken: fully minted");
        factory.mintMeme{value: PRICE}(token);
    }

    function test_MintMeme_RevertWhen_ZeroAddressToken() public {
        vm.prank(alice);
        vm.expectRevert();
        factory.mintMeme{value: PRICE}(address(0));
    }

    /*══════════════════════════════════════════════════════════════
                        3) Implementation cannot be initialized
    ══════════════════════════════════════════════════════════════*/

    function test_ImplementationLocked() public {
        MemeToken impl = MemeToken(factory.implementation());
        vm.expectRevert(abi.encodeWithSelector(MemeToken.AlreadyInitialized.selector));
        impl.initialize("X", 1, 1, 1, address(0xdead));
    }

    /*══════════════════════════════════════════════════════════════
                    3.5) Direct mint bypass attempt (access control)
    ══════════════════════════════════════════════════════════════*/

    function test_DirectMint_RevertWhen_NotFactory() public {
        address token = _deploy();
        vm.prank(alice);
        vm.expectRevert("MemeToken: not factory");
        MemeToken(token).mint(alice);
    }

    function test_DirectMint_AnyAddress_Reverts() public {
        address token = _deploy();
        vm.prank(deployer);
        vm.expectRevert("MemeToken: not factory");
        MemeToken(token).mint(deployer);

        vm.prank(bob);
        vm.expectRevert("MemeToken: not factory");
        MemeToken(token).mint(bob);
    }

    /*══════════════════════════════════════════════════════════════
                        4) ERC20 token standard
    ══════════════════════════════════════════════════════════════*/

    function test_Transfer() public {
        address token = _deploy();

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        MemeToken t = MemeToken(token);
        assertEq(t.balanceOf(alice), PER_MINT);

        vm.prank(alice);
        t.transfer(bob, PER_MINT / 2);

        assertEq(t.balanceOf(alice), PER_MINT / 2);
        assertEq(t.balanceOf(bob), PER_MINT / 2);
    }

    function test_ApproveAndTransferFrom() public {
        address token = _deploy();

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        MemeToken t = MemeToken(token);
        vm.prank(alice);
        t.approve(bob, PER_MINT);

        vm.prank(bob);
        t.transferFrom(alice, bob, PER_MINT);

        assertEq(t.balanceOf(alice), 0);
        assertEq(t.balanceOf(bob), PER_MINT);
        assertEq(t.allowance(alice, bob), 0);
    }

    function test_InfiniteApprove() public {
        address token = _deploy();

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        MemeToken t = MemeToken(token);
        vm.prank(alice);
        t.approve(bob, type(uint256).max);

        vm.prank(bob);
        t.transferFrom(alice, bob, PER_MINT / 2);

        assertEq(t.allowance(alice, bob), type(uint256).max);

        vm.prank(bob);
        t.transferFrom(alice, bob, PER_MINT / 2);

        assertEq(t.balanceOf(alice), 0);
        assertEq(t.balanceOf(bob), PER_MINT);
    }

    /*══════════════════════════════════════════════════════════════
                    5) buyMeme
    ══════════════════════════════════════════════════════════════*/

    /// @dev Helper: set up a Uniswap pair with reserves that give a pool price
    ///      below the mint price so buyMeme() succeeds.
    function _setupPoolForBuy(
        address tokenAddr,
        uint256 reserveToken,
        uint256 reserveWETH
    ) internal returns (MockUniswapV2Pair pair) {
        pair = new MockUniswapV2Pair();
        pair.setTokens(tokenAddr, factory.WETH());
        pair.setReserves(uint112(reserveToken), uint112(reserveWETH));

        // Register the pair in the factory
        uniswapFactory.setPair(tokenAddr, factory.WETH(), address(pair));
    }

    function test_BuyMeme_Success() public {
        address token = _deploy();

        // Mint price = 1 ETH / 100,000 tokens = 0.00001 ETH per token (1e13 wei)
        // Set pool reserves so pool price is LOWER (better for buyer):
        // 200,000 tokens and 1 WETH → 1/200000 = 0.000005 ETH per token (5e12 wei)
        // 5e12 < 1e13 → pool is cheaper → buyMeme should succeed
        _setupPoolForBuy(token, 200_000 ether, 1 ether);

        router.setSwapReturnAmount(200_000 ether);

        uint256 bobBalBefore = bob.balance;

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Bought(token, bob, 0.5 ether, 200_000 ether);
        factory.buyMeme{value: 0.5 ether}(token, 0);

        assertEq(bob.balance, bobBalBefore - 0.5 ether);
        assertTrue(router.lastSwapCalled());
    }

    function test_BuyMeme_Success_WithMinAmountOut() public {
        address token = _deploy();

        // Pool: 200k tokens, 1 WETH → price = 0.000005 ETH/token (better than mint)
        _setupPoolForBuy(token, 200_000 ether, 1 ether);

        router.setSwapReturnAmount(100_000 ether);

        vm.prank(bob);
        // minAmountOut = 50,000 tokens
        factory.buyMeme{value: 0.5 ether}(token, 50_000 ether);

        assertTrue(router.lastSwapCalled());
        assertEq(router.lastSwapAmountOutMin(), 50_000 ether);
        assertEq(router.lastSwapEthSent(), 0.5 ether);
    }

    function test_BuyMeme_RevertWhen_PoolPriceNotBetter() public {
        address token = _deploy();

        // Pool: 50,000 tokens and 1 WETH → price = 0.00002 ETH/token (2e13)
        // Mint price = 0.00001 ETH/token (1e13)
        // 2e13 > 1e13 → pool is MORE expensive → should revert
        _setupPoolForBuy(token, 50_000 ether, 1 ether);

        vm.prank(bob);
        vm.expectRevert("MemeFactory: pool price >= mint price");
        factory.buyMeme{value: 0.5 ether}(token, 0);
    }

    function test_BuyMeme_RevertWhen_NoPool() public {
        address token = _deploy();

        vm.prank(bob);
        vm.expectRevert("MemeFactory: no liquidity pool");
        factory.buyMeme{value: 0.5 ether}(token, 0);
    }

    function test_BuyMeme_RevertWhen_ZeroETH() public {
        address token = _deploy();

        vm.prank(bob);
        vm.expectRevert("MemeFactory: zero ETH");
        factory.buyMeme{value: 0}(token, 0);
    }

    /*══════════════════════════════════════════════════════════════
                        6) LiquidityAddition specifics
    ══════════════════════════════════════════════════════════════*/

    function test_LiquidityAdded_EmitsEvent() public {
        address token = _deploy();

        uint256 expectedLiqFee = (PRICE * 500) / 10_000;
        uint256 expectedTokens = (expectedLiqFee * PER_MINT) / PRICE;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit LiquidityAdded(token, address(0), expectedLiqFee, expectedTokens, expectedLiqFee + expectedTokens);
        factory.mintMeme{value: PRICE}(token);
    }

    function test_LiquidityAdded_FirstAdditionUsesMintPrice() public {
        address token = _deploy();

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        // First addition: tokenAmount = ethAmount * perMint / price
        uint256 expectedTokens = (PRICE * 500 / 10_000) * PER_MINT / PRICE;
        assertEq(router.lastLiqAmountTokenDesired(), expectedTokens);
        assertEq(router.lastLiqEthSent(), PRICE * 500 / 10_000);
    }

    function test_LiquidityAdded_SecondAdditionMatchesPoolRatio() public {
        address token = _deploy();

        // First mint — creates initial liquidity
        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        // Now set up a mock pool with a different ratio (simulating price change)
        MockUniswapV2Pair pair = new MockUniswapV2Pair();
        pair.setTokens(token, factory.WETH());
        // Pool: 500k tokens, 2 ETH → price = 0.000004 ETH/token (different from mint)
        pair.setReserves(uint112(500_000 ether), uint112(2 ether));
        uniswapFactory.setPair(token, factory.WETH(), address(pair));

        // Second mint — should use pool ratio
        vm.prank(bob);
        factory.mintMeme{value: PRICE}(token);

        uint256 expectedLiqFee = (PRICE * 500) / 10_000;
        // Pool ratio: token/WETH = 500k/2 = 250k per ETH
        // So for expectedLiqFee ETH, tokens = expectedLiqFee * reserve0 / reserve1
        // token is token0, WETH is token1
        uint256 expectedTokens = (expectedLiqFee * 500_000 ether) / (2 ether);
        assertEq(router.lastLiqAmountTokenDesired(), expectedTokens);
    }

    /*══════════════════════════════════════════════════════════════
                    7) Uniswap V2 constants
    ══════════════════════════════════════════════════════════════*/

    function test_UniswapConstants() public {
        assertEq(factory.PROJECT_FEE_BPS(), 500);
        assertEq(address(factory.uniswapRouter()), address(router));
        assertEq(address(factory.uniswapFactory()), address(uniswapFactory));
        assertEq(factory.WETH(), address(router.WETH()));
    }

    /*══════════════════════════════════════════════════════════════
                        8) Admin
    ══════════════════════════════════════════════════════════════*/

    function test_SetFeeCollector() public {
        address newCollector = makeAddr("newFee");
        vm.prank(projectFeeRecipient);
        factory.setFeeCollector(newCollector);
        assertEq(factory.feeCollector(), newCollector);
    }

    function test_SetFeeCollector_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert("MemeFactory: not feeCollector");
        factory.setFeeCollector(alice);
    }

    function test_SetFeeCollector_RevertWhen_Zero() public {
        vm.prank(projectFeeRecipient);
        vm.expectRevert("MemeFactory: zero address");
        factory.setFeeCollector(address(0));
    }

    /*══════════════════════════════════════════════════════════════
                        9) Multiple tokens
    ══════════════════════════════════════════════════════════════*/

    function test_MultipleTokensIndependence() public {
        vm.startPrank(deployer);
        address t1 = factory.deployMeme("DOGE", 1_000_000e18, 100_000e18, 0.5 ether);
        address t2 = factory.deployMeme("SHIB", 2_000_000e18, 200_000e18, 1 ether);
        vm.stopPrank();

        MemeToken token1 = MemeToken(t1);
        MemeToken token2 = MemeToken(t2);

        assertEq(token1.symbol(), "DOGE");
        assertEq(token1.totalSupply(), 1_000_000e18);
        assertEq(token1.perMint(), 100_000e18);
        assertEq(token1.price(), 0.5 ether);

        assertEq(token2.symbol(), "SHIB");
        assertEq(token2.totalSupply(), 2_000_000e18);
        assertEq(token2.perMint(), 200_000e18);
        assertEq(token2.price(), 1 ether);
    }

    /*══════════════════════════════════════════════════════════════
                    10) Constructor validation
    ══════════════════════════════════════════════════════════════*/

    function test_Constructor_RevertWhen_ZeroFeeCollector() public {
        vm.expectRevert("MemeFactory: feeCollector = 0");
        new MemeFactory(address(0), address(router));
    }

    function test_Constructor_RevertWhen_ZeroRouter() public {
        vm.expectRevert("MemeFactory: router = 0");
        new MemeFactory(projectFeeRecipient, address(0));
    }
}
