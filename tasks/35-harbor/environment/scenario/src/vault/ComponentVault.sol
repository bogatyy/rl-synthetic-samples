// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProtocolERC20} from "../token/ProtocolERC20.sol";

interface ISettlement {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract ComponentVault is ProtocolERC20 {
    struct Epoch {
        uint64 openedAt;
        uint64 closedAt;
        uint128 deposits;
        uint128 withdrawals;
        bytes32 settlementRoot;
    }
    ISettlement public immutable asset;
    address public immutable factory;
    bytes32 public immutable marketId;
    uint256 public currentEpoch;
    uint256 public queuedWithdrawalShares;
    mapping(uint256 => Epoch) public epochs;
    mapping(address => uint256) public pendingWithdrawals;
    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event WithdrawInitiated(address indexed account, uint256 shares, uint256 assets, uint256 indexed epoch);
    event EpochRolled(uint256 indexed epoch, bytes32 settlementRoot);

    constructor(address asset_, string memory symbol_, bytes32 marketId_) ProtocolERC20("Thetanuts Component Vault", symbol_, 18) {
        asset = ISettlement(asset_);
        factory = msg.sender;
        marketId = marketId_;
        epochs[0].openedAt = uint64(block.timestamp);
    }

    function convertToShares(uint256 assets) public pure returns (uint256) { return assets * 1e12; }
    function convertToAssets(uint256 shares) public pure returns (uint256) { return shares / 1e12; }
    function totalAssets() external view returns (uint256) { return asset.balanceOf(address(this)); }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assets != 0, "zero assets");
        shares = convertToShares(assets);
        require(asset.transferFrom(msg.sender, address(this), assets), "asset transfer");
        _mint(receiver, shares);
        epochs[currentEpoch].deposits += uint128(assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function initWithdraw(uint256 shares) external returns (uint256 assets) {
        require(shares != 0, "zero shares");
        assets = convertToAssets(shares);
        _burn(msg.sender, shares);
        queuedWithdrawalShares += shares;
        pendingWithdrawals[msg.sender] += assets;
        epochs[currentEpoch].withdrawals += uint128(assets);
        require(asset.transfer(msg.sender, assets), "withdraw transfer");
        emit WithdrawInitiated(msg.sender, shares, assets, currentEpoch);
    }

    function rollEpoch(bytes32 settlementRoot) external {
        require(msg.sender == factory, "factory");
        Epoch storage old = epochs[currentEpoch];
        old.closedAt = uint64(block.timestamp);
        old.settlementRoot = settlementRoot;
        emit EpochRolled(currentEpoch, settlementRoot);
        unchecked { ++currentEpoch; }
        epochs[currentEpoch].openedAt = uint64(block.timestamp);
    }
}

contract ComponentVaultFactory {
    address public immutable settlement;
    address[] private vaults;
    mapping(bytes32 => address) public vaultForMarket;
    event VaultCreated(address indexed vault, bytes32 indexed marketId, uint256 indexed ordinal);
    constructor(address settlement_) { settlement = settlement_; }
    function createVault(string calldata symbol, bytes32 marketId) external returns (address vault) {
        require(vaultForMarket[marketId] == address(0), "market exists");
        vault = address(new ComponentVault(settlement, symbol, marketId));
        vaultForMarket[marketId] = vault;
        vaults.push(vault);
        emit VaultCreated(vault, marketId, vaults.length - 1);
    }
    function vaultCount() external view returns (uint256) { return vaults.length; }
}
