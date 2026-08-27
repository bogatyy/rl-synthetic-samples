// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./OpalLiquidity.sol";

contract OpalMarketRegistry {
    address public immutable factory;
    address public immutable settlementAsset;
    address public immutable baseAsset;
    mapping(address => bool) public approved;

    event MarketRegistered(address indexed market, address indexed stakingAsset, uint8 kind);

    constructor(address factory_, address settlementAsset_, address baseAsset_) {
        factory = factory_;
        settlementAsset = settlementAsset_;
        baseAsset = baseAsset_;
    }

    function register(address market) external {
        require(OpalMarketFactory(factory).isMarket(market), "factory");
        (uint8 kind, address stakingAsset, uint8 assetDecimals) = OpalMarketShare(market).assetInfo();
        require(kind < 4 && stakingAsset != address(0) && assetDecimals <= 18, "metadata");
        require(stakingAsset == settlementAsset || stakingAsset == baseAsset, "staking asset");
        address[] memory rewards = OpalMarketShare(market).rewardTokens();
        require(rewards.length != 0 && rewards.length <= 4, "rewards");
        for (uint256 i; i < rewards.length; ++i) {
            require(rewards[i] != address(0), "reward token");
        }
        approved[market] = true;
        emit MarketRegistered(market, stakingAsset, kind);
    }
}

contract OpalStakingHub {
    struct PoolState {
        uint128 totalStaked;
        uint64 lastHarvestBlock;
        bool active;
    }

    address public administrator = msg.sender;
    address public settlementAsset;
    address public baseAsset;
    address public protectedReserve;
    address public liquidityBank;
    address public marketFactory;
    address public marketRegistry;
    mapping(address => PoolState) public pools;
    mapping(address => mapping(address => uint256)) public stakeOf;
    mapping(address => mapping(address => uint256)) public rewardIntegral;
    mapping(address => mapping(address => mapping(address => uint256))) public rewardDebt;
    mapping(address => mapping(address => mapping(address => uint256))) public credit;

    event HubConfigured(address indexed registry, address indexed bank);
    event PoolActivated(address indexed market, address indexed asset);
    event Staked(address indexed market, address indexed account, uint256 amount);
    event Withdrawn(address indexed market, address indexed account, uint256 amount);
    event Harvested(address indexed market, address indexed caller, address indexed token, uint256 amount);

    function configure(address cash, address base, address bank, address factory, address registry) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        baseAsset = base;
        liquidityBank = bank;
        marketFactory = factory;
        marketRegistry = registry;
        emit HubConfigured(registry, bank);
    }

    function setProtectedReserve(address market) external {
        require(msg.sender == administrator && protectedReserve == address(0), "administrator");
        require(OpalMarketRegistry(marketRegistry).approved(market), "market");
        protectedReserve = market;
        administrator = address(0);
    }

    function activateMarket(address market) public {
        require(OpalMarketRegistry(marketRegistry).approved(market), "registry");
        PoolState storage pool = pools[market];
        if (!pool.active) {
            pool.active = true;
            pool.lastHarvestBlock = uint64(block.number);
            emit PoolActivated(market, OpalMarketShare(market).asset());
        }
    }

    function stake(address market, uint256 amount, address account) external {
        require(amount != 0 && account != address(0), "stake");
        activateMarket(market);
        _checkpoint(market, account);
        require(IERC20Like(market).transferFrom(msg.sender, address(this), amount), "market in");
        pools[market].totalStaked += uint128(amount);
        stakeOf[market][account] += amount;
        _resetDebt(market, account);
        emit Staked(market, account, amount);
    }

    function withdraw(address market, uint256 amount, address receiver) external {
        require(amount != 0 && receiver != address(0), "withdraw");
        _checkpoint(market, msg.sender);
        stakeOf[market][msg.sender] -= amount;
        pools[market].totalStaked -= uint128(amount);
        _resetDebt(market, msg.sender);
        require(IERC20Like(market).transfer(receiver, amount), "market out");
        emit Withdrawn(market, msg.sender, amount);
    }

    function harvest(address market) public {
        PoolState storage pool = pools[market];
        require(pool.active && block.number > pool.lastHarvestBlock && pool.totalStaked != 0, "harvest");
        address[] memory tokens = OpalMarketShare(market).rewardTokens();
        uint256[] memory balancesBefore = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            balancesBefore[i] = IERC20Like(tokens[i]).balanceOf(address(this));
        }

        OpalMarketShare(market).claimRewards(address(this));

        for (uint256 i; i < tokens.length; ++i) {
            uint256 received = IERC20Like(tokens[i]).balanceOf(address(this)) - balancesBefore[i];
            if (received != 0) {
                rewardIntegral[market][tokens[i]] += received * 1 ether / pool.totalStaked;
                emit Harvested(market, msg.sender, tokens[i], received);
            }
        }
        pool.lastHarvestBlock = uint64(block.number);
        _checkpoint(market, msg.sender);
    }

    function claim(address market, address token, uint256 amount, address receiver) external {
        require(amount != 0 && receiver != address(0), "claim");
        _checkpoint(market, msg.sender);
        credit[market][msg.sender][token] -= amount;
        require(IERC20Like(token).transfer(receiver, amount), "reward out");
    }

    function rewardTokenCount(address market) external view returns (uint256) {
        return OpalMarketShare(market).rewardTokens().length;
    }

    function _checkpoint(address market, address account) private {
        if (!pools[market].active) return;
        address[] memory tokens = OpalMarketShare(market).rewardTokens();
        uint256 stakeBalance = stakeOf[market][account];
        for (uint256 i; i < tokens.length; ++i) {
            uint256 accrued = stakeBalance * rewardIntegral[market][tokens[i]] / 1 ether;
            uint256 debt = rewardDebt[market][account][tokens[i]];
            if (accrued > debt) credit[market][account][tokens[i]] += accrued - debt;
            rewardDebt[market][account][tokens[i]] = accrued;
        }
    }

    function _resetDebt(address market, address account) private {
        address[] memory tokens = OpalMarketShare(market).rewardTokens();
        uint256 stakeBalance = stakeOf[market][account];
        for (uint256 i; i < tokens.length; ++i) {
            rewardDebt[market][account][tokens[i]] = stakeBalance * rewardIntegral[market][tokens[i]] / 1 ether;
        }
    }
}
