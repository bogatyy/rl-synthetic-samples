// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/LanternMarket.sol";
import "../src/LanternProtocol.sol";

interface Vm {
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function run() external {
        vm.startBroadcast(KEY);
        LanternCreditGateway gateway = new LanternCreditGateway();
        LocalToken cash = new LocalToken("Lantern Settlement Cash", "CASH", 18);
        FeeFlashBank bank = new FeeFlashBank(address(cash), 10);
        LanternVenueFactory venues = new LanternVenueFactory();
        LanternMarketFactory markets = new LanternMarketFactory(address(venues));
        LanternMarketRegistry registry = new LanternMarketRegistry(address(markets));
        LanternPositionBook book = new LanternPositionBook();
        LanternLendingReserve reserve = new LanternLendingReserve(address(cash));

        book.bind(address(gateway));
        reserve.bind(address(gateway));
        for (uint160 i; i < 64; ++i) {
            uint128 debt = i == 47 ? uint128(1_500_000 ether) : uint128((10_000 + (i % 9) * 4_000) * 1 ether);
            book.seed(address(0xB100 + i * 37), debt, uint8(i % 4));
        }
        book.freeze();
        cash.mint(address(reserve), 3_000_000 ether);
        cash.mint(address(bank), 300_000 ether);
        gateway.configure(
            address(cash),
            address(reserve),
            address(bank),
            address(venues),
            address(markets),
            address(registry),
            address(book)
        );
        cash.renounceAdministration();
        vm.stopBroadcast();
    }
}
