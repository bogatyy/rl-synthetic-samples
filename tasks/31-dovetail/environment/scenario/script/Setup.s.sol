// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/DovetailProduct.sol";
import "../src/DovetailModules.sol";
import "../src/DovetailProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        vm.startBroadcast(KEY);
        DovetailExchangePortal portal = new DovetailExchangePortal();
        LocalToken cash = new LocalToken("Dovetail Settlement Cash", "CASH", 18);
        LocalToken base = new LocalToken("Dovetail Base Component", "DBASE", 18);
        LocalToken bond = new LocalToken("Dovetail Bond Component", "DBOND", 18);
        address[] memory assets = new address[](3);
        assets[0] = address(cash);
        assets[1] = address(base);
        assets[2] = address(bond);
        MultiFlashBank bank = new MultiFlashBank(assets, 5);
        DovetailProductCreator creator = new DovetailProductCreator();
        DovetailBasicIssuance basic = new DovetailBasicIssuance();
        DovetailNavRedemption nav = new DovetailNavRedemption();
        DovetailBalanceValuer valuer = new DovetailBalanceValuer();

        valuer.setPrice(address(cash), 1 ether);
        valuer.setPrice(address(base), 1 ether);
        valuer.setPrice(address(bond), 1 ether);
        valuer.freeze();

        cash.mint(address(portal), 3_000_000 ether);
        base.mint(address(portal), 1_000_000 ether);
        bond.mint(address(portal), 1_500_000 ether);
        cash.mint(address(bank), 500_000 ether);
        base.mint(address(bank), 700_000 ether);
        bond.mint(address(bank), 1_000_000 ether);
        portal.configure(
            address(cash),
            address(base),
            address(bond),
            address(bank),
            address(creator),
            address(basic),
            address(nav),
            address(valuer)
        );
        cash.renounceAdministration();
        base.renounceAdministration();
        bond.renounceAdministration();
        vm.stopBroadcast();
    }
}
