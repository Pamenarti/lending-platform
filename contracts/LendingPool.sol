// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IInterestRateModel.sol";

contract LendingPool is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    struct Market {
        IERC20 token;
        uint256 totalSupply;
        uint256 totalBorrows;
        uint256 lastUpdateTimestamp;
        uint256 reserveFactor;
        uint256 collateralFactor;
        IInterestRateModel interestRateModel;
        bool isListed;
    }

    struct UserData {
        uint256 borrowed;
        uint256 supplied;
        uint256 lastUpdateTimestamp;
    }

    mapping(address => Market) public markets;
    mapping(address => mapping(address => UserData)) public userData;
    mapping(address => bool) public isMarketListed;
    
    IPriceOracle public priceOracle;
    uint256 public constant PRECISION = 1e18;
    uint256 public liquidationIncentive;

    event MarketListed(address token, address interestRateModel);
    event Supplied(address token, address user, uint256 amount);
    event Borrowed(address token, address user, uint256 amount);
    event Repaid(address token, address user, uint256 amount);
    event Withdrawn(address token, address user, uint256 amount);
    event Liquidated(
        address liquidator,
        address borrower,
        address tokenBorrowed,
        address tokenCollateral,
        uint256 amount
    );

    constructor(address _priceOracle, uint256 _liquidationIncentive) {
        priceOracle = IPriceOracle(_priceOracle);
        liquidationIncentive = _liquidationIncentive;
    }

    function listMarket(
        address _token,
        address _interestRateModel,
        uint256 _reserveFactor,
        uint256 _collateralFactor
    ) external onlyOwner {
        require(!isMarketListed[_token], "Market already listed");
        require(_collateralFactor <= PRECISION, "Invalid collateral factor");
        require(_reserveFactor <= PRECISION, "Invalid reserve factor");

        markets[_token] = Market({
            token: IERC20(_token),
            totalSupply: 0,
            totalBorrows: 0,
            lastUpdateTimestamp: block.timestamp,
            reserveFactor: _reserveFactor,
            collateralFactor: _collateralFactor,
            interestRateModel: IInterestRateModel(_interestRateModel),
            isListed: true
        });

        isMarketListed[_token] = true;
        emit MarketListed(_token, _interestRateModel);
    }

    function supply(address _token, uint256 _amount) external nonReentrant {
        Market storage market = markets[_token];
        require(market.isListed, "Market not listed");
        require(_amount > 0, "Amount must be greater than 0");

        updateMarketInterest(_token);
        
        UserData storage user = userData[_token][msg.sender];
        user.supplied = user.supplied.add(_amount);
        user.lastUpdateTimestamp = block.timestamp;
        
        market.totalSupply = market.totalSupply.add(_amount);
        market.token.transferFrom(msg.sender, address(this), _amount);

        emit Supplied(_token, msg.sender, _amount);
    }

    function borrow(address _token, uint256 _amount) external nonReentrant {
        Market storage market = markets[_token];
        require(market.isListed, "Market not listed");
        require(_amount > 0, "Amount must be greater than 0");
        require(
            getAccountLiquidity(msg.sender) >= _amount,
            "Insufficient collateral"
        );

        updateMarketInterest(_token);
        
        UserData storage user = userData[_token][msg.sender];
        user.borrowed = user.borrowed.add(_amount);
        user.lastUpdateTimestamp = block.timestamp;
        
        market.totalBorrows = market.totalBorrows.add(_amount);
        market.token.transfer(msg.sender, _amount);

        emit Borrowed(_token, msg.sender, _amount);
    }

    function repay(address _token, uint256 _amount) external nonReentrant {
        Market storage market = markets[_token];
        require(market.isListed, "Market not listed");

        updateMarketInterest(_token);
        
        UserData storage user = userData[_token][msg.sender];
        uint256 repayAmount = _amount > user.borrowed ? user.borrowed : _amount;
        
        user.borrowed = user.borrowed.sub(repayAmount);
        user.lastUpdateTimestamp = block.timestamp;
        
        market.totalBorrows = market.totalBorrows.sub(repayAmount);
        market.token.transferFrom(msg.sender, address(this), repayAmount);

        emit Repaid(_token, msg.sender, repayAmount);
    }

    function withdraw(address _token, uint256 _amount) external nonReentrant {
        Market storage market = markets[_token];
        require(market.isListed, "Market not listed");

        updateMarketInterest(_token);
        
        UserData storage user = userData[_token][msg.sender];
        require(user.supplied >= _amount, "Insufficient balance");
        
        uint256 newSupplyBalance = user.supplied.sub(_amount);
        require(
            getAccountLiquidity(msg.sender) >= 0,
            "Withdrawal would cause undercollateralization"
        );
        
        user.supplied = newSupplyBalance;
        user.lastUpdateTimestamp = block.timestamp;
        
        market.totalSupply = market.totalSupply.sub(_amount);
        market.token.transfer(msg.sender, _amount);

        emit Withdrawn(_token, msg.sender, _amount);
    }

    function liquidate(
        address _borrower,
        address _tokenBorrowed,
        address _tokenCollateral,
        uint256 _amount
    ) external nonReentrant {
        require(
            getAccountHealth(_borrower) < PRECISION,
            "Account not liquidatable"
        );

        Market storage borrowedMarket = markets[_tokenBorrowed];
        Market storage collateralMarket = markets[_tokenCollateral];
        
        updateMarketInterest(_tokenBorrowed);
        updateMarketInterest(_tokenCollateral);
        
        UserData storage borrowerData = userData[_tokenBorrowed][_borrower];
        require(_amount <= borrowerData.borrowed, "Amount too high");
        
        uint256 collateralAmount = _calculateLiquidationAmount(
            _amount,
            _tokenBorrowed,
            _tokenCollateral
        );
        
        // Update borrowed token state
        borrowerData.borrowed = borrowerData.borrowed.sub(_amount);
        borrowedMarket.totalBorrows = borrowedMarket.totalBorrows.sub(_amount);
        
        // Update collateral token state
        userData[_tokenCollateral][_borrower].supplied = 
            userData[_tokenCollateral][_borrower].supplied.sub(collateralAmount);
        collateralMarket.totalSupply = collateralMarket.totalSupply.sub(collateralAmount);
        
        // Transfer tokens
        borrowedMarket.token.transferFrom(msg.sender, address(this), _amount);
        collateralMarket.token.transfer(msg.sender, collateralAmount);

        emit Liquidated(
            msg.sender,
            _borrower,
            _tokenBorrowed,
            _tokenCollateral,
            _amount
        );
    }

    // Internal functions
    function updateMarketInterest(address _token) internal {
        Market storage market = markets[_token];
        uint256 timeElapsed = block.timestamp.sub(market.lastUpdateTimestamp);
        if (timeElapsed > 0) {
            uint256 borrowRate = market.interestRateModel.getBorrowRate(
                market.totalSupply,
                market.totalBorrows
            );
            
            uint256 interestAccumulated = market.totalBorrows
                .mul(borrowRate)
                .mul(timeElapsed)
                .div(365 days)
                .div(PRECISION);
            
            market.totalBorrows = market.totalBorrows.add(interestAccumulated);
            market.lastUpdateTimestamp = block.timestamp;
        }
    }

    function getAccountLiquidity(address _account) public view returns (uint256) {
        uint256 collateralValue = 0;
        uint256 borrowValue = 0;
        
        address[] memory listedMarkets = getListedMarkets();
        
        for (uint256 i = 0; i < listedMarkets.length; i++) {
            address token = listedMarkets[i];
            Market storage market = markets[token];
            UserData storage user = userData[token][_account];
            
            uint256 tokenPrice = priceOracle.getPrice(token);
            
            // Calculate collateral value
            uint256 collateral = user.supplied
                .mul(market.collateralFactor)
                .mul(tokenPrice)
                .div(PRECISION);
            collateralValue = collateralValue.add(collateral);
            
            // Calculate borrow value
            uint256 borrowed = user.borrowed.mul(tokenPrice).div(PRECISION);
            borrowValue = borrowValue.add(borrowed);
        }
        
        return collateralValue > borrowValue ? 
            collateralValue.sub(borrowValue) : 0;
    }

    function getAccountHealth(address _account) public view returns (uint256) {
        uint256 collateralValue = 0;
        uint256 borrowValue = 0;
        
        address[] memory listedMarkets = getListedMarkets();
        
        for (uint256 i = 0; i < listedMarkets.length; i++) {
            address token = listedMarkets[i];
            Market storage market = markets[token];
            UserData storage user = userData[token][_account];
            
            uint256 tokenPrice = priceOracle.getPrice(token);
            
            collateralValue = collateralValue.add(
                user.supplied
                    .mul(market.collateralFactor)
                    .mul(tokenPrice)
                    .div(PRECISION)
            );
            
            borrowValue = borrowValue.add(
                user.borrowed.mul(tokenPrice).div(PRECISION)
            );
        }
        
        return borrowValue > 0 ?
            collateralValue.mul(PRECISION).div(borrowValue) : PRECISION;
    }

    function _calculateLiquidationAmount(
        uint256 _borrowedAmount,
        address _tokenBorrowed,
        address _tokenCollateral
    ) internal view returns (uint256) {
        uint256 borrowedPrice = priceOracle.getPrice(_tokenBorrowed);
        uint256 collateralPrice = priceOracle.getPrice(_tokenCollateral);
        
        return _borrowedAmount
            .mul(borrowedPrice)
            .mul(liquidationIncentive)
            .div(collateralPrice)
            .div(PRECISION);
    }

    function getListedMarkets() public view returns (address[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < getMarketCount(); i++) {
            if (markets[address(uint160(i))].isListed) {
                count++;
            }
        }
        
        address[] memory listedMarkets = new address[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < getMarketCount(); i++) {
            if (markets[address(uint160(i))].isListed) {
                listedMarkets[index] = address(uint160(i));
                index++;
            }
        }
        
        return listedMarkets;
    }

    function getMarketCount() public view returns (uint256) {
        return type(uint160).max;
    }
} 