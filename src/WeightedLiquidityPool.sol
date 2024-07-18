// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract WeightedLiquidityPool is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    struct Pool {
        address[] tokens;
        uint256[] weights;
        uint256 totalLiquidity;
        mapping(address => uint256) balances;
        uint256 swapFee;
        uint256 lastUpdateTime;
    }

    struct UserInfo {
        uint256 liquidity;
        uint256 rewardDebt;
        uint256 lastDepositTime;
    }

    IERC20 public balToken;
    uint256 public balPerBlock;
    uint256 public totalAllocPoint;

    uint256 public constant WEIGHT_MULTIPLIER = 1e18;
    uint256 public constant MAX_TOKENS_PER_POOL = 8;
    uint256 public constant MIN_SWAP_FEE = 1e15; // 0.1%
    uint256 public constant MAX_SWAP_FEE = 1e17; // 10%
    uint256 public constant WITHDRAWAL_FEE_PERIOD = 3 days;
    uint256 public constant WITHDRAWAL_FEE = 50; // 0.5%
    uint256 public constant FEE_DENOMINATOR = 10000;

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => uint256) public poolAllocPoints;

    uint256 public poolCount;

    event PoolCreated(
        uint256 indexed poolId,
        address[] tokens,
        uint256[] weights,
        uint256 swapFee
    );
    event LiquidityAdded(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount
    );
    event LiquidityRemoved(
        uint256 indexed poolId,
        address indexed user,
        uint256 amount,
        uint256 fee
    );
    event Swap(
        uint256 indexed poolId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event RewardPaid(address indexed user, uint256 amount);
    event BalPerBlockUpdated(uint256 newBalPerBlock);
    event PoolAllocPointUpdated(uint256 indexed poolId, uint256 allocPoint);

    // Add this constructor
    constructor(IERC20 _balToken, uint256 _balPerBlock) Ownable(msg.sender) {
        balToken = _balToken;
        balPerBlock = _balPerBlock;
    }

    function createPool(
        address[] calldata _tokens,
        uint256[] calldata _weights,
        uint256 _allocPoint,
        uint256 _swapFee
    ) external onlyOwner {
        require(
            _tokens.length == _weights.length,
            "Tokens and weights length mismatch"
        );
        require(
            _tokens.length >= 2 && _tokens.length <= MAX_TOKENS_PER_POOL,
            "Invalid number of tokens"
        );
        require(
            _swapFee >= MIN_SWAP_FEE && _swapFee <= MAX_SWAP_FEE,
            "Invalid swap fee"
        );

        uint256 poolId = poolCount++;
        Pool storage pool = pools[poolId];
        pool.tokens = _tokens;
        pool.weights = _weights;
        pool.swapFee = _swapFee;
        pool.lastUpdateTime = block.timestamp;

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < _weights.length; i++) {
            totalWeight += _weights[i];
        }
        require(totalWeight == WEIGHT_MULTIPLIER, "Total weight must be 100%");

        poolAllocPoints[poolId] = _allocPoint;
        totalAllocPoint += _allocPoint;

        emit PoolCreated(poolId, _tokens, _weights, _swapFee);
    }

    function addLiquidity(
        uint256 _poolId,
        uint256[] calldata _amounts
    ) external nonReentrant whenNotPaused {
        Pool storage pool = pools[_poolId];
        require(
            _amounts.length == pool.tokens.length,
            "Amounts length mismatch"
        );

        uint256 liquidity = calculateLiquidity(_poolId, _amounts);
        require(liquidity > 0, "Insufficient liquidity");

        for (uint256 i = 0; i < pool.tokens.length; i++) {
            IERC20(pool.tokens[i]).safeTransferFrom(
                msg.sender,
                address(this),
                _amounts[i]
            );
            pool.balances[pool.tokens[i]] += _amounts[i];
        }

        pool.totalLiquidity += liquidity;
        userInfo[_poolId][msg.sender].liquidity += liquidity;
        userInfo[_poolId][msg.sender].lastDepositTime = block.timestamp;

        updateReward(_poolId, msg.sender);

        emit LiquidityAdded(_poolId, msg.sender, liquidity);
    }

    function removeLiquidity(
        uint256 _poolId,
        uint256 _liquidity
    ) external nonReentrant whenNotPaused {
        Pool storage pool = pools[_poolId];
        UserInfo storage user = userInfo[_poolId][msg.sender];
        require(user.liquidity >= _liquidity, "Insufficient liquidity");

        updateReward(_poolId, msg.sender);

        uint256 fee = 0;
        if (block.timestamp < user.lastDepositTime + WITHDRAWAL_FEE_PERIOD) {
            fee = (_liquidity * WITHDRAWAL_FEE) / FEE_DENOMINATOR;
            _liquidity -= fee;
        }

        user.liquidity -= _liquidity + fee;
        pool.totalLiquidity -= _liquidity + fee;

        for (uint256 i = 0; i < pool.tokens.length; i++) {
            uint256 amount = (_liquidity * pool.balances[pool.tokens[i]]) /
                pool.totalLiquidity;
            pool.balances[pool.tokens[i]] -= amount;
            IERC20(pool.tokens[i]).safeTransfer(msg.sender, amount);
        }

        emit LiquidityRemoved(_poolId, msg.sender, _liquidity, fee);
    }

    function swap(
        uint256 _poolId,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) external nonReentrant whenNotPaused {
        Pool storage pool = pools[_poolId];
        require(_tokenIn != _tokenOut, "Cannot swap same token");
        require(
            pool.balances[_tokenIn] > 0 && pool.balances[_tokenOut] > 0,
            "Invalid tokens"
        );

        uint256 amountOut = calculateSwapOutput(
            _poolId,
            _tokenIn,
            _tokenOut,
            _amountIn
        );
        require(amountOut >= _minAmountOut, "Insufficient output amount");

        uint256 swapFee = (amountOut * pool.swapFee) / WEIGHT_MULTIPLIER;
        uint256 amountOutAfterFee = amountOut - swapFee;

        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        IERC20(_tokenOut).safeTransfer(msg.sender, amountOutAfterFee);

        pool.balances[_tokenIn] += _amountIn;
        pool.balances[_tokenOut] -= amountOut;

        emit Swap(
            _poolId,
            msg.sender,
            _tokenIn,
            _tokenOut,
            _amountIn,
            amountOutAfterFee
        );
    }

    function updateReward(uint256 _poolId, address _user) internal {
        Pool storage pool = pools[_poolId];
        UserInfo storage user = userInfo[_poolId][_user];

        uint256 blocksSinceLastUpdate = block.number - pool.lastUpdateTime;
        if (blocksSinceLastUpdate > 0 && pool.totalLiquidity > 0) {
            uint256 balReward = (blocksSinceLastUpdate *
                balPerBlock *
                poolAllocPoints[_poolId]) / totalAllocPoint;
            uint256 userReward = (balReward * user.liquidity) /
                pool.totalLiquidity;
            user.rewardDebt += userReward;
        }
        pool.lastUpdateTime = block.number;
    }

    function claimRewards(uint256 _poolId) external nonReentrant {
        updateReward(_poolId, msg.sender);
        UserInfo storage user = userInfo[_poolId][msg.sender];
        uint256 pending = user.rewardDebt;
        if (pending > 0) {
            user.rewardDebt = 0;
            balToken.safeTransfer(msg.sender, pending);
            emit RewardPaid(msg.sender, pending);
        }
    }

    function calculateLiquidity(
        uint256 _poolId,
        uint256[] memory _amounts
    ) public view returns (uint256) {
        Pool storage pool = pools[_poolId];
        if (pool.totalLiquidity == 0) {
            uint256 totalWeight = 0;
            for (uint256 i = 0; i < pool.weights.length; i++) {
                totalWeight += (_amounts[i] * pool.weights[i]);
            }
            return totalWeight / WEIGHT_MULTIPLIER;
        }

        uint256 minRatio = type(uint256).max;
        for (uint256 i = 0; i < _amounts.length; i++) {
            uint256 ratio = (_amounts[i] * pool.totalLiquidity) /
                pool.balances[pool.tokens[i]];
            if (ratio < minRatio) {
                minRatio = ratio;
            }
        }
        return minRatio;
    }

    function calculateSwapOutput(
        uint256 _poolId,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) public view returns (uint256) {
        Pool storage pool = pools[_poolId];
        (
            uint256 weightIn,
            uint256 weightOut,
            uint256 balanceIn,
            uint256 balanceOut
        ) = getPoolInfo(_poolId, _tokenIn, _tokenOut);

        uint256 amountInWithFee = (_amountIn *
            (WEIGHT_MULTIPLIER - pool.swapFee)) / WEIGHT_MULTIPLIER;
        uint256 denominator = balanceIn + amountInWithFee;
        uint256 ratio = (balanceIn * WEIGHT_MULTIPLIER) / denominator;
        uint256 exponent = (weightIn * WEIGHT_MULTIPLIER) / weightOut;
        uint256 ratioE = pow(ratio, exponent);
        uint256 y = WEIGHT_MULTIPLIER - ratioE;
        uint256 amountOut = (y * balanceOut) / WEIGHT_MULTIPLIER;

        return amountOut;
    }

    function getPoolInfo(
        uint256 _poolId,
        address _tokenIn,
        address _tokenOut
    )
        internal
        view
        returns (
            uint256 weightIn,
            uint256 weightOut,
            uint256 balanceIn,
            uint256 balanceOut
        )
    {
        Pool storage pool = pools[_poolId];
        for (uint256 i = 0; i < pool.tokens.length; i++) {
            if (pool.tokens[i] == _tokenIn) {
                weightIn = pool.weights[i];
                balanceIn = pool.balances[_tokenIn];
            } else if (pool.tokens[i] == _tokenOut) {
                weightOut = pool.weights[i];
                balanceOut = pool.balances[_tokenOut];
            }
        }
        require(weightIn > 0 && weightOut > 0, "Invalid tokens");
    }

    function pow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        z = n % 2 != 0 ? x : WEIGHT_MULTIPLIER;

        for (n /= 2; n != 0; n /= 2) {
            x = (x * x) / WEIGHT_MULTIPLIER;

            if (n % 2 != 0) {
                z = (z * x) / WEIGHT_MULTIPLIER;
            }
        }
    }

    function setBalPerBlock(uint256 _balPerBlock) external onlyOwner {
        balPerBlock = _balPerBlock;
        emit BalPerBlockUpdated(_balPerBlock);
    }

    function setPoolAllocPoint(
        uint256 _poolId,
        uint256 _allocPoint
    ) external onlyOwner {
        totalAllocPoint =
            totalAllocPoint -
            poolAllocPoints[_poolId] +
            _allocPoint;
        poolAllocPoints[_poolId] = _allocPoint;
        emit PoolAllocPointUpdated(_poolId, _allocPoint);
    }

    function getPendingRewards(
        uint256 _poolId,
        address _user
    ) external view returns (uint256) {
        Pool storage pool = pools[_poolId];
        UserInfo storage user = userInfo[_poolId][_user];
        uint256 blocksSinceLastUpdate = block.number - pool.lastUpdateTime;
        uint256 balReward = (blocksSinceLastUpdate *
            balPerBlock *
            poolAllocPoints[_poolId]) / totalAllocPoint;
        return
            user.rewardDebt +
            ((balReward * user.liquidity) / pool.totalLiquidity);
    }

    function getPoolTokens(
        uint256 _poolId
    ) external view returns (address[] memory) {
        return pools[_poolId].tokens;
    }

    function getPoolWeights(
        uint256 _poolId
    ) external view returns (uint256[] memory) {
        return pools[_poolId].weights;
    }

    function getPoolBalance(
        uint256 _poolId,
        address _token
    ) external view returns (uint256) {
        return pools[_poolId].balances[_token];
    }

    function getUserLiquidity(
        uint256 _poolId,
        address _user
    ) external view returns (uint256) {
        return userInfo[_poolId][_user].liquidity;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(uint256 _poolId) external nonReentrant {
        UserInfo storage user = userInfo[_poolId][msg.sender];
        Pool storage pool = pools[_poolId];
        uint256 liquidity = user.liquidity;
        require(liquidity > 0, "No liquidity to withdraw");

        user.liquidity = 0;
        user.rewardDebt = 0;
        pool.totalLiquidity -= liquidity;

        for (uint256 i = 0; i < pool.tokens.length; i++) {
            uint256 amount = (liquidity * pool.balances[pool.tokens[i]]) /
                pool.totalLiquidity;
            pool.balances[pool.tokens[i]] -= amount;
            IERC20(pool.tokens[i]).safeTransfer(msg.sender, amount);
        }

        emit LiquidityRemoved(_poolId, msg.sender, liquidity, 0);
    }

    // Emergency function to withdraw BAL tokens (in case they get stuck)
    function emergencyWithdrawBAL(uint256 _amount) external onlyOwner {
        balToken.safeTransfer(owner(), _amount);
    }
}
