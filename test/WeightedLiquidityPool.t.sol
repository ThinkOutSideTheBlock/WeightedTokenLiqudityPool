// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/WeightedLiquidityPool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract CustomLiquidityPoolTest is Test {
    WeightedLiquidityPool public pool;
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;
    MockERC20 public balToken;

    address public owner;
    address public user1;
    address public user2;

    uint256 public constant INITIAL_BALANCE = 10000 * 1e18;
    uint256 public constant BAL_PER_BLOCK = 1 * 1e18;
    uint256 public constant MAX_TOKENS_PER_POOL = 8;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        token1 = new MockERC20("Token1", "TK1");
        token2 = new MockERC20("Token2", "TK2");
        token3 = new MockERC20("Token3", "TK3");
        balToken = new MockERC20("BAL Token", "BAL");

        pool = new WeightedLiquidityPool(
            IERC20(address(balToken)),
            BAL_PER_BLOCK
        );

        // Distribute tokens to users
        token1.transfer(user1, INITIAL_BALANCE);
        token2.transfer(user1, INITIAL_BALANCE);
        token3.transfer(user1, INITIAL_BALANCE);
        token1.transfer(user2, INITIAL_BALANCE);
        token2.transfer(user2, INITIAL_BALANCE);
        token3.transfer(user2, INITIAL_BALANCE);

        // Approve tokens for the pool
        vm.startPrank(user1);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        token3.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        token1.approve(address(pool), type(uint256).max);
        token2.approve(address(pool), type(uint256).max);
        token3.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function testCreateMaxTokenPool() public {
        address[] memory tokens = new address[](8); // Use 8 instead of MAX_TOKENS_PER_POOL
        uint256[] memory weights = new uint256[](8);

        for (uint256 i = 0; i < 8; i++) {
            tokens[i] = address(
                new MockERC20(
                    string(abi.encodePacked("Token", i)),
                    string(abi.encodePacked("TK", i))
                )
            );
            weights[i] = 1e18 / 8;
        }

        pool.createPool(tokens, weights, 100, 3e15);

        (address[] memory poolTokens, uint256[] memory poolWeights) = pool
            .getPoolTokensandWeight(0);
        assertEq(poolTokens.length, 8);
        assertEq(poolWeights.length, 8);
    }

    function testFailCreatePoolInvalidWeights() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(token1);
        tokens[1] = address(token2);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 6e17; // 60%
        weights[1] = 5e17; // 50%

        uint256 allocPoint = 100;
        uint256 swapFee = 3e15; // 0.3%

        pool.createPool(tokens, weights, allocPoint, swapFee);
    }

    function testAddLiquidity() public {
        // Create a pool first
        testCreatePool();

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000 * 1e18;
        amounts[1] = 1000 * 1e18;

        vm.startPrank(user1);
        pool.addLiquidity(0, amounts);
        vm.stopPrank();

        assertEq(pool.getUserLiquidity(0, user1), 1000 * 1e18);
        assertEq(pool.getPoolBalance(0, address(token1)), 1000 * 1e18);
        assertEq(pool.getPoolBalance(0, address(token2)), 1000 * 1e18);
    }

    function testFailAddLiquidityInsufficientBalance() public {
        // Create a pool first
        testCreatePool();

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000000 * 1e18; // More than the user has
        amounts[1] = 1000 * 1e18;

        vm.startPrank(user1);
        pool.addLiquidity(0, amounts);
        vm.stopPrank();
    }

    function testRemoveLiquidity() public {
        testAddLiquidity();

        vm.startPrank(user1);
        pool.removeLiquidity(0, 500 * 1e18);
        vm.stopPrank();

        assertEq(pool.getUserLiquidity(0, user1), 500 * 1e18);
        assertEq(pool.getPoolBalance(0, address(token1)), 500 * 1e18);
        assertEq(pool.getPoolBalance(0, address(token2)), 500 * 1e18);
    }

    function testFailRemoveLiquidityTooMuch() public {
        testAddLiquidity();

        vm.startPrank(user1);
        pool.removeLiquidity(0, 1500 * 1e18);
        vm.stopPrank();
    }

    function testSwap() public {
        testAddLiquidity();

        vm.startPrank(user2);
        pool.swap(0, address(token1), address(token2), 100 * 1e18, 90 * 1e18);
        vm.stopPrank();

        assertGt(token2.balanceOf(user2), INITIAL_BALANCE);
        assertLt(token1.balanceOf(user2), INITIAL_BALANCE);
    }

    function testFailSwapInsufficientOutput() public {
        testAddLiquidity();

        vm.startPrank(user2);
        pool.swap(0, address(token1), address(token2), 100 * 1e18, 100 * 1e18); // Expecting too much output
        vm.stopPrank();
    }

    function testClaimRewards() public {
        testAddLiquidity();

        // Simulate some blocks passing
        vm.roll(block.number + 100);

        uint256 initialBalBalance = balToken.balanceOf(user1);

        vm.startPrank(user1);
        pool.claimRewards(0);
        vm.stopPrank();

        assertGt(balToken.balanceOf(user1), initialBalBalance);
    }

    function testEmergencyWithdraw() public {
        testAddLiquidity();

        uint256 initialToken1Balance = token1.balanceOf(user1);
        uint256 initialToken2Balance = token2.balanceOf(user1);

        vm.startPrank(user1);
        pool.emergencyWithdraw(0);
        vm.stopPrank();

        assertEq(pool.getUserLiquidity(0, user1), 0);
        assertGt(token1.balanceOf(user1), initialToken1Balance);
        assertGt(token2.balanceOf(user1), initialToken2Balance);
        assertEq(pool.getPoolBalance(0, address(token1)), 0);
        assertEq(pool.getPoolBalance(0, address(token2)), 0);
    }

    function testFailEmergencyWithdrawNoLiquidity() public {
        testCreatePool();

        vm.startPrank(user1);
        pool.emergencyWithdraw(0);
        vm.stopPrank();
    }

    function testPauseUnpause() public {
        pool.pause();
        assertTrue(pool.paused());

        vm.expectRevert("Pausable: paused");
        testAddLiquidity();

        pool.unpause();
        assertFalse(pool.paused());

        testAddLiquidity();
    }

    function testFailPauseNonOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.pause();
    }

    function testSetBalPerBlock() public {
        uint256 newBalPerBlock = 2 * 1e18;
        pool.setBalPerBlock(newBalPerBlock);
        assertEq(pool.balPerBlock(), newBalPerBlock);
    }

    function testFailSetBalPerBlockNonOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.setBalPerBlock(2 * 1e18);
    }

    function testSetPoolAllocPoint() public {
        testCreatePool();
        uint256 newAllocPoint = 200;
        pool.setPoolAllocPoint(0, newAllocPoint);
        assertEq(pool.poolAllocPoints(0), newAllocPoint);
    }

    function testFailSetPoolAllocPointNonOwner() public {
        testCreatePool();
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.setPoolAllocPoint(0, 200);
    }

    function testGetPendingRewards() public {
        testAddLiquidity();

        // Simulate some blocks passing
        vm.roll(block.number + 100);

        uint256 pendingRewards = pool.getPendingRewards(0, user1);
        assertGt(pendingRewards, 0);
    }

    function testMultipleUsersAddLiquidity() public {
        testCreatePool();

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000 * 1e18;
        amounts[1] = 1000 * 1e18;

        vm.prank(user1);
        pool.addLiquidity(0, amounts);

        vm.prank(user2);
        pool.addLiquidity(0, amounts);

        assertEq(pool.getUserLiquidity(0, user1), 1000 * 1e18);
        assertEq(pool.getUserLiquidity(0, user2), 1000 * 1e18);
        assertEq(pool.getPoolBalance(0, address(token1)), 2000 * 1e18);
        assertEq(pool.getPoolBalance(0, address(token2)), 2000 * 1e18);
    }

    function testAddLiquidityUnbalanced() public {
        testCreatePool();

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000 * 1e18;
        amounts[1] = 2000 * 1e18;

        vm.prank(user1);
        pool.addLiquidity(0, amounts);

        assertEq(pool.getUserLiquidity(0, user1), 1000 * 1e18);
        assertEq(pool.getPoolBalance(0, address(token1)), 1000 * 1e18);
        assertEq(pool.getPoolBalance(0, address(token2)), 2000 * 1e18);
    }

    function testSwapEdgeCase() public {
        testAddLiquidity();

        // Attempt to swap a very small amount
        vm.startPrank(user2);
        pool.swap(0, address(token1), address(token2), 1, 0);
        vm.stopPrank();

        // Attempt to swap a very large amount
        vm.startPrank(user2);
        vm.expectRevert("Insufficient output amount");
        pool.swap(
            0,
            address(token1),
            address(token2),
            1000000 * 1e18,
            990000 * 1e18
        );
        vm.stopPrank();
    }

    function testCreateMaxTokenPool() public {
        address[] memory tokens = new address[](MAX_TOKENS_PER_POOL);
        uint256[] memory weights = new uint256[](MAX_TOKENS_PER_POOL);

        for (uint256 i = 0; i < MAX_TOKENS_PER_POOL; i++) {
            tokens[i] = address(
                new MockERC20(
                    string(abi.encodePacked("Token", i)),
                    string(abi.encodePacked("TK", i))
                )
            );
            weights[i] = 1e18 / MAX_TOKENS_PER_POOL;
        }

        pool.createPool(tokens, weights, 100, 3e15);

        (address[] memory poolTokens, ) = pool.getPoolTokens(0);
        assertEq(poolTokens.length, MAX_TOKENS_PER_POOL);
    }

    function testFailCreatePoolTooManyTokens() public {
        address[] memory tokens = new address[](MAX_TOKENS_PER_POOL + 1);
        uint256[] memory weights = new uint256[](MAX_TOKENS_PER_POOL + 1);

        for (uint256 i = 0; i < MAX_TOKENS_PER_POOL + 1; i++) {
            tokens[i] = address(
                new MockERC20(
                    string(abi.encodePacked("Token", i)),
                    string(abi.encodePacked("TK", i))
                )
            );
            weights[i] = 1e18 / (MAX_TOKENS_PER_POOL + 1);
        }

        pool.createPool(tokens, weights, 100, 3e15);
    }

    function testEmergencyWithdrawBAL() public {
        uint256 amount = 1000 * 1e18;
        balToken.transfer(address(pool), amount);

        uint256 initialBalance = balToken.balanceOf(owner);
        pool.emergencyWithdrawBAL(amount);

        assertEq(balToken.balanceOf(owner), initialBalance + amount);
    }

    function testFailEmergencyWithdrawBALNonOwner() public {
        uint256 amount = 1000 * 1e18;
        balToken.transfer(address(pool), amount);

        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.emergencyWithdrawBAL(amount);
    }
}
