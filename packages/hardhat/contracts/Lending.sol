// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Corn.sol";
import "./CornDEX.sol";

error Lending__InvalidAmount();
error Lending__TransferFailed();
error Lending__UnsafePositionRatio();
error Lending__BorrowingFailed();
error Lending__RepayingFailed();
error Lending__PositionSafe();
error Lending__NotLiquidatable();
error Lending__InsufficientLiquidatorCorn();

contract Lending is Ownable {
    uint256 private constant COLLATERAL_RATIO = 120; // 120% collateralization required
    uint256 private constant LIQUIDATOR_REWARD = 10; // 10% reward for liquidators

    Corn private i_corn;
    CornDEX private i_cornDEX;

    mapping(address => uint256) public s_userCollateral; // User's collateral balance
    mapping(address => uint256) public s_userBorrowed; // User's borrowed corn balance

    event CollateralAdded(address indexed user, uint256 indexed amount, uint256 price);
    event CollateralWithdrawn(address indexed user, uint256 indexed amount, uint256 price);
    event AssetBorrowed(address indexed user, uint256 indexed amount, uint256 price);
    event AssetRepaid(address indexed user, uint256 indexed amount, uint256 price);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        uint256 amountForLiquidator,
        uint256 liquidatedUserDebt,
        uint256 price
    );

    constructor(address _cornDEX, address _corn) Ownable(msg.sender) {
        i_cornDEX = CornDEX(_cornDEX);
        i_corn = Corn(_corn);
        i_corn.approve(address(this), type(uint256).max);
    }

    /**
     * @notice Allows users to add collateral to their account
     */
    function addCollateral() public payable {
        // 1.校验eth是否为0
        if (msg.value == 0) {
            revert Lending__InvalidAmount();
        }
        // 2.更新用户存入的抵押
        s_userCollateral[msg.sender] += msg.value;
        // 3.触发用户存入抵押事件
        emit CollateralAdded(msg.sender, msg.value, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to withdraw collateral as long as it doesn't make them liquidatable
     * @param amount The amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 amount) public {
        // 1.校验amonut是否为0或用户是否有足够的抵押
        if (amount == 0 || amount > s_userCollateral[msg.sender]) {
            revert Lending__InvalidAmount();
        }
        // 2.更新用户取回的抵押
        s_userCollateral[msg.sender] -= amount;
        // 3.校验用户取回后是否超过安全线
        if (s_userBorrowed[msg.sender] > 0) {
            _validatePosition(msg.sender);
        }
        (bool sent, ) = msg.sender.call{ value: amount }("");
        require(sent, "fail to transfer withdraw to user");
        // 4.触发用户取回抵押
        emit CollateralWithdrawn(msg.sender, amount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Calculates the total collateral value for a user based on their collateral balance
     * @param user The address of the user to calculate the collateral value for
     * @return uint256 The collateral value
     */
    function calculateCollateralValue(address user) public view returns (uint256) {
        // 1.获取用户的抵押
        uint256 userCollateral = s_userCollateral[user];
        // 2.计算抵押的corn价值
        // ⚠️这里需要除以一个1e18
        return (userCollateral * i_cornDEX.currentPrice()) / 1e18;
    }

    /**
     * @notice Calculates the position ratio for a user to ensure they are within safe limits
     * @param user The address of the user to calculate the position ratio for
     * @return uint256 The position ratio
     */
    function _calculatePositionRatio(address user) internal view returns (uint256) {
        // 1.获取用户的代币抵押和贷款
        uint256 userBorrowed = s_userBorrowed[user];
        uint256 userCollateralValue = calculateCollateralValue(user);
        // 2.如果没有贷款，返回最大值
        if (userBorrowed == 0) {
            return type(uint256).max;
        }
        // 3.否则计算抵贷比
        // ⚠️先 * 1e18以防精度丢失
        return (userCollateralValue * 1e18) / userBorrowed;
    }

    /**
     * @notice Checks if a user's position can be liquidated
     * @param user The address of the user to check
     * @return bool True if the position is liquidatable, false otherwise
     */
    function isLiquidatable(address user) public view returns (bool) {
        // 返回是否达到清算点，
        // ⚠️position是百分比，需要 * 100，而 COLLATERAL_RATIO要与position一样扩大1e18
        return _calculatePositionRatio(user) * 100 < COLLATERAL_RATIO * 1e18;
    }

    /**
     * @notice Internal view method that reverts if a user's position is unsafe
     * @param user The address of the user to validate
     */
    function _validatePosition(address user) internal view {
        // 校验借贷比合法
        if (isLiquidatable(user)) {
            revert Lending__UnsafePositionRatio();
        }
    }

    /**
     * @notice Allows users to borrow corn based on their collateral
     * @param borrowAmount The amount of corn to borrow
     */
    function borrowCorn(uint256 borrowAmount) public {
        // 1.校验借贷数量
        if (borrowAmount == 0) {
            revert Lending__InvalidAmount();
        }
        // 2.更新用户贷款值
        s_userBorrowed[msg.sender] += borrowAmount;
        // 3.校验是否能借贷
        _validatePosition(msg.sender);
        // 4.发放corn借贷
        bool sent = i_corn.transferFrom(address(this), msg.sender, borrowAmount);
        if (!sent) {
            revert Lending__BorrowingFailed();
        }
        // 5.触发完成借贷事件
        emit AssetBorrowed(msg.sender, borrowAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows users to repay corn and reduce their debt
     * @param repayAmount The amount of corn to repay
     */
    function repayCorn(uint256 repayAmount) public {
        // 1.校验用户还贷数量
        if (repayAmount == 0 || s_userBorrowed[msg.sender] < repayAmount) {
            revert Lending__InvalidAmount();
        }
        // 2.更新用户贷款值
        s_userBorrowed[msg.sender] -= repayAmount;
        // 3.转移用户corn到lending合约
        bool sent = i_corn.transferFrom(msg.sender, address(this), repayAmount);
        if (!sent) {
            revert Lending__RepayingFailed();
        }
        // 4.触发用户还贷事件
        emit AssetRepaid(msg.sender, repayAmount, i_cornDEX.currentPrice());
    }

    /**
     * @notice Allows liquidators to liquidate unsafe positions
     * @param user The address of the user to liquidate
     * @dev The caller must have enough CORN to pay back user's debt
     * @dev The caller must have approved this contract to transfer the debt
     */
    function liquidate(address user) public {
        // 函数作用：msg.sender通过corn买负债用户的抵押价值
        address liquidator = msg.sender;
        // 1.校验用户是否能做liquidate
        if (!isLiquidatable(user)) {
            revert Lending__NotLiquidatable();
        }
        // 2.判断是否有足够的corn做清算
        uint256 userDebt = s_userBorrowed[user];
        if (i_corn.balanceOf(liquidator) < userDebt) {
            revert Lending__InsufficientLiquidatorCorn();
        }
        // 3.清算用户的贷款和抵押
        // 3.1 负债用户的抵押
        uint256 userCollateral = s_userCollateral[user];
        // 3.2 负债用户的抵押价值
        uint256 userCollateralValue = calculateCollateralValue(user);
        // 3.3 还债用户通过转移corn还款
        i_corn.transferFrom(liquidator, address(this), userDebt);
        s_userBorrowed[user] = 0;
        // 3.4 计算负债用户对应的价值
        uint256 collateralPurchase = (userCollateral * userDebt) / userCollateralValue;
        // 3.5 计算还债用户回报
        uint256 liquidatorReward = (collateralPurchase * LIQUIDATOR_REWARD) / 100;
        // 3.6 计算还债用户的总收益
        uint256 amountForLiquidator = collateralPurchase + liquidatorReward;
        // 3.7 更新清算值，以防超出负债用户抵押
        amountForLiquidator = amountForLiquidator > userCollateral ? userCollateral : amountForLiquidator;
        // 4.更新负债用户抵押
        s_userCollateral[user] = userCollateral - amountForLiquidator;
        // 5.还债用户获得负债用户的抵押
        (bool sent, ) = payable(liquidator).call{ value: amountForLiquidator }("");
        require(sent, "fail to liquidate");
        // 6.触发清算事件
        emit Liquidation(user, liquidator, amountForLiquidator, userDebt, i_cornDEX.currentPrice());
    }
}
