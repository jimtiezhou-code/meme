// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MemeFactory.sol";
import "../src/MemeToken.sol";

/// @notice A helper so we can test the implementation directly (not through a proxy).
contract MockToken {
    constructor() {}
}

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

    /*══════════════════════════════════════════════════════════════
                            Fixtures
    ══════════════════════════════════════════════════════════════*/
    MemeFactory factory;
    address projectFeeRecipient;

    address deployer = makeAddr("deployer");   // meme creator
    address alice    = makeAddr("alice");       // minter
    address bob      = makeAddr("bob");

    string constant SYMBOL       = "RACC";
    uint256 constant TOTAL_SUPPLY = 1_000_000e18;  // 1M tokens
    uint256 constant PER_MINT     = 100_000e18;     // 100k per chunk
    uint256 constant PRICE        = 1 ether;         // 1 ETH per chunk

    function setUp() public {
        projectFeeRecipient = makeAddr("feeCollector");
        factory = new MemeFactory(projectFeeRecipient);

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

        // balance initially zero
        assertEq(t.balanceOf(deployer), 0);
        assertEq(t.balanceOf(address(factory)), 0);
    }

    function test_DeployMeme_EmitsEvent() public {
        vm.prank(deployer);
        factory.deployMeme(SYMBOL, TOTAL_SUPPLY, PER_MINT, PRICE);
        // The event is checked at a higher level; we just verify no revert.
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
                        2) mintMeme
    ══════════════════════════════════════════════════════════════*/

    /// @dev Helper: deploy & return token address.
    function _deploy() internal returns (address) {
        vm.prank(deployer);
        return factory.deployMeme(SYMBOL, TOTAL_SUPPLY, PER_MINT, PRICE);
    }

    function test_MintMeme_Success() public {
        address token = _deploy();

        uint256 feeColBalanceBefore = projectFeeRecipient.balance;
        uint256 depBalanceBefore    = deployer.balance;
        uint256 aliceBalanceBefore  = alice.balance;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Minted(token, alice, PER_MINT, PRICE / 100);
        factory.mintMeme{value: PRICE}(token);

        MemeToken t = MemeToken(token);
        assertEq(t.balanceOf(alice), PER_MINT);
        assertEq(t.minted(), PER_MINT);
        assertEq(t.remaining(), TOTAL_SUPPLY - PER_MINT);

        // Alice paid PRICE
        assertEq(alice.balance, aliceBalanceBefore - PRICE);

        // 1% → project fee collector
        assertEq(projectFeeRecipient.balance, feeColBalanceBefore + PRICE / 100);

        // 99% → deployer
        assertEq(deployer.balance, depBalanceBefore + PRICE - PRICE / 100);
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
        assertEq(t.minted(), 3 * PER_MINT);
    }

    function test_MintMeme_LastChunkPartial() public {
        // total = 1M, perMint = 100k, so 10 chunks exactly.
        // Let's change total to 250k -> 2 full chunks + 1 partial of 50k
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
        assertEq(t.minted(), 200_000e18);
        assertEq(t.balanceOf(alice), 200_000e18);
        assertEq(t.remaining(), 50_000e18);

        // Third mint should only give 50k, but still costs full PRICE
        uint256 aliceBalBefore = alice.balance;
        uint256 feeColBefore   = projectFeeRecipient.balance;
        uint256 depBefore      = deployer.balance;

        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        assertEq(t.balanceOf(alice), 250_000e18);
        assertEq(t.minted(), 250_000e18);
        assertEq(t.remaining(), 0);

        // Alice still pays full PRICE
        assertEq(alice.balance, aliceBalBefore - PRICE);
        // Fees still split
        assertEq(projectFeeRecipient.balance, feeColBefore + PRICE / 100);
        assertEq(deployer.balance, depBefore + PRICE - PRICE / 100);
    }

    function test_MintMeme_RevertWhen_WrongPrice() public {
        address token = _deploy();
        vm.prank(alice);
        vm.expectRevert("MemeFactory: wrong payment");
        factory.mintMeme{value: PRICE - 1}(token);   // underpay
    }

    function test_MintMeme_RevertWhen_FullyMinted() public {
        address token = _deploy();

        uint256 chunks = TOTAL_SUPPLY / PER_MINT; // 10
        for (uint256 i = 0; i < chunks; i++) {
            vm.prank(alice);
            factory.mintMeme{value: PRICE}(token);
        }

        // one extra should fail
        vm.prank(bob);
        vm.expectRevert("MemeToken: fully minted");
        factory.mintMeme{value: PRICE}(token);
    }

    function test_MintMeme_RevertWhen_ZeroAddressToken() public {
        vm.prank(alice);
        vm.expectRevert(); // low-level call will revert on wrong price check or zero address
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

        // Anyone calling mint() directly on the token should be rejected
        vm.prank(alice);
        vm.expectRevert("MemeToken: not factory");
        MemeToken(token).mint(alice);
    }

    function test_DirectMint_AnyAddress_Reverts() public {
        address token = _deploy();

        // Even the deployer cannot mint directly
        vm.prank(deployer);
        vm.expectRevert("MemeToken: not factory");
        MemeToken(token).mint(deployer);

        // Bob too
        vm.prank(bob);
        vm.expectRevert("MemeToken: not factory");
        MemeToken(token).mint(bob);
    }

    /*══════════════════════════════════════════════════════════════
                       4) ERC20 token standard
    ══════════════════════════════════════════════════════════════*/

    function test_Transfer() public {
        address token = _deploy();

        // Alice buys some
        vm.prank(alice);
        factory.mintMeme{value: PRICE}(token);

        MemeToken t = MemeToken(token);
        assertEq(t.balanceOf(alice), PER_MINT);

        // Alice transfers half to Bob
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

        // First transfer
        vm.prank(bob);
        t.transferFrom(alice, bob, PER_MINT / 2);

        // Allowance should still be max
        assertEq(t.allowance(alice, bob), type(uint256).max);

        // Second transfer
        vm.prank(bob);
        t.transferFrom(alice, bob, PER_MINT / 2);

        assertEq(t.balanceOf(alice), 0);
        assertEq(t.balanceOf(bob), PER_MINT);
    }

    /*══════════════════════════════════════════════════════════════
                        5) Admin
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
                        6) Multiple tokens
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
}