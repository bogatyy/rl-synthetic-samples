// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../src/LocalPrimitives.sol";
import "../src/TalusRewards.sol";
import "../src/TalusProtocol.sol";

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
        TalusCampaignToken token = new TalusCampaignToken();
        LocalToken cash = new LocalToken("Talus Settlement Cash", "CASH", 18);
        TalusHashrateToken hashrate = new TalusHashrateToken();
        FeeFlashBank bank = new FeeFlashBank(address(cash), 10);
        LocalPair pair = new LocalPair(address(cash), address(token));
        LocalFlashBank stakeBank = new LocalFlashBank(address(pair));
        TalusMiningRewards rewards = new TalusMiningRewards(address(token), address(hashrate));
        TalusReferralBook referrals = new TalusReferralBook();
        TalusLiquidityCoordinator coordinator =
            new TalusLiquidityCoordinator(address(pair), address(rewards), address(stakeBank));

        cash.mint(address(pair), 2_000_000 ether);
        token.mint(address(pair), 2_000_000 ether);
        pair.mint(DEPLOYER);
        pair.transfer(address(stakeBank), 100_000 ether);
        cash.mint(address(bank), 600_000 ether);
        rewards.configure(address(pair), address(coordinator), address(referrals));
        hashrate.configure(address(rewards));
        token.setMinter(address(rewards), true);
        token.configure(
            address(cash),
            address(pair),
            address(bank),
            address(rewards),
            address(coordinator),
            address(referrals),
            address(hashrate)
        );
        cash.renounceAdministration();
        hashrate.renounceAdministration();
        token.renounceAdministration();
        vm.stopBroadcast();
    }
}
