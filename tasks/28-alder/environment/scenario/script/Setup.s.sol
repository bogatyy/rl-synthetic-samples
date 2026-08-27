// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/AlderVenues.sol";
import "../src/AlderProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        vm.startBroadcast(KEY);
        AlderBasketIssuance issuance = new AlderBasketIssuance();
        LocalToken cash = new LocalToken("Alder Settlement Cash", "CASH", 18);
        FeeFlashBank bank = new FeeFlashBank(address(cash), 10);
        address[] memory components = new address[](8);
        uint8[] memory decimals = new uint8[](8);
        uint8[8] memory componentDecimals = [uint8(6), 8, 18, 12, 6, 18, 8, 15];
        for (uint256 i; i < 8; ++i) {
            LocalToken token = new LocalToken("Alder Basket Component", "ACOMP", componentDecimals[i]);
            components[i] = address(token);
            decimals[i] = componentDecimals[i];
        }
        AlderComponentRegistry registry = new AlderComponentRegistry(components, decimals);
        AlderBasketReserve reserve = new AlderBasketReserve(address(registry));
        AlderVenueFactory factory = new AlderVenueFactory();
        AlderComponentShop shop = new AlderComponentShop(address(cash), address(registry));

        cash.mint(address(shop), 1_000_000 ether);
        cash.mint(address(bank), 25_000 ether);
        for (uint256 i; i < 8; ++i) {
            LocalToken token = LocalToken(components[i]);
            uint256 unit = 10 ** decimals[i];
            token.mint(address(reserve), 100_000 * unit);
            token.mint(address(shop), 100 * unit);
            token.renounceAdministration();
        }
        reserve.bind(address(issuance));
        issuance.configure(
            address(cash),
            address(shop),
            address(reserve),
            address(bank),
            address(registry),
            address(factory),
            address(shop)
        );
        cash.renounceAdministration();
        vm.stopBroadcast();
    }
}
