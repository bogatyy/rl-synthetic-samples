// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PortfolioIndexVault} from "../src/index/PortfolioIndexVault.sol";
import {SettlementToken} from "../src/token/ProtocolERC20.sol";
import {ComponentVaultFactory} from "../src/vault/ComponentVault.sol";
import {PoolAddressesProvider, AaveStylePool, ReserveAToken} from "../src/lending/AaveStylePool.sol";
import {PortfolioParticipant, GovernanceTimelock} from "../src/setup/PortfolioParticipant.sol";

interface Vm { function startBroadcast(uint256) external; function stopBroadcast() external; }

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        vm.startBroadcast(KEY);

        PortfolioIndexVault index = new PortfolioIndexVault();
        SettlementToken usdc = new SettlementToken();
        ComponentVaultFactory factory = new ComponentVaultFactory(address(usdc));

        address[5] memory components;
        components[0] = factory.createVault("TN-BTCUSD-PUT", keccak256("BTC-USD-PUT-WEEKLY"));
        components[1] = factory.createVault("TN-ETHUSD-PUT", keccak256("ETH-USD-PUT-WEEKLY"));
        components[2] = factory.createVault("TN-AVAXUSD-PUT", keccak256("AVAX-USD-PUT-WEEKLY"));
        components[3] = factory.createVault("TN-BNBUSD-PUT", keccak256("BNB-USD-PUT-WEEKLY"));
        components[4] = factory.createVault("TN-MATICUSD-PUT", keccak256("MATIC-USD-PUT-WEEKLY"));

        PoolAddressesProvider provider = new PoolAddressesProvider();
        AaveStylePool pool = new AaveStylePool(address(provider));
        ReserveAToken aToken = new ReserveAToken(address(pool), address(index), DEPLOYER);
        provider.setAddress(keccak256("POOL"), address(pool));
        pool.initReserve(address(index), address(aToken));

        address[] memory basket = new address[](5);
        uint16[] memory weights = new uint16[](5);
        for (uint256 i; i < 5; ++i) { basket[i] = components[i]; weights[i] = 2_000; }
        index.initialize(basket, weights, keccak256("TN-INDEX-USDC-PUT-LEGACY"), DEPLOYER);

        usdc.mint(DEPLOYER, 500_000e6);
        for (uint256 i; i < 48; ++i) {
            uint256 shares = i == 47 ? 30_000 ether : 10_000 ether;
            PortfolioParticipant participant = new PortfolioParticipant(
                address(usdc), address(index), address(pool), components,
                keccak256(abi.encode("legacy-index-participant", i))
            );
            usdc.transfer(address(participant), shares / 1e12);
            participant.enter(shares);
        }

        require(index.balanceOf(address(aToken)) == 500_000 ether, "reserve seeding");
        GovernanceTimelock timelock = new GovernanceTimelock(
            address(index), 2 days, keccak256(abi.encode(address(factory), address(provider), basket))
        );
        index.commitRebalance(keccak256(abi.encode("legacy-allocation", block.number)));
        index.transferGovernance(address(timelock));
        provider.transferOwnership(address(timelock));
        usdc.renounceAdministration();

        vm.stopBroadcast();
    }
}
