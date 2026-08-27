// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/CinderProtocol.sol";
import "../src/CinderRisk.sol";
import "../src/CinderOracle.sol";
import "../src/LocalPrimitives.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 private constant MARKET_COUNT = 96;
    uint256 private constant SCARCE_MARKET_COUNT = 12;

    function _scarce(uint256 market) private pure returns (bool) {
        return market >= 5 && market <= 93 && (market - 5) % 8 == 0;
    }

    function _scarceSlot(uint256 market) private pure returns (uint256) {
        require(_scarce(market), "ordinary market");
        return (market - 5) / 8;
    }

    function run() external {
        vm.startBroadcast(KEY);
        IndexedLendingPool pool = new IndexedLendingPool();
        LocalToken cash = new LocalToken("Cinder Settlement", "CASH", 18);
        CinderPriceBook priceBook = new CinderPriceBook();
        CreditPolicy policy = new CreditPolicy(address(priceBook));

        LocalToken[] memory underlyings = new LocalToken[](MARKET_COUNT);
        for (uint256 i; i < MARKET_COUNT; ++i) {
            underlyings[i] = new LocalToken(
                string.concat("Cinder Reserve Asset ", _decimal(i)), string.concat("CRA-", _decimal(i)), 18
            );
        }

        ReserveWrapper[] memory wrappers = new ReserveWrapper[](MARKET_COUNT);
        for (uint256 i; i < MARKET_COUNT; ++i) {
            wrappers[i] = new ReserveWrapper(address(underlyings[i]), string.concat("RSC-", _decimal(i)));
        }
        ReserveWrapper[12] memory scarceBaseWrappers;
        ReserveWrapper[12] memory scarceLayerOne;
        ReserveWrapper[12] memory scarceLayerTwo;
        ReserveWrapper[12] memory scarceLayerThree;
        uint256[12] memory scarceMarkets;
        for (uint256 j; j < SCARCE_MARKET_COUNT; ++j) {
            uint256 market = 5 + j * 8;
            scarceMarkets[j] = market;
            scarceBaseWrappers[j] = wrappers[market];
            scarceLayerOne[j] =
                new ReserveWrapper(address(scarceBaseWrappers[j]), string.concat("RSC-A-", _decimal(market)));
            scarceLayerTwo[j] =
                new ReserveWrapper(address(scarceLayerOne[j]), string.concat("RSC-B-", _decimal(market)));
            scarceLayerThree[j] =
                new ReserveWrapper(address(scarceLayerTwo[j]), string.concat("RSC-C-", _decimal(market)));
            wrappers[market] = scarceLayerThree[j];
        }
        FeeFlashBank lender = new FeeFlashBank(address(cash), 9);
        address[] memory reserveAssets = new address[](SCARCE_MARKET_COUNT);
        for (uint256 j; j < SCARCE_MARKET_COUNT; ++j) {
            reserveAssets[j] = address(underlyings[scarceMarkets[j]]);
        }
        MultiFlashBank reserveLender = new MultiFlashBank(reserveAssets, 10);
        CinderConversionPool[12] memory conversions;
        for (uint256 j; j < SCARCE_MARKET_COUNT; ++j) {
            conversions[j] = new CinderConversionPool(address(cash), reserveAssets[j]);
        }

        for (uint256 i; i < MARKET_COUNT; ++i) {
            uint256 wrapperLiquidity = _scarce(i) ? 40 ether : (900_000 + i * 10_000) * 1 ether;
            underlyings[i].mint(DEPLOYER, wrapperLiquidity + (_scarce(i) ? 1_000 ether : 0));
            if (_scarce(i)) {
                uint256 j = _scarceSlot(i);
                underlyings[i].approve(address(scarceBaseWrappers[j]), type(uint256).max);
                scarceBaseWrappers[j].bootstrap(40 ether, 40 ether, DEPLOYER);
                scarceBaseWrappers[j].approve(address(scarceLayerOne[j]), type(uint256).max);
                scarceLayerOne[j].bootstrap(40 ether, 40 ether, DEPLOYER);
                scarceLayerOne[j].approve(address(scarceLayerTwo[j]), type(uint256).max);
                scarceLayerTwo[j].bootstrap(40 ether, 40 ether, DEPLOYER);
                scarceLayerTwo[j].approve(address(scarceLayerThree[j]), type(uint256).max);
                scarceLayerThree[j].bootstrap(20 ether, 20 ether, DEPLOYER);
                scarceLayerThree[j].mint(20 ether, address(pool));
            } else {
                underlyings[i].approve(address(wrappers[i]), type(uint256).max);
                wrappers[i].bootstrap(wrapperLiquidity, wrapperLiquidity, address(pool));
            }
            uint256 price = _scarce(i) ? (8_000 + _scarceSlot(i) * 1_000) * 1 ether : (8_000 + i * 1_700) * 1 ether;
            priceBook.set(address(underlyings[i]), price);
            if (!_scarce(i)) priceBook.setWrapper(address(wrappers[i]), address(underlyings[i]));
        }
        for (uint256 j; j < SCARCE_MARKET_COUNT; ++j) {
            priceBook.setWrapper(address(scarceBaseWrappers[j]), reserveAssets[j]);
            priceBook.setWrapper(address(scarceLayerOne[j]), address(scarceBaseWrappers[j]));
            priceBook.setWrapper(address(scarceLayerTwo[j]), address(scarceLayerOne[j]));
            priceBook.setWrapper(address(scarceLayerThree[j]), address(scarceLayerTwo[j]));
        }

        policy.bind(address(pool));
        for (uint256 i; i < MARKET_COUNT; ++i) {
            uint256 factorValue = _scarce(i) ? 9_000 : 2_500 + (i % 7) * 800;
            uint256 liquidationValue = factorValue + (10_000 - factorValue) / 2;
            uint256 exposureValue = _scarce(i) ? uint256(2_300_000 ether) : uint256(100_000 ether);
            policy.list(
                address(wrappers[i]),
                uint16(factorValue),
                uint16(liquidationValue),
                uint16(_scarce(i) ? 2 : 2),
                uint128(exposureValue),
                _scarce(i)
            );
        }
        pool.configure(address(cash), address(policy));
        for (uint256 i; i < MARKET_COUNT; ++i) {
            pool.listMarket(address(wrappers[i]));
        }
        pool.finishConfiguration();
        policy.finishConfiguration();
        priceBook.finishConfiguration();

        cash.mint(address(pool), 30_000_000 ether);
        cash.mint(address(lender), 12_000_000 ether);
        cash.mint(DEPLOYER, 200_000_000 ether);
        for (uint256 j; j < SCARCE_MARKET_COUNT; ++j) {
            LocalToken reserveAsset = underlyings[scarceMarkets[j]];
            reserveAsset.mint(address(reserveLender), 100 ether);
            cash.approve(address(conversions[j]), type(uint256).max);
            reserveAsset.approve(address(conversions[j]), type(uint256).max);
            // Match the conversion venue's spot price to the configured oracle.
            // Ordinary purchases of wrapper collateral are therefore not an
            // economic shortcut around the donation-sensitive share accounting.
            uint256 marketPrice = (8_000 + j * 1_000) * 1 ether;
            conversions[j].seed(marketPrice * 1_000, 1_000 ether);
        }
        cash.renounceAdministration();
        for (uint256 i; i < MARKET_COUNT; ++i) {
            underlyings[i].renounceAdministration();
        }
        vm.stopBroadcast();
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        bytes memory out = new bytes(2);
        out[0] = bytes1(uint8(48 + value / 10));
        out[1] = bytes1(uint8(48 + value % 10));
        return string(out);
    }
}
