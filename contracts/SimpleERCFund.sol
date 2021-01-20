pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './owner/Operator.sol';
import './interfaces/ISimpleERCFund.sol';

contract SimpleERCFund is ISimpleERCFund, Operator {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public devFund;
    address public opFund;

    constructor(
        address _devFund, 
        address _opFund
    ) public {
        devFund = _devFund;
        opFund = _opFund;
    }

    function setDevFund(address _devFund) public onlyOperator {
        devFund = _devFund;
    }

    function setOpFund(address _opFund) public onlyOperator {
        opFund = _opFund;
    }

    function deposit(
        address token,
        uint256 amount,
        string memory reason
    ) public override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        IERC20(token).safeTransfer(devFund, amount.mul(4).div(7));      // 4% for dev
        IERC20(token).safeTransfer(opFund, amount.mul(3).div(7));       // 3% for app store operation
        
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
