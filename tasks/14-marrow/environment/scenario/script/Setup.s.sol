// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/MarrowMath.sol";
import "../src/MarrowProtocol.sol";

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
        MarrowRangeExchange exchange = new MarrowRangeExchange();
        LocalToken cash = new LocalToken("Marrow Settlement Cash", "CASH", 18);
        LocalToken base = new LocalToken("Marrow Range Base", "MBASE", 18);
        address[] memory assets = new address[](2);
        assets[0] = address(cash);
        assets[1] = address(base);
        MultiFlashBank bank = new MultiFlashBank(assets, 10);
        MarrowPositionManager manager = new MarrowPositionManager(address(exchange), address(cash), address(base));
        MarrowPositionValuer valuer = new MarrowPositionValuer(address(exchange), address(manager));
        MarrowCollateralRegistry registry = new MarrowCollateralRegistry(address(manager));
        MarrowPositionLender lender =
            new MarrowPositionLender(address(cash), address(manager), address(valuer), address(registry));

        exchange.configure(
            address(cash), address(base), address(bank), address(manager), address(valuer), address(lender)
        );
        registry.bind(address(lender));
        cash.mint(DEPLOYER, 3_000_000 ether);
        base.mint(DEPLOYER, 3_000_000 ether);
        cash.approve(address(exchange), type(uint256).max);
        base.approve(address(exchange), type(uint256).max);
        exchange.seed(1_860_000 ether, 2_200_000 ether);
        cash.mint(address(lender), 4_000_000 ether);
        cash.mint(address(bank), 2_000_000 ether);
        base.mint(address(bank), 1_300_000 ether);
        cash.renounceAdministration();
        base.renounceAdministration();
        vm.stopBroadcast();
    }
}
