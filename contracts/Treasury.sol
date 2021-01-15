pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import './interfaces/IOracle.sol';
import './interfaces/IBoardroom.sol';
import './interfaces/IBasisAsset.sol';
import './interfaces/ISimpleERCFund.sol';
import './interfaces/ITreasury.sol';
import './interfaces/IONBRewardPool.sol';
import './lib/Babylonian.sol';
import './lib/FixedPoint.sol';
import './lib/Safe112.sol';
import './owner/Operator.sol';
import './utils/Epoch.sol';
import './utils/ContractGuard.sol';

/**
 * @title Basis Cash Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis cash assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== STATE VARIABLES ========== */

    // ========== FLAGS
    bool public migrated = false;
    bool public initialized = false;

    // ========== CORE
    address public fund;
    address public cash;
    address public bond;
    address public share;
    address public shareBoardroom;
    address public lpBoardroom;
    address public bondRewardPool;

    //address public bondOracle;
    //address public seigniorageOracle;
    address public oracle;

    // ========== PARAMS
    uint256 public cashPriceOne;
    uint256 public cashPriceCeiling;
    uint256 public cashPriceFloor;
    uint256 public cashPriceBondReward;

    uint256 private accumulatedSeigniorage = 0;
    uint256 private accumulatedDebt = 0;
    uint256 public bondPriceOnONC;
    uint256 public minBondPriceOnONC;
    uint256 public bondPriceOnONCDelta;

    uint256 public fundAllocationRate = 2; // %
    uint256 public maxInflationRate = 10;
    
    uint256 public debtAddRate = 2;
    uint256 public maxDebtRate = 20;

    // ========== MIGRATE
    address public legacyTreasury;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _cash,
        address _bond,
        address _share,
        address _oracle,
        address _shareBoardroom,
        address _lpBoardroom,
        address _bondRewardPool,
        address _fund,
        uint256 _startTime
    ) public Epoch(8 hours, _startTime, 0) {
        cash = _cash;
        bond = _bond;
        share = _share;
        oracle = _oracle;

        shareBoardroom = _shareBoardroom;
        lpBoardroom = _lpBoardroom;
        bondRewardPool = _bondRewardPool;

        fund = _fund;

        cashPriceOne = 10**18;
        cashPriceCeiling = uint256(102).mul(cashPriceOne).div(10**2);
        cashPriceFloor = uint256(98).mul(cashPriceOne).div(10**2);
        cashPriceBondReward = uint256(95).mul(cashPriceOne).div(10**2);
        
        bondPriceOnONC = 10**18;
        minBondPriceOnONC = 5 * 10**17;
        bondPriceOnONCDelta = 2 * 10 ** 16;
    }

    /* =================== Modifier =================== */

    modifier checkMigration {
        require(!migrated, 'Treasury: migrated');

        _;
    }

    modifier checkOperator {
        require(
            IBasisAsset(cash).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(shareBoardroom).operator() == address(this) &&
                Operator(lpBoardroom).operator() == address(this) &&
                Operator(bondRewardPool).operator() == address(this),
            'Treasury: need more permission'
        );

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // budget
    function getReserve() public view returns (uint256) {
        return accumulatedSeigniorage;
    }

    // debt
    function getDebt() public view returns (uint256) {
        return accumulatedDebt;
    }

    // oracle
    function getOraclePrice() public view returns (uint256) {
        return _getCashPrice(oracle);
    }

    function _getCashPrice(address _oracle) internal view returns (uint256) {
        try IOracle(_oracle).consult(cash, 1e18) returns (uint256 price) {
            return price;
        } catch {
            revert('Treasury: failed to consult cash price from the oracle');
        }
    }

    /* ========== GOVERNANCE ========== */
    function setLegacyTreasury(address _legacyTreasury) public onlyOperator {
        legacyTreasury = _legacyTreasury;
    }

    function initialize(
        uint256 _accumulatedSeigniorage,
        uint256 _accumulatedDebt,
        uint256 _bondPriceOnONC
    ) public {
        require(!initialized, 'Treasury: initialized');
        require(msg.sender == legacyTreasury, 'Treasury: on legacy treasury');

        accumulatedSeigniorage = _accumulatedSeigniorage;
        accumulatedDebt = _accumulatedDebt;
        bondPriceOnONC = _bondPriceOnONC;

        initialized = true;
        emit Initialized(msg.sender, block.number);
    }

    function migrate(address target) public onlyOperator checkOperator {
        require(!migrated, 'Treasury: migrated');

        // cash
        Operator(cash).transferOperator(target);
        Operator(cash).transferOwnership(target);
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        // params
        ITreasury(target).initialize(
            accumulatedSeigniorage, 
            accumulatedDebt,
            bondPriceOnONC
        );

        migrated = true;
        emit Migration(target);
    }

    function setFund(address newFund) public onlyOperator {
        fund = newFund;
        emit ContributionPoolChanged(msg.sender, newFund);
    }

    function setFundAllocationRate(uint256 rate) public onlyOperator {
        fundAllocationRate = rate;
        emit ContributionPoolRateChanged(msg.sender, rate);
    }

    function setMaxInflationRate(uint256 rate) public onlyOperator {
        maxInflationRate = rate;
        emit MaxInflationRateChanged(msg.sender, rate);
    }

    function setDebtAddRate(uint256 rate) public onlyOperator {
        debtAddRate = rate;
        emit DebtAddRateChanged(msg.sender, rate);
    }

    function setMaxDebtRate(uint256 rate) public onlyOperator {
        maxDebtRate = rate;
        emit MaxDebtRateChanged(msg.sender, rate);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateCashPrice() internal {
        try IOracle(oracle).update()  {} catch {}
    }

    function buyBonds(uint256 amount)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        uint256 cashPrice = _getCashPrice(oracle);
        require(
            cashPrice < cashPriceOne, // price < $1
            'Treasury: cashPrice not eligible for bond purchase'
        );

        uint256 burnAmount = Math.min(
            amount,
            accumulatedDebt.mul(bondPriceOnONC).div(1e18)
        );
        require(burnAmount > 0, 'Treasury: cannot purchase bonds with zero amount');

        uint256 mintBondAmount = burnAmount.mul(1e18).div(bondPriceOnONC);
        IBasisAsset(cash).burnFrom(msg.sender, burnAmount);
        IBasisAsset(bond).mint(msg.sender, mintBondAmount);
        accumulatedDebt = accumulatedDebt.sub(mintBondAmount);
        _updateCashPrice();

        emit BoughtBonds(msg.sender, burnAmount);
    }

    function redeemBonds(uint256 amount)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        uint256 cashPrice = _getCashPrice(oracle);
        require(
            cashPrice > cashPriceOne, // price > $1
            'Treasury: cashPrice not eligible for bond redeem'
        );

        uint256 redeemAmount = Math.min(accumulatedSeigniorage, amount);
        require(redeemAmount > 0, 'Treasury: cannot redeem bonds with zero amount');

        accumulatedSeigniorage = accumulatedSeigniorage.sub(redeemAmount);
        IBasisAsset(bond).burnFrom(msg.sender, redeemAmount);
        IERC20(cash).safeTransfer(msg.sender, redeemAmount);
        _updateCashPrice();

        emit RedeemedBonds(msg.sender, redeemAmount);
    }

    function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkOperator
    {
        _updateCashPrice();
        uint256 cashPrice = _getCashPrice(oracle);
        // circulating supply
        uint256 cashSupply = IERC20(cash).totalSupply().sub(
            accumulatedSeigniorage
        );

        // bond reward
        if (cashPrice <= cashPriceBondReward) {
            uint256 rewardAmount = IERC20(bond).totalSupply().div(100);
            IBasisAsset(bond).mint(bondRewardPool, rewardAmount);
            IONBRewardPool(bondRewardPool).notifyRewardAmount(rewardAmount);
            emit BondReward(block.timestamp, rewardAmount);
        }    

        // add debt
        if (cashPrice <= cashPriceFloor) {
            uint256 addDebt = cashSupply.mul(debtAddRate).div(100);
            uint256 maxDebt = cashSupply.mul(maxDebtRate).div(100);
            accumulatedDebt = accumulatedDebt.add(addDebt);
            if (accumulatedDebt > maxDebt) {
                accumulatedDebt = maxDebt;
            }
            bondPriceOnONC = bondPriceOnONC.sub(bondPriceOnONCDelta);
            if (bondPriceOnONC <= minBondPriceOnONC) {
                bondPriceOnONC = minBondPriceOnONC;
            }
        }

        // clear the debt
        if (cashPrice > cashPriceFloor) {
            accumulatedDebt = 0;    
            bondPriceOnONC = 10**18;
        }

        if (cashPrice <= cashPriceCeiling) {
            return; // just advance epoch instead revert
        }
        
        uint256 percentage = cashPrice.sub(cashPriceOne);
        uint256 seigniorage = cashSupply.mul(percentage).div(1e18);
        uint256 maxSeigniorage = cashSupply.mul(maxInflationRate).div(100);
        if (seigniorage > maxSeigniorage) {
            seigniorage = maxSeigniorage;
        }
        IBasisAsset(cash).mint(address(this), seigniorage);

        // ======================== BIP-3
        uint256 fundReserve = seigniorage.mul(fundAllocationRate).div(100);
        if (fundReserve > 0) {
            IERC20(cash).safeApprove(fund, fundReserve);
            ISimpleERCFund(fund).deposit(
                cash,
                fundReserve,
                'Treasury: Seigniorage Allocation'
            );
            emit ContributionPoolFunded(now, fundReserve);
        }

        seigniorage = seigniorage.sub(fundReserve);

        // ======================== BIP-4
        uint256 treasuryReserve = Math.min(
            seigniorage.div(2),                 // only 50% inflation to treasury
            IERC20(bond).totalSupply().sub(accumulatedSeigniorage)
        );
        if (treasuryReserve > 0) {
            accumulatedSeigniorage = accumulatedSeigniorage.add(
                treasuryReserve
            );
            emit TreasuryFunded(now, treasuryReserve);
        }

        // boardroom
        uint256 boardroomReserve = seigniorage.sub(treasuryReserve);
        if (boardroomReserve > 0) {
            uint256 shareBoardroomReserve = boardroomReserve.mul(6).div(10);
            uint256 lpBoardroomReserve = boardroomReserve.sub(shareBoardroomReserve);
            IERC20(cash).safeApprove(shareBoardroom, shareBoardroomReserve);
            IBoardroom(shareBoardroom).allocateSeigniorage(shareBoardroomReserve);
            IERC20(cash).safeApprove(lpBoardroom, lpBoardroomReserve);
            IBoardroom(lpBoardroom).allocateSeigniorage(lpBoardroomReserve);
            emit BoardroomFunded(now, boardroomReserve);
        }
    }

    // GOV
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event ContributionPoolChanged(address indexed operator, address newFund);
    event ContributionPoolRateChanged(
        address indexed operator,
        uint256 newRate
    );
    event MaxInflationRateChanged(
        address indexed operator,
        uint256 newRate
    );
    event DebtAddRateChanged(
        address indexed operator,
        uint256 newRate
    );
    event MaxDebtRateChanged(
        address indexed operator,
        uint256 newRate
    );

    // CORE
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event BondReward(uint256 timestamp, uint256 seigniorage);
    event ContributionPoolFunded(uint256 timestamp, uint256 seigniorage);
}


