pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

/**
 *Submitted for verification at Etherscan.io on 2020-07-17
 */

/*
   ____            __   __        __   _
  / __/__ __ ___  / /_ / /  ___  / /_ (_)__ __
 _\ \ / // // _ \/ __// _ \/ -_)/ __// / \ \ /
/___/ \_, //_//_/\__//_//_/\__/ \__//_/ /_\_\
     /___/

* Synthetix: BASISCASHRewards.sol
*
* Docs: https://docs.synthetix.io/
*
*
* MIT License
* ===========
*
* Copyright (c) 2020 Synthetix
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import '../utils/Epoch.sol';

contract ShareDistributor is Epoch {
    using SafeERC20 for IERC20;

    IERC20 public oneShare;
    
    struct Pool {
        address poolAddress;
        uint256 weight;
    }

    Pool[] public pools;
    uint256 public periodReward;

    event RewardDistribution(address pool, uint256 reward);

    constructor(
        address oneShare_,
        uint256 _startTime
    ) public Epoch(5 days, _startTime, 0) {
        oneShare = IERC20(oneShare_);
        periodReward = uint256(25000 * 10 ** 18).div(18);
    }

    function getLeftShares() public view returns(uint256) {
        return oneShare.balanceOf(address(this));
    }
    
    function setPools(Pool[] calldata _pools) public onlyOperator {
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < _pools.length; i++) {
            totalWeight = totalWeight.add(_pools[i].weight);
        }
        require(totalWeight == 10000, "ShareDistributor: invalid pools");
        pools = _pools;
    }

    function distribute() public checkEpoch {
        uint256 idx = getCurrentEpoch().sub(1);
        
        // half every 90 days (90 = 18 * 5)
        if (idx == idx.div(18).mul(18) && idx > 0) {
            periodReward = periodReward.div(2);
        }
        
        for (uint256 i = 0; i < pools.length; i++) {
            uint256 amount = periodReward.mul(pools[i].weight).div(10000);
            IERC20(oneShare).safeTransfer(pools[i].poolAddress, amount);
            IPool(pools[i].poolAddress).allocateReward(amount);
            emit RewardDistribution(pools[i].poolAddress, amount);
        }
    }
}

interface IPool {
    function allocateReward(uint256 amount) external;
}
