// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

contract LanternQuoteVenue {
    address public immutable cash;
    address public immutable quoteAsset;
    address public immutable provider;
    uint112 public cashReserve;
    uint112 public quoteReserve;

    constructor(address cash_, address quote_, address provider_) {
        cash = cash_;
        quoteAsset = quote_;
        provider = provider_;
    }

    function seed(uint256 cashAmount, uint256 quoteAmount) external {
        require(msg.sender == provider && cashReserve == 0, "provider");
        IERC20Like(cash).transferFrom(msg.sender, address(this), cashAmount);
        IERC20Like(quoteAsset).transferFrom(msg.sender, address(this), quoteAmount);
        _sync();
    }

    function quoteCash(uint256 quoteAmount) external view returns (uint256) {
        require(quoteReserve != 0, "reserve");
        return quoteAmount * uint256(cashReserve) / uint256(quoteReserve);
    }

    function close(address receiver) external {
        require(msg.sender == provider, "provider");
        IERC20Like(cash).transfer(receiver, IERC20Like(cash).balanceOf(address(this)));
        IERC20Like(quoteAsset).transfer(receiver, IERC20Like(quoteAsset).balanceOf(address(this)));
        _sync();
    }

    function _sync() private {
        uint256 c = IERC20Like(cash).balanceOf(address(this));
        uint256 q = IERC20Like(quoteAsset).balanceOf(address(this));
        require(c <= type(uint112).max && q <= type(uint112).max, "reserves");
        cashReserve = uint112(c);
        quoteReserve = uint112(q);
    }
}

contract LanternVenueFactory {
    mapping(address => bool) public isVenue;
    event VenueCreated(address indexed venue, address indexed cash, address indexed quote, address provider);

    function create(address cash, address quote) external returns (address venue) {
        venue = address(new LanternQuoteVenue(cash, quote, msg.sender));
        isVenue[venue] = true;
        emit VenueCreated(venue, cash, quote, msg.sender);
    }
}

contract LanternDeleverageMarket {
    address public immutable asset;
    address public immutable venue;
    address public immutable cash;
    uint256 public totalDeposits;
    mapping(address => uint256) public deposits;

    constructor(address cash_, address asset_, address venue_) {
        cash = cash_;
        asset = asset_;
        venue = venue_;
    }

    function recordDeposit(address account, uint256 amount) external {
        require(IERC20Like(asset).balanceOf(address(this)) >= totalDeposits + amount, "funding");
        totalDeposits += amount;
        deposits[account] += amount;
    }

    function previewRefund(uint256 amount) external view returns (uint256) {
        return LanternQuoteVenue(venue).quoteCash(amount);
    }
}

contract LanternMarketFactory {
    address public immutable venueFactory;
    mapping(address => bool) public isMarket;
    event MarketCreated(address indexed market, address indexed asset, address indexed venue);

    constructor(address venueFactory_) {
        venueFactory = venueFactory_;
    }

    function create(address cash, address asset, address venue) external returns (address market) {
        require(LanternVenueFactory(venueFactory).isVenue(venue), "venue");
        require(LanternQuoteVenue(venue).cash() == cash && LanternQuoteVenue(venue).quoteAsset() == asset, "pair");
        market = address(new LanternDeleverageMarket(cash, asset, venue));
        isMarket[market] = true;
        emit MarketCreated(market, asset, venue);
    }
}

contract LanternMarketRegistry {
    address public immutable marketFactory;
    address public immutable curator;
    mapping(address => bool) public approved;

    constructor(address factory_) {
        marketFactory = factory_;
        curator = msg.sender;
    }

    function register(address market) external {
        require(LanternMarketFactory(marketFactory).isMarket(market), "factory");
        require(
            LanternDeleverageMarket(market).asset() != address(0)
                && LanternDeleverageMarket(market).venue() != address(0),
            "metadata"
        );
        approved[market] = true;
    }
}
