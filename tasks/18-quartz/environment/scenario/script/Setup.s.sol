// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/QuartzRange.sol";
import "../src/QuartzProtocol.sol";

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
        QuartzPositionLender lender = new QuartzPositionLender();
        LocalToken cash = new LocalToken("Quartz Settlement Cash", "CASH", 18);
        LocalToken quote = new LocalToken("Quartz Quote Asset", "QRT", 18);
        address[] memory assets = new address[](2);
        assets[0] = address(cash);
        assets[1] = address(quote);
        MultiFlashBank bank = new MultiFlashBank(assets, 5);
        QuartzRangeVenue venue = new QuartzRangeVenue(address(cash), address(quote));
        QuartzPositionEngine engine = new QuartzPositionEngine(address(cash), address(quote), address(venue));
        QuartzCollateralRegistry registry = new QuartzCollateralRegistry(address(engine));
        QuartzDebtBook book = new QuartzDebtBook();
        QuartzRestructurePolicy policy = new QuartzRestructurePolicy();

        lender.configure(
            address(cash),
            address(quote),
            address(bank),
            address(venue),
            address(engine),
            address(registry),
            address(book),
            address(policy)
        );
        registry.bind(address(lender));
        book.bind(address(lender));
        uint8[56] memory selected = [
            uint8(25),
            19,
            50,
            4,
            74,
            75,
            47,
            39,
            70,
            79,
            58,
            91,
            49,
            69,
            5,
            20,
            77,
            63,
            86,
            3,
            23,
            67,
            14,
            82,
            61,
            88,
            9,
            46,
            73,
            76,
            55,
            52,
            94,
            71,
            34,
            31,
            68,
            81,
            95,
            13,
            10,
            15,
            45,
            41,
            27,
            51,
            44,
            35,
            73,
            76,
            55,
            52,
            94,
            71,
            34,
            31
        ];
        uint256 targetAmount;
        uint256 targetCost;
        uint256 targetDuration;
        uint256 targetLoss;
        for (uint8 bucket; bucket < 4; ++bucket) {
            for (uint256 i; i < 96; ++i) {
                uint256 salt = uint256(bucket) * 104_729 + i * 7_919 + i * i * 3_571;
                uint128 relief = uint128((6_000 + (salt + 123) % 18_000) * 1 ether);
                uint128 cost = uint128((500 + (salt * 4_567 + 777) % 3_500) * 1 ether);
                uint32 maturity = i % 6 == 0 ? uint32(block.number + 1_000) : uint32(block.number);
                uint256 id = 100_000 + uint256(bucket) * 20_000 + i * 131;
                book.record(id, bucket, relief, cost, maturity);
                (uint16 duration, uint16 loss) = book.riskScores(id);
                for (uint256 j; j < 14; ++j) {
                    if (selected[uint256(bucket) * 14 + j] != i) continue;
                    targetAmount += relief;
                    targetCost += cost;
                    targetDuration += duration;
                    targetLoss += loss;
                    break;
                }
            }
        }
        book.freeze();
        policy.configure(address(lender), 56, targetAmount, targetCost, targetDuration, targetLoss);

        cash.mint(DEPLOYER, 2_000_000 ether);
        quote.mint(DEPLOYER, 2_000_000 ether);
        cash.approve(address(venue), type(uint256).max);
        quote.approve(address(venue), type(uint256).max);
        venue.seed(2_000_000 ether, 2_000_000 ether);
        cash.mint(address(lender), 3_000_000 ether);
        cash.mint(address(bank), 1_800_000 ether);
        quote.mint(address(bank), 1_200_000 ether);
        cash.renounceAdministration();
        quote.renounceAdministration();
        vm.stopBroadcast();
    }
}
