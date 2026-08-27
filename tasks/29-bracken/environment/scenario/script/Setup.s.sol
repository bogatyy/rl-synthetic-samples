// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/BrackenStrategies.sol";
import "../src/BrackenProtocol.sol";
import "../src/BrackenPolicy.sol";

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
        BrackenPortfolioVault vault = new BrackenPortfolioVault();
        LocalToken cash = new LocalToken("Bracken Settlement Cash", "CASH", 18);
        LocalToken bond = new LocalToken("Bracken Strategy Bond", "BBOND", 6);
        address[] memory loanAssets = new address[](2);
        loanAssets[0] = address(cash);
        loanAssets[1] = address(bond);
        MultiFlashBank bank = new MultiFlashBank(loanAssets, 5);
        BrackenCashStrategy cashStrategy = new BrackenCashStrategy(address(cash));
        BrackenBondStrategy bondStrategy = new BrackenBondStrategy(address(cash), address(bond));
        BrackenQueuedStrategy queuedStrategy = new BrackenQueuedStrategy(address(cash));
        address[] memory strategies = new address[](3);
        strategies[0] = address(cashStrategy);
        strategies[1] = address(bondStrategy);
        strategies[2] = address(queuedStrategy);
        BrackenAccountant accountant = new BrackenAccountant(strategies);
        BrackenFixedDesk desk = new BrackenFixedDesk(address(cash), address(bond));
        (uint256 liquidity, uint256 duration, uint256 loss, uint256 correlation) = _withdrawalPlan();
        BrackenWithdrawalPolicy policy = new BrackenWithdrawalPolicy(
            address(bond), address(bondStrategy), 32, liquidity, duration, loss, correlation
        );

        address[] memory queue = new address[](3);
        queue[0] = address(cashStrategy);
        queue[1] = address(queuedStrategy);
        queue[2] = address(bondStrategy);
        vault.configure(
            address(cash),
            address(bond),
            address(bank),
            address(accountant),
            address(bondStrategy),
            address(desk),
            address(policy),
            queue
        );
        cashStrategy.bind(address(vault));
        bondStrategy.bind(address(vault));
        queuedStrategy.bind(address(vault));
        cash.mint(DEPLOYER, 3_000_000 ether);
        cash.approve(address(vault), type(uint256).max);
        vault.bootstrap(3_000_000 ether, 1_000_000 ether, 500_000 ether, DEPLOYER);
        cash.mint(address(bank), 1_600_000 ether);
        bond.mint(address(bank), 150_000e6);
        bond.mint(address(desk), 200_000e6);
        cash.renounceAdministration();
        bond.renounceAdministration();
        vm.stopBroadcast();
    }

    function _withdrawalPlan()
        private
        pure
        returns (uint256 liquidity, uint256 duration, uint256 loss, uint256 correlation)
    {
        uint16[32] memory selected = _selected();
        for (uint256 i; i < selected.length; ++i) {
            uint64 code = BrackenPlanData.code(selected[i]);
            liquidity += uint16(code);
            duration += uint16(code >> 16);
            loss += uint16(code >> 32);
            correlation += uint16(code >> 48);
        }
    }

    function _selected() private pure returns (uint16[32] memory indices) {
        indices = [
            uint16(4),
            17,
            31,
            46,
            63,
            79,
            96,
            112,
            129,
            145,
            162,
            178,
            195,
            211,
            228,
            244,
            261,
            277,
            294,
            310,
            327,
            343,
            360,
            376,
            393,
            409,
            426,
            442,
            459,
            475,
            492,
            508
        ];
    }
}
