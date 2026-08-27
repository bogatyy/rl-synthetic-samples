// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract VerdantSaleRouter {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public inventoryToken;
    address public protectedReserve;
    address public liquidityBank;
    address public batchPolicy;
    address public sellerFactory;
    address public inventoryPool;

    event SaleConfigured(
        address indexed dealer, address indexed policy, address indexed factory, address inventoryPool
    );

    function configure(
        address cash,
        address token,
        address dealer,
        address bank,
        address policy,
        address factory,
        address pool
    ) external {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        inventoryToken = token;
        protectedReserve = dealer;
        liquidityBank = bank;
        batchPolicy = policy;
        sellerFactory = factory;
        inventoryPool = pool;
        emit SaleConfigured(dealer, policy, factory, pool);
        administrator = address(0);
    }
}
