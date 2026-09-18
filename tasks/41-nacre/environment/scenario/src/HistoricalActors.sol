// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IHistoricalAsset {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IHistoricalVaultShare {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 amount) external returns (uint256 shares);
    function initWithdraw(uint256 shares) external returns (uint256 assets);
}

/// @notice Local equivalent of the historical nonzero owner/maker role. It is
/// used to perform the observed lifecycle calls, then irreversibly locked so
/// the public task does not expose a known Anvil administrator key.
contract HistoricalOwnerController {
    address private operator;

    constructor(address operator_) {
        operator = operator_;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "operator");
        _;
    }

    function deploy(bytes calldata creationCode) external onlyOperator returns (address deployed) {
        bytes memory code = creationCode;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0), "deployment");
    }

    function invoke(address target, bytes calldata callData) external onlyOperator returns (bytes memory result) {
        bool success;
        (success, result) = target.call(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function seal() external onlyOperator {
        operator = address(0);
    }
}

/// @notice Reconstructs the observable behavior of the unverified historical
/// user wrapper: pull collateral, deposit it, then send every minted share to
/// the strategy custodian.
contract HistoricalDepositWrapper {
    function deposit(address asset, address vault, address custodian, uint256 amount)
        external
        returns (uint256 shares)
    {
        require(IHistoricalAsset(asset).transferFrom(msg.sender, address(this), amount), "funding");
        require(IHistoricalAsset(asset).approve(vault, amount), "asset approval");
        shares = IHistoricalVaultShare(vault).deposit(amount);
        require(IHistoricalVaultShare(vault).approve(custodian, shares), "share approval");
        HistoricalShareCustodian(custodian).collect(vault, address(this), shares);
    }
}

/// @notice Reconstructs the share aggregation and final ordinary withdrawal
/// performed by the historical strategy contract. It has no task-only views or
/// registry of vaults.
contract HistoricalShareCustodian {
    address private immutable operator;

    constructor(address operator_) {
        operator = operator_;
    }

    function collect(address vault, address from, uint256 shares) external {
        require(IHistoricalVaultShare(vault).transferFrom(from, address(this), shares), "share transfer");
    }

    function withdrawAll(address vault) external returns (uint256 assets) {
        require(msg.sender == operator, "operator");
        assets = IHistoricalVaultShare(vault).initWithdraw(type(uint256).max);
    }
}
