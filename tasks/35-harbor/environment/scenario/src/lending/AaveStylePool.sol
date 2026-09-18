// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProtocolERC20} from "../token/ProtocolERC20.sol";

interface IERC20Reserve {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

contract ReserveAToken is ProtocolERC20 {
    address public immutable POOL;
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public treasury;
    uint128 public liquidityIndex = 1e27;
    uint40 public lastUpdateTimestamp;
    event Mint(address indexed caller, address indexed onBehalfOf, uint256 amount, uint256 index);
    event Burn(address indexed from, address indexed receiver, uint256 amount, uint256 index);

    constructor(address pool_, address underlying_, address treasury_)
        ProtocolERC20("Aave Ethereum Index USDC PUT", "aEthTNIDX", 18)
    {
        POOL = pool_;
        UNDERLYING_ASSET_ADDRESS = underlying_;
        treasury = treasury_;
        lastUpdateTimestamp = uint40(block.timestamp);
    }

    function mint(address caller, address onBehalfOf, uint256 amount, uint256 index) external returns (bool) {
        require(msg.sender == POOL, "pool");
        _mint(onBehalfOf, amount);
        liquidityIndex = uint128(index);
        lastUpdateTimestamp = uint40(block.timestamp);
        emit Mint(caller, onBehalfOf, amount, index);
        return balanceOf[onBehalfOf] == amount;
    }

    function burn(address from, address receiver, uint256 amount, uint256 index) external {
        require(msg.sender == POOL, "pool");
        _burn(from, amount);
        IERC20Reserve(UNDERLYING_ASSET_ADDRESS).transfer(receiver, amount);
        liquidityIndex = uint128(index);
        emit Burn(from, receiver, amount, index);
    }

    function transferUnderlyingTo(address target, uint256 amount) external {
        require(msg.sender == POOL, "pool");
        require(IERC20Reserve(UNDERLYING_ASSET_ADDRESS).transfer(target, amount), "underlying transfer");
    }
}

contract PoolAddressesProvider {
    address public owner;
    mapping(bytes32 => address) private addresses;
    event AddressSet(bytes32 indexed id, address indexed oldAddress, address indexed newAddress);
    constructor() { owner = msg.sender; }
    function setAddress(bytes32 id, address value) external { require(msg.sender == owner, "owner"); emit AddressSet(id, addresses[id], value); addresses[id] = value; }
    function getAddress(bytes32 id) external view returns (address) { return addresses[id]; }
    function getPool() external view returns (address) { return addresses[keccak256("POOL")]; }
    function transferOwnership(address next) external { require(msg.sender == owner, "owner"); owner = next; }
}

contract AaveStylePool {
    struct ReserveData {
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint40 lastUpdateTimestamp;
        address aTokenAddress;
        bool active;
        bool flashLoanEnabled;
    }
    PoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    address public configurator;
    mapping(address => ReserveData) private reserves;
    mapping(address => uint256) public suppliedPrincipal;
    uint128 public constant FLASHLOAN_PREMIUM_TOTAL = 9;
    event ReserveInitialized(address indexed asset, address indexed aToken, uint128 liquidityIndex);
    event Supply(address indexed reserve, address indexed user, address indexed onBehalfOf, uint256 amount, uint16 referralCode);
    event FlashLoan(address indexed target, address indexed initiator, address indexed asset, uint256 amount, uint256 premium, uint16 referralCode);

    constructor(address provider_) { ADDRESSES_PROVIDER = PoolAddressesProvider(provider_); configurator = msg.sender; }

    function initReserve(address asset, address aToken) external {
        require(msg.sender == configurator && !reserves[asset].active, "configurator");
        reserves[asset] = ReserveData(1e27, 0, uint40(block.timestamp), aToken, true, true);
        emit ReserveInitialized(asset, aToken, 1e27);
    }

    function getReserveData(address asset) external view returns (ReserveData memory) { return reserves[asset]; }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        ReserveData storage reserve = reserves[asset];
        require(reserve.active && amount != 0, "reserve");
        require(IERC20Reserve(asset).transferFrom(msg.sender, reserve.aTokenAddress, amount), "supply transfer");
        ReserveAToken(reserve.aTokenAddress).mint(msg.sender, onBehalfOf, amount, reserve.liquidityIndex);
        suppliedPrincipal[onBehalfOf] += amount;
        emit Supply(asset, msg.sender, onBehalfOf, amount, referralCode);
    }

    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external {
        require(assets.length == 1 && amounts.length == 1 && interestRateModes.length == 1, "single reserve");
        require(interestRateModes[0] == 0 && onBehalfOf == receiverAddress, "flash mode");
        ReserveData storage reserve = reserves[assets[0]];
        require(reserve.active && reserve.flashLoanEnabled, "flash disabled");
        uint256 amount = amounts[0];
        uint256 premium = amount * FLASHLOAN_PREMIUM_TOTAL / 10_000;
        ReserveAToken(reserve.aTokenAddress).transferUnderlyingTo(receiverAddress, amount);
        address[] memory callbackAssets = new address[](1); callbackAssets[0] = assets[0];
        uint256[] memory callbackAmounts = new uint256[](1); callbackAmounts[0] = amount;
        uint256[] memory premiums = new uint256[](1); premiums[0] = premium;
        require(IFlashLoanReceiver(receiverAddress).executeOperation(callbackAssets, callbackAmounts, premiums, receiverAddress, params), "callback");
        require(IERC20Reserve(assets[0]).transferFrom(receiverAddress, reserve.aTokenAddress, amount + premium), "repayment");
        reserve.lastUpdateTimestamp = uint40(block.timestamp);
        emit FlashLoan(receiverAddress, msg.sender, assets[0], amount, premium, referralCode);
    }
}
