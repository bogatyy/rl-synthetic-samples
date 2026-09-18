// SPDX-License-Identifier: MIT
pragma solidity =0.5.16;

import {MetaverseToken} from "../src/MetaverseToken.sol";
import {PancakeFactory, IPancakePair} from "../src/PancakeFactory.sol";
import {
    FixtureToken,
    FixtureDistribution,
    FixtureRouter,
    FixtureFlashLender,
    IFixtureToken,
    IFixturePair
} from "../src/FixtureContracts.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract Setup {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address private constant DISTRIBUTION = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address private constant RETIRED = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant TOKEN_RESERVE = 25_914_029_372_088_304_489_583;
    uint256 private constant STABLE_RESERVE = 37_009_240_317_278_254_683_142;

    function run() external {
        vm.startBroadcast(KEY);

        MetaverseToken marketToken = new MetaverseToken(DISTRIBUTION);
        FixtureDistribution distribution = new FixtureDistribution(address(marketToken));
        require(address(distribution) == DISTRIBUTION, "distribution address");
        FixtureToken stable = new FixtureToken("Tether USD", "USDT");
        PancakeFactory factory = new PancakeFactory(DEPLOYER);
        FixtureRouter router = new FixtureRouter(address(factory));
        FixtureFlashLender lender = new FixtureFlashLender(address(stable));

        address pair = factory.createPair(address(marketToken), address(stable));
        distribution.setWhite(pair, true);
        marketToken.sendTransfer(pair, 22_400 ether);
        distribution.sendAsset(address(marketToken), pair, TOKEN_RESERVE - 22_400 ether);
        stable.mint(pair, STABLE_RESERVE);
        IPancakePair(pair).mint(RETIRED);

        _configureHistoricalFees(marketToken, pair, distribution, router);
        stable.mint(address(lender), 189_727 ether);
        _seedMarkets(factory, stable);

        distribution.finish(RETIRED);
        marketToken.renounceMinter();
        stable.renounceAdministration();
        factory.setFeeToSetter(RETIRED);
        vm.stopBroadcast();
    }

    function _configureHistoricalFees(
        MetaverseToken marketToken,
        address pair,
        FixtureDistribution distribution,
        FixtureRouter router
    ) private {
        uint256[] memory fees0 = new uint256[](3);
        address[] memory recipients0 = new address[](3);
        fees0[0] = 1000;
        fees0[1] = 1200;
        fees0[2] = 2200;
        recipients0[0] = 0xa0f76967e9F36367c9045AdcfEe0F62D17B4F016;
        recipients0[1] = 0x869A387Fa1B10A7A3F6361B89e9D0946a40A4F1A;
        recipients0[2] = 0xf8E339c3bCF47417E5b1F8B76bf8d8a4034Ef493;
        marketToken.setContractorsFee(fees0, recipients0, 0);

        uint256[] memory fees1 = new uint256[](3);
        address[] memory recipients1 = new address[](3);
        fees1[0] = 36;
        fees1[1] = 10;
        fees1[2] = 54;
        recipients1[0] = 0xb173e47E94c2b16e98433B099F9e3A028410946a;
        recipients1[1] = 0x869A387Fa1B10A7A3F6361B89e9D0946a40A4F1A;
        recipients1[2] = 0xB56b5Cd919E2Ab61197EDd1Dbc222554a4c87e58;
        marketToken.setContractorsFee(fees1, recipients1, 1);

        uint256[] memory fees2 = new uint256[](1);
        address[] memory recipients2 = new address[](1);
        fees2[0] = 10_000;
        recipients2[0] = 0xb2a894a022e047BD850b471EC16aBD649b230126;
        marketToken.setContractorsFee(fees2, recipients2, 2);
        marketToken.setTransactFee(5);
        marketToken.setSaleDate(1_660_647_540);
        marketToken.setSell(address(router));
        distribution.setWhite(pair, false);
    }

    function _seedMarkets(PancakeFactory factory, FixtureToken stable) private {
        FixtureToken[] memory assets = new FixtureToken[](12);
        for (uint256 i; i < assets.length; ++i) {
            assets[i] = new FixtureToken("Market Asset", "MKT");
            assets[i].mint(DEPLOYER, 20_000_000 ether);
        }
        stable.mint(DEPLOYER, 300_000_000 ether);

        for (uint256 i; i < assets.length; ++i) {
            _createMarket(factory, address(assets[i]), address(stable), 700_000 ether + i * 31_000 ether, 1_100_000 ether + i * 47_000 ether);
        }
        for (uint256 i; i < assets.length; ++i) {
            uint256 j = (i + 5) % assets.length;
            if (address(assets[i]) < address(assets[j])) {
                _createMarket(factory, address(assets[i]), address(assets[j]), 420_000 ether + i * 19_000 ether, 510_000 ether + i * 23_000 ether);
            }
        }

        for (uint256 i; i < assets.length; ++i) assets[i].renounceAdministration();
    }

    function _createMarket(PancakeFactory factory, address tokenA, address tokenB, uint256 amountA, uint256 amountB) private {
        address pair = factory.createPair(tokenA, tokenB);
        require(IFixtureToken(tokenA).transfer(pair, amountA), "market A");
        require(IFixtureToken(tokenB).transfer(pair, amountB), "market B");
        IFixturePair(pair).mint(RETIRED);

        (uint112 reserve0, uint112 reserve1,) = IFixturePair(pair).getReserves();
        bool aIs0 = IFixturePair(pair).token0() == tokenA;
        uint256 reserveIn = aIs0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = aIs0 ? uint256(reserve1) : uint256(reserve0);
        uint256 amountIn = amountA / 137;
        require(IFixtureToken(tokenA).transfer(pair, amountIn), "season input");
        uint256 withFee = amountIn * 9975;
        uint256 amountOut = withFee * reserveOut / (reserveIn * 10000 + withFee);
        IFixturePair(pair).swap(aIs0 ? 0 : amountOut, aIs0 ? amountOut : 0, DEPLOYER, "");
    }
}
