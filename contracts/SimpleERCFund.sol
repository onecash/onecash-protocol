pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './owner/Operator.sol';
import './interfaces/ISimpleERCFund.sol';

contract SimpleERCFund is ISimpleERCFund, Operator {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    function deposit(
        address token,
        uint256 amount,
        string memory reason
    ) public override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        address devFundAddr = 0xC7da206a87d85e3f9FF06c761E540553c648bC19;
        address appStoreFundAddr = 0x03BB6e3aa1524720bCf6c010e8c67C2ACe7522B2;
        IERC20(token).safeTransfer(devFundAddr, amount.mul(2).div(5));      // 2% for dev
        IERC20(token).safeTransfer(appStoreFundAddr, amount.mul(3).div(5)); // 3% for app store operation
        
        emit Deposit(msg.sender, now, reason);
    }

    function withdraw(
        address token,
        uint256 amount,
        address to,
        string memory reason
    ) public override onlyOperator {
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawal(msg.sender, to, now, reason);
    }

    event Deposit(address indexed from, uint256 indexed at, string reason);
    event Withdrawal(
        address indexed from,
        address indexed to,
        uint256 indexed at,
        string reason
    );
}
