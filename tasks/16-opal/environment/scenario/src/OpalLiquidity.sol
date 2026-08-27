// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IOpalRewardProvider {
    function assetInfo() external view returns (uint8 kind, address asset, uint8 decimals);
    function rewardTokens() external view returns (address[] memory tokens);
    function releaseRewards(address receiver) external;
}

contract OpalMarketShare {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    address public immutable asset;
    address public immutable rewardProvider;
    address public immutable factory;
    address public harvester;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address asset_, address provider_, string memory symbol_) {
        require(asset_ != address(0) && provider_ != address(0), "market");
        asset = asset_;
        rewardProvider = provider_;
        factory = msg.sender;
        name = string.concat("Opal Market ", symbol_);
        symbol = symbol_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address receiver, uint256 amount) external returns (bool) {
        _move(msg.sender, receiver, amount);
        return true;
    }

    function transferFrom(address owner, address receiver, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[owner][msg.sender];
        if (permitted != type(uint256).max) allowance[owner][msg.sender] = permitted - amount;
        _move(owner, receiver, amount);
        return true;
    }

    function assetInfo() external view returns (uint8 kind, address stakingAsset, uint8 assetDecimals) {
        (kind, stakingAsset, assetDecimals) = IOpalRewardProvider(rewardProvider).assetInfo();
        require(stakingAsset == asset && assetDecimals <= 18, "metadata");
    }

    function bindHarvester(address harvester_) external {
        require(harvester == address(0) && harvester_ != address(0), "harvester");
        require(msg.sender == factory || tx.origin == factory, "factory");
        harvester = harvester_;
    }

    function rewardTokens() external view returns (address[] memory tokens) {
        return IOpalRewardProvider(rewardProvider).rewardTokens();
    }

    function addLiquidity(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets != 0 && receiver != address(0), "liquidity");
        uint256 managedBefore = IERC20Like(asset).balanceOf(address(this));
        require(IERC20Like(asset).transferFrom(msg.sender, address(this), assets), "asset in");
        shares = totalSupply == 0 ? assets : assets * totalSupply / managedBefore;
        require(shares != 0, "shares");
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function removeLiquidity(uint256 shares, address receiver) external returns (uint256 assets) {
        require(shares != 0 && receiver != address(0), "liquidity");
        assets = IERC20Like(asset).balanceOf(address(this)) * shares / totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        require(IERC20Like(asset).transfer(receiver, assets), "asset out");
    }

    function claimRewards(address receiver) external {
        require(msg.sender == harvester && receiver == harvester, "harvester");
        IOpalRewardProvider(rewardProvider).releaseRewards(receiver);
    }

    function _move(address owner, address receiver, uint256 amount) private {
        require(receiver != address(0), "receiver");
        balanceOf[owner] -= amount;
        balanceOf[receiver] += amount;
    }
}

contract OpalMarketFactory {
    address public administrator = msg.sender;
    address public harvester;
    uint256 public serial;
    mapping(address => bool) public isMarket;

    event MarketCreated(address indexed market, address indexed asset, address indexed rewardProvider, uint256 serial);

    function create(address asset, address rewardProvider) external returns (address market) {
        market = address(new OpalMarketShare(asset, rewardProvider, string.concat("OM-", _decimal(serial))));
        require(harvester != address(0), "harvester");
        OpalMarketShare(market).bindHarvester(harvester);
        isMarket[market] = true;
        emit MarketCreated(market, asset, rewardProvider, serial++);
    }

    function adopt(address market) external {
        require(msg.sender == administrator && !isMarket[market], "administrator");
        require(harvester != address(0), "harvester");
        OpalMarketShare(market).bindHarvester(harvester);
        isMarket[market] = true;
        emit MarketCreated(
            market,
            OpalMarketShare(market).asset(),
            OpalMarketShare(market).rewardProvider(),
            serial++
        );
    }

    function configureHarvester(address harvester_) external {
        require(msg.sender == administrator && harvester == address(0) && harvester_ != address(0), "administrator");
        harvester = harvester_;
    }

    function finishConfiguration() external {
        require(msg.sender == administrator, "administrator");
        administrator = address(0);
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        if (value < 10) return string(abi.encodePacked(bytes1(uint8(48 + value))));
        return string(abi.encodePacked(bytes1(uint8(48 + value / 10)), bytes1(uint8(48 + value % 10))));
    }
}

contract OpalRewardSource {
    address public administrator = msg.sender;
    address public market;
    address public rewardAsset;

    function configure(address market_, address rewardAsset_) external {
        require(msg.sender == administrator && market == address(0), "configuration");
        require(market_ != address(0) && rewardAsset_ != address(0), "addresses");
        market = market_;
        rewardAsset = rewardAsset_;
        administrator = address(0);
    }

    function release(address receiver) external returns (uint256 amount) {
        require(msg.sender == market, "market");
        amount = IERC20Like(rewardAsset).balanceOf(address(this));
        if (amount != 0) require(IERC20Like(rewardAsset).transfer(receiver, amount), "reward");
    }
}

contract OpalRewardAdapter is IOpalRewardProvider {
    address public administrator = msg.sender;
    address public immutable underlying;
    uint8 public immutable underlyingDecimals;
    address public market;
    address public source;

    constructor(address underlying_, uint8 decimals_) {
        underlying = underlying_;
        underlyingDecimals = decimals_;
    }

    function configure(address market_, address source_) external {
        require(msg.sender == administrator && market == address(0), "configuration");
        market = market_;
        source = source_;
        administrator = address(0);
    }

    function assetInfo() external view returns (uint8, address, uint8) {
        return (1, underlying, underlyingDecimals);
    }

    function rewardTokens() external view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = market;
    }

    function releaseRewards(address receiver) external {
        require(msg.sender == market, "market");
        OpalRewardSource(source).release(receiver);
    }
}
