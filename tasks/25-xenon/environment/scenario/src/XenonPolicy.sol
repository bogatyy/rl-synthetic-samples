// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract CheckpointPolicy {
    address public administrator = msg.sender;
    uint32 public immutable depositWorkLimit;
    uint32 public immutable totalEpochs;

    event VaultRegistered(address indexed vault);

    constructor(uint32 depositWorkLimit_, uint32 totalEpochs_) {
        require(depositWorkLimit_ != 0 && depositWorkLimit_ < totalEpochs_, "limit");
        depositWorkLimit = depositWorkLimit_;
        totalEpochs = totalEpochs_;
    }

    function registerVault(address vault) external {
        require(msg.sender == administrator && vault != address(0), "administrator");
        administrator = address(0);
        emit VaultRegistered(vault);
    }

    function depositBudget(uint32 remainingEpochs) external view returns (uint32) {
        return remainingEpochs == totalEpochs ? depositWorkLimit : 0;
    }

    function entryFeeBps(uint32 epoch) external pure returns (uint256) {
        return 7 + uint256(epoch * 13 % 29);
    }
}
