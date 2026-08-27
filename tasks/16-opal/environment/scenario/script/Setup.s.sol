// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/OpalLiquidity.sol";
import "../src/OpalProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        vm.startBroadcast(KEY);
        OpalStakingHub hub = new OpalStakingHub();
        LocalToken cash = new LocalToken("Opal Settlement Cash", "CASH", 18);
        LocalToken base = new LocalToken("Opal Base Asset", "OBASE", 18);
        address[] memory loanAssets = new address[](2);
        loanAssets[0] = address(cash);
        loanAssets[1] = address(base);
        MultiFlashBank bank = new MultiFlashBank(loanAssets, 5);
        OpalMarketFactory factory = new OpalMarketFactory();
        OpalMarketRegistry registry = new OpalMarketRegistry(address(factory), address(cash), address(base));
        OpalRewardSource cashRewards = new OpalRewardSource();
        OpalRewardSource baseRewards = new OpalRewardSource();
        OpalRewardAdapter cashAdapter = new OpalRewardAdapter(address(cash), 18);
        OpalRewardAdapter baseAdapter = new OpalRewardAdapter(address(base), 18);
        OpalMarketShare cashMarket = new OpalMarketShare(address(cash), address(cashAdapter), "OM-CASH");
        OpalMarketShare baseMarket = new OpalMarketShare(address(base), address(baseAdapter), "OM-BASE");

        factory.configureHarvester(address(hub));
        factory.adopt(address(cashMarket));
        factory.adopt(address(baseMarket));
        cashRewards.configure(address(cashAdapter), address(cashMarket));
        baseRewards.configure(address(baseAdapter), address(baseMarket));
        cashAdapter.configure(address(cashMarket), address(cashRewards));
        baseAdapter.configure(address(baseMarket), address(baseRewards));
        registry.register(address(cashMarket));
        registry.register(address(baseMarket));
        hub.configure(address(cash), address(base), address(bank), address(factory), address(registry));
        hub.activateMarket(address(cashMarket));
        hub.activateMarket(address(baseMarket));
        hub.setProtectedReserve(address(cashMarket));

        cash.mint(DEPLOYER, 8_000_000 ether);
        base.mint(DEPLOYER, 8_000_000 ether);
        cash.mint(address(bank), 1_500_000 ether);
        base.mint(address(bank), 1_500_000 ether);
        cash.approve(address(cashMarket), type(uint256).max);
        base.approve(address(baseMarket), type(uint256).max);
        cashMarket.addLiquidity(3_750_000 ether, DEPLOYER);
        baseMarket.addLiquidity(3_750_000 ether, DEPLOYER);

        cashMarket.approve(address(hub), type(uint256).max);
        baseMarket.approve(address(hub), type(uint256).max);
        hub.stake(address(cashMarket), 3_000_000 ether, DEPLOYER);
        hub.stake(address(baseMarket), 3_000_000 ether, DEPLOYER);
        cashMarket.transfer(address(cashRewards), 750_000 ether);
        baseMarket.transfer(address(baseRewards), 750_000 ether);

        factory.finishConfiguration();
        cash.renounceAdministration();
        base.renounceAdministration();
        vm.stopBroadcast();
    }
}
