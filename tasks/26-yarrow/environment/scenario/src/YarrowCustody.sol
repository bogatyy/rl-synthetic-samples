// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";

interface IYarrowVenue {
    function venueClass() external view returns (uint8);
    function execute(address account, bytes32 commandId, bytes calldata data) external returns (bytes32 digest);
}

interface IYarrowActionModule {
    function execute(address account, bytes32 commandId, bytes calldata payload) external;
}

contract YarrowVenueRegistry {
    address public administrator = msg.sender;
    address public module;
    bool public frozen;
    address[] private venues;
    mapping(address => bool) public approved;
    mapping(address => uint8) public classOf;

    event VenueApproved(address indexed venue, uint8 indexed venueClass);

    function configureModule(address module_) external {
        require(msg.sender == administrator && module == address(0), "configuration");
        module = module_;
    }

    function approveVenue(address venue) external {
        require(msg.sender == administrator && !frozen && venue.code.length != 0 && !approved[venue], "venue");
        uint8 class = IYarrowVenue(venue).venueClass();
        require(class >= 1 && class <= 4, "class");
        approved[venue] = true;
        classOf[venue] = class;
        venues.push(venue);
        emit VenueApproved(venue, class);
    }

    function finishConfiguration() external {
        require(msg.sender == administrator && module != address(0) && venues.length >= 5, "configuration");
        frozen = true;
        administrator = address(0);
    }

    function venueCount() external view returns (uint256) {
        return venues.length;
    }

    function venueAt(uint256 index) external view returns (address) {
        return venues[index];
    }
}

contract YarrowSessionLedger {
    struct Session {
        bytes32 digest;
        uint8 phase;
        uint64 openedAt;
    }

    YarrowVenueRegistry public immutable registry;
    mapping(bytes32 => Session) public sessions;

    constructor(address registry_) {
        registry = YarrowVenueRegistry(registry_);
    }

    function advance(bytes32 commandId, uint8 expected, uint8 next, bytes32 digest) external {
        require(registry.approved(msg.sender), "venue");
        Session storage session = sessions[commandId];
        require(session.phase == expected && next == expected + 1, "phase");
        if (expected == 0) {
            require(digest != bytes32(0), "digest");
            session.digest = digest;
            session.openedAt = uint64(block.number);
        } else {
            require(session.digest == digest && block.number <= session.openedAt + 2, "session");
        }
        session.phase = next;
    }
}

contract YarrowCustodyAccount {
    address public immutable accountRouter;
    address public immutable adapter;
    address public immutable settlementAsset;

    constructor(address accountRouter_, address adapter_, address asset_) {
        accountRouter = accountRouter_;
        adapter = adapter_;
        settlementAsset = asset_;
    }

    function release(address asset, address receiver, uint256 amount) external {
        require(msg.sender == adapter && asset == settlementAsset && receiver != address(0), "adapter");
        require(IERC20Like(asset).transfer(receiver, amount), "transfer");
    }
}

contract YarrowTokenAdapter {
    YarrowVenueRegistry public immutable registry;
    address public immutable receipt;

    constructor(address registry_, address receipt_) {
        registry = YarrowVenueRegistry(registry_);
        receipt = receipt_;
    }

    function settle(address account, address asset, address receiver, uint256 amount) external {
        require(registry.approved(msg.sender) && registry.classOf(msg.sender) == 2, "settlement venue");
        YarrowCustodyAccount(account).release(asset, receiver, amount);
        LocalToken(receipt).mint(account, amount);
    }
}

contract YarrowAccountRouter {
    address public administrator = msg.sender;
    address public bridgeRouter;
    address public actionModule;
    mapping(bytes32 => address) public accountOf;

    function configure(address bridge, address module, bytes32 accountId, address account) external {
        require(msg.sender == administrator && bridgeRouter == address(0), "configuration");
        require(bridge != address(0) && module != address(0) && account != address(0), "addresses");
        bridgeRouter = bridge;
        actionModule = module;
        accountOf[accountId] = account;
        administrator = address(0);
    }

    function dispatch(bytes32 accountId, bytes32 commandId, bytes calldata payload) external {
        require(msg.sender == bridgeRouter && accountOf[accountId] != address(0), "bridge");
        IYarrowActionModule(actionModule).execute(accountOf[accountId], commandId, payload);
    }
}

contract YarrowActionModule {
    struct Action {
        uint8 expectedClass;
        address venue;
        bytes data;
    }

    address public immutable accountRouter;
    YarrowVenueRegistry public immutable registry;
    YarrowSessionLedger public immutable sessions;

    constructor(address accountRouter_, address registry_, address sessions_) {
        accountRouter = accountRouter_;
        registry = YarrowVenueRegistry(registry_);
        sessions = YarrowSessionLedger(sessions_);
    }

    function execute(address account, bytes32 commandId, bytes calldata payload) external {
        require(msg.sender == accountRouter, "account router");
        Action[] memory actions = abi.decode(payload, (Action[]));
        require(actions.length == 3, "action count");
        for (uint256 i; i < actions.length; ++i) {
            Action memory action = actions[i];
            require(
                registry.approved(action.venue) && registry.classOf(action.venue) == action.expectedClass
                    && action.expectedClass == i + 1,
                "route"
            );
            IYarrowVenue(action.venue).execute(account, commandId, action.data);
        }
        (bytes32 digest, uint8 phase,) = sessions.sessions(commandId);
        require(digest != bytes32(0) && phase == 3, "incomplete");
    }
}
