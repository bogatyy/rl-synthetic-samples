// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./YarrowCustody.sol";

struct YarrowOrder {
    address asset;
    address beneficiary;
    uint128 amount;
    uint128 minimumReceipt;
    uint64 validUntil;
    bytes32 salt;
}

library YarrowOrderLib {
    function digest(address account, YarrowOrder memory order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                account,
                order.asset,
                order.beneficiary,
                order.amount,
                order.minimumReceipt,
                order.validUntil,
                order.salt
            )
        );
    }
}

contract YarrowQuoteVenue is IYarrowVenue {
    YarrowSessionLedger public immutable sessions;

    constructor(address sessions_) {
        sessions = YarrowSessionLedger(sessions_);
    }

    function venueClass() external pure returns (uint8) {
        return 1;
    }

    function execute(address account, bytes32 commandId, bytes calldata data) external returns (bytes32 digest) {
        YarrowOrder memory order = abi.decode(data, (YarrowOrder));
        require(
            order.asset != address(0) && order.beneficiary != address(0) && order.amount != 0
                && order.amount >= order.minimumReceipt && block.number <= order.validUntil,
            "quote"
        );
        digest = YarrowOrderLib.digest(account, order);
        sessions.advance(commandId, 0, 1, digest);
    }
}

contract YarrowSettlementVenue is IYarrowVenue {
    YarrowSessionLedger public immutable sessions;
    YarrowTokenAdapter public immutable adapter;
    address public immutable settlementAsset;

    constructor(address sessions_, address adapter_, address asset_) {
        sessions = YarrowSessionLedger(sessions_);
        adapter = YarrowTokenAdapter(adapter_);
        settlementAsset = asset_;
    }

    function venueClass() external pure returns (uint8) {
        return 2;
    }

    function execute(address account, bytes32 commandId, bytes calldata data) external returns (bytes32 digest) {
        YarrowOrder memory order = abi.decode(data, (YarrowOrder));
        require(order.asset == settlementAsset && order.amount >= order.minimumReceipt, "settlement");
        digest = YarrowOrderLib.digest(account, order);
        sessions.advance(commandId, 1, 2, digest);
        adapter.settle(account, order.asset, order.beneficiary, order.amount);
    }
}

contract YarrowFinalizeVenue is IYarrowVenue {
    YarrowSessionLedger public immutable sessions;

    constructor(address sessions_) {
        sessions = YarrowSessionLedger(sessions_);
    }

    function venueClass() external pure returns (uint8) {
        return 3;
    }

    function execute(address account, bytes32 commandId, bytes calldata data) external returns (bytes32 digest) {
        YarrowOrder memory order = abi.decode(data, (YarrowOrder));
        require(block.number <= order.validUntil, "expired");
        digest = YarrowOrderLib.digest(account, order);
        sessions.advance(commandId, 2, 3, digest);
    }
}

contract YarrowAccountingVenue is IYarrowVenue {
    uint8 public immutable configuredClass;
    bytes32 public immutable lane;

    constructor(uint8 class_, bytes32 lane_) {
        require(class_ >= 1 && class_ <= 4, "class");
        configuredClass = class_;
        lane = lane_;
    }

    function venueClass() external view returns (uint8) {
        return configuredClass;
    }

    function execute(address, bytes32, bytes calldata) external pure returns (bytes32) {
        revert("accounting only");
    }
}
