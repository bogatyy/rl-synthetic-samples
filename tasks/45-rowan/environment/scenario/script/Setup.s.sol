// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {XDK} from "../src/production/contracts/XDK.sol";
import {FixtureToken,FixtureFactory,FixtureRouter,FixturePair} from "../src/FixtureDex.sol";

interface Vm { function startBroadcast(uint256 key) external; function stopBroadcast() external; }

contract Setup {
    Vm private constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address private constant DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address private constant DEAD=0x000000000000000000000000000000000000dEaD;

    function run() external {
        vm.startBroadcast(KEY);
        FixtureToken gpc=new FixtureToken("GPC","GPC",18);
        FixtureToken wrapped=new FixtureToken("Wrapped BNB","WBNB",18);
        FixtureToken usdc=new FixtureToken("USD Coin","USDC",18);
        FixtureToken usdt=new FixtureToken("Tether USD","USDT",18);
        FixtureFactory factory=new FixtureFactory();
        FixtureRouter router=new FixtureRouter(address(factory),address(wrapped));
        XDK token=new XDK("XDK","XDK",100_000_000,12_000_000,DEPLOYER);
        FixturePair flashPair=new FixturePair(address(wrapped),address(gpc));

        gpc.mint(DEPLOYER,25_000_000 ether);
        wrapped.mint(DEPLOYER,500_000 ether);
        usdc.mint(DEPLOYER,8_000_000 ether);
        usdt.mint(DEPLOYER,11_000_000 ether);
        gpc.approve(address(router),type(uint256).max);
        token.approve(address(router),type(uint256).max);

        router.addLiquidity(address(token),address(gpc),3_000_000 ether,600_000 ether,0,0,DEPLOYER,type(uint256).max);
        address mainPair=token.uniswapV2Pair();
        FixturePair lp=FixturePair(mainPair);
        uint256 minted=lp.balanceOf(DEPLOYER);
        lp.transfer(DEAD,minted*70/100);
        uint256 slice=minted*30/100/48;
        for(uint256 i;i<48;++i){
            lp.transfer(address(uint160(uint256(keccak256(abi.encode("xdk-liquidity-provider",i))))),slice);
        }
        lp.transfer(DEAD,lp.balanceOf(DEPLOYER));

        gpc.transfer(address(flashPair),2_000_000 ether);
        wrapped.transfer(address(flashPair),30_000 ether);
        flashPair.mint(DEAD);

        address wbnbPair=factory.getPair(address(token),address(wrapped));
        token.transfer(wbnbPair,120_000 ether); wrapped.transfer(wbnbPair,900 ether); FixturePair(wbnbPair).mint(DEAD);
        address usdcPair=factory.getPair(address(token),address(usdc));
        token.transfer(usdcPair,90_000 ether); usdc.transfer(usdcPair,22_000 ether); FixturePair(usdcPair).mint(DEAD);
        address usdtPair=factory.getPair(address(token),address(usdt));
        token.transfer(usdtPair,75_000 ether); usdt.transfer(usdtPair,19_000 ether); FixturePair(usdtPair).mint(DEAD);

        token.launch();
        token.renounceOwnership();
        gpc.finishMinting(); wrapped.finishMinting(); usdc.finishMinting(); usdt.finishMinting();
        vm.stopBroadcast();
    }
}
