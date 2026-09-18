// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IERC20Fixture {
    function balanceOf(address) external view returns (uint256);
    function transfer(address,uint256) external returns (bool);
    function transferFrom(address,address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
}

interface IV2Callback { function pancakeCall(address,uint256,uint256,bytes calldata) external; }
interface IMoolahCallback { function onMoolahFlashLoan(uint256,bytes calldata) external; }

contract FixtureToken {
    string public name; string public symbol; uint8 public immutable decimals;
    uint256 public totalSupply; address public administrator = msg.sender;
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 value);
    event Approval(address indexed owner,address indexed spender,uint256 value);
    constructor(string memory n,string memory s,uint8 d){name=n;symbol=s;decimals=d;}
    function approve(address s,uint256 v) external returns(bool){allowance[msg.sender][s]=v;emit Approval(msg.sender,s,v);return true;}
    function transfer(address to,uint256 v) external returns(bool){_move(msg.sender,to,v);return true;}
    function transferFrom(address from,address to,uint256 v) external returns(bool){uint256 a=allowance[from][msg.sender];if(a!=type(uint256).max)allowance[from][msg.sender]=a-v;_move(from,to,v);return true;}
    function mint(address to,uint256 v) external {require(msg.sender==administrator);totalSupply+=v;balanceOf[to]+=v;emit Transfer(address(0),to,v);}
    function finishMinting() external {require(msg.sender==administrator);administrator=address(0);}
    function _move(address from,address to,uint256 v) internal {require(to!=address(0));balanceOf[from]-=v;balanceOf[to]+=v;emit Transfer(from,to,v);}
}

contract FixturePair {
    string public constant name="Pancake LPs"; string public constant symbol="Cake-LP"; uint8 public constant decimals=18;
    address public immutable token0; address public immutable token1; address public immutable factory;
    uint112 private reserve0; uint112 private reserve1; uint32 private timestampLast; uint256 private unlocked=1;
    uint256 public totalSupply; mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 value); event Sync(uint112 reserve0,uint112 reserve1);
    event Swap(address indexed sender,uint256 amount0In,uint256 amount1In,uint256 amount0Out,uint256 amount1Out,address indexed to);
    modifier lock(){require(unlocked==1,"Pancake: LOCKED");unlocked=0;_;unlocked=1;}
    constructor(address a,address b){factory=msg.sender;token0=a;token1=b;}
    function approve(address s,uint256 v) external returns(bool){allowance[msg.sender][s]=v;return true;}
    function transfer(address to,uint256 v) external returns(bool){balanceOf[msg.sender]-=v;balanceOf[to]+=v;emit Transfer(msg.sender,to,v);return true;}
    function transferFrom(address from,address to,uint256 v) external returns(bool){uint256 a=allowance[from][msg.sender];if(a!=type(uint256).max)allowance[from][msg.sender]=a-v;balanceOf[from]-=v;balanceOf[to]+=v;emit Transfer(from,to,v);return true;}
    function getReserves() external view returns(uint112,uint112,uint32){return(reserve0,reserve1,timestampLast);}
    function mint(address to) external lock returns(uint256 liquidity){uint256 b0=IERC20Fixture(token0).balanceOf(address(this));uint256 b1=IERC20Fixture(token1).balanceOf(address(this));uint256 a0=b0-reserve0;uint256 a1=b1-reserve1;liquidity=totalSupply==0?_sqrt(a0*a1):_min(a0*totalSupply/reserve0,a1*totalSupply/reserve1);require(liquidity>1000,"Pancake: LIQUIDITY");if(totalSupply==0){totalSupply=1000;balanceOf[address(0xdead)]=1000;emit Transfer(address(0),address(0xdead),1000);}totalSupply+=liquidity;balanceOf[to]+=liquidity;emit Transfer(address(0),to,liquidity);_update(b0,b1);}
    function sync() external lock{_update(IERC20Fixture(token0).balanceOf(address(this)),IERC20Fixture(token1).balanceOf(address(this)));}
    function skim(address to) external lock{IERC20Fixture(token0).transfer(to,IERC20Fixture(token0).balanceOf(address(this))-reserve0);IERC20Fixture(token1).transfer(to,IERC20Fixture(token1).balanceOf(address(this))-reserve1);}
    function swap(uint256 o0,uint256 o1,address to,bytes calldata data) external lock{require(o0!=0||o1!=0,"Pancake: OUTPUT");require(o0<reserve0&&o1<reserve1,"Pancake: LIQUIDITY");if(o0!=0)IERC20Fixture(token0).transfer(to,o0);if(o1!=0)IERC20Fixture(token1).transfer(to,o1);if(data.length!=0)IV2Callback(to).pancakeCall(msg.sender,o0,o1,data);uint256 b0=IERC20Fixture(token0).balanceOf(address(this));uint256 b1=IERC20Fixture(token1).balanceOf(address(this));uint256 i0=b0>uint256(reserve0)-o0?b0-(uint256(reserve0)-o0):0;uint256 i1=b1>uint256(reserve1)-o1?b1-(uint256(reserve1)-o1):0;require(i0!=0||i1!=0,"Pancake: INPUT");uint256 a0=b0*10000-i0*25;uint256 a1=b1*10000-i1*25;require(a0*a1>=uint256(reserve0)*reserve1*10000**2,"Pancake: K");_update(b0,b1);emit Swap(msg.sender,i0,i1,o0,o1,to);}
    function _update(uint256 b0,uint256 b1) private {require(b0<=type(uint112).max&&b1<=type(uint112).max);reserve0=uint112(b0);reserve1=uint112(b1);timestampLast=uint32(block.timestamp);emit Sync(reserve0,reserve1);}
    function _min(uint256 a,uint256 b) private pure returns(uint256){return a<b?a:b;}
    function _sqrt(uint256 y) private pure returns(uint256 z){if(y>3){z=y;uint256 x=y/2+1;while(x<z){z=x;x=(y/x+x)/2;}}else if(y!=0)z=1;}
}

contract FixtureFactory {
    mapping(address=>mapping(address=>address)) public getPair; address[] public allPairs;
    function createPair(address a,address b) external returns(address pair){require(a!=b&&getPair[a][b]==address(0));pair=address(new FixturePair(a,b));getPair[a][b]=pair;getPair[b][a]=pair;allPairs.push(pair);}
    function allPairsLength() external view returns(uint256){return allPairs.length;}
}

contract FixtureRouter {
    address public immutable factory; address public immutable WETH;
    constructor(address f,address w){factory=f;WETH=w;}
    function getAmountsOut(uint256 amount,address[] memory path) public view returns(uint256[] memory amounts){require(path.length==2);amounts=new uint256[](2);amounts[0]=amount;(uint112 r0,uint112 r1,)=FixturePair(FixtureFactory(factory).getPair(path[0],path[1])).getReserves();(uint256 ri,uint256 ro)=path[0]==FixturePair(FixtureFactory(factory).getPair(path[0],path[1])).token0()?(r0,r1):(r1,r0);amounts[1]=_out(amount,ri,ro);}
    function getAmountsIn(uint256 output,address[] memory path) external view returns(uint256[] memory amounts){require(path.length==2);address p=FixtureFactory(factory).getPair(path[0],path[1]);(uint112 r0,uint112 r1,)=FixturePair(p).getReserves();(uint256 ri,uint256 ro)=path[0]==FixturePair(p).token0()?(r0,r1):(r1,r0);amounts=new uint256[](2);amounts[0]=ri*output*10000/((ro-output)*9975)+1;amounts[1]=output;}
    function swapExactTokensForTokens(uint256 amount,uint256 min,address[] calldata path,address to,uint256 deadline) external returns(uint256[] memory amounts){require(deadline>=block.timestamp);address p=FixtureFactory(factory).getPair(path[0],path[1]);IERC20Fixture(path[0]).transferFrom(msg.sender,p,amount);amounts=getAmountsOut(amount,path);require(amounts[1]>=min);if(path[0]==FixturePair(p).token0())FixturePair(p).swap(0,amounts[1],to,"");else FixturePair(p).swap(amounts[1],0,to,"");}
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amount,uint256 min,address[] calldata path,address to,uint256 deadline) external {require(deadline>=block.timestamp);address p=FixtureFactory(factory).getPair(path[0],path[1]);(uint112 r0,uint112 r1,)=FixturePair(p).getReserves();uint256 beforeBalance=IERC20Fixture(path[0]).balanceOf(p);IERC20Fixture(path[0]).transferFrom(msg.sender,p,amount);uint256 received=IERC20Fixture(path[0]).balanceOf(p)-beforeBalance;(uint256 ri,uint256 ro)=path[0]==FixturePair(p).token0()?(r0,r1):(r1,r0);uint256 output=_out(received,ri,ro);require(output>=min);if(path[0]==FixturePair(p).token0())FixturePair(p).swap(0,output,to,"");else FixturePair(p).swap(output,0,to,"");}
    function addLiquidity(address a,address b,uint256 ad,uint256 bd,uint256,uint256,address to,uint256 deadline) external returns(uint256 aa,uint256 bb,uint256 liq){require(deadline>=block.timestamp);address p=FixtureFactory(factory).getPair(a,b);if(p==address(0))p=FixtureFactory(factory).createPair(a,b);IERC20Fixture(a).transferFrom(msg.sender,p,ad);IERC20Fixture(b).transferFrom(msg.sender,p,bd);liq=FixturePair(p).mint(to);return(ad,bd,liq);}
    function swapTokensForExactETH(uint256,uint256,address[] calldata,address,uint256) external pure returns(uint256[] memory){revert("unused");}
    function _out(uint256 a,uint256 ri,uint256 ro) private pure returns(uint256){uint256 f=a*9975;return f*ro/(ri*10000+f);}
}

contract FixtureV3Router {
    address public immutable wrapped; address public immutable stable;
    constructor(address w,address s){wrapped=w;stable=s;}
    receive() external payable {}
    function exactInputSingle(bytes calldata) external payable returns(uint256){revert("fixture route closed");}
}

contract FixtureFundPool {
    address public stable; mapping(address=>uint256) public lpAmount; uint256 public funded;
    constructor(address s){stable=s;}
    function fundUSDT(uint256 amount) external {IERC20Fixture(stable).transferFrom(msg.sender,address(this),amount);funded+=amount;}
    function setUserAmount(address user,uint256 amount) external {lpAmount[user]=amount;}
    function initUserAmount(address user,uint256 amount) external {lpAmount[user]=amount;}
}

contract FixtureMoolah {
    IERC20Fixture public immutable stable;
    constructor(address s){stable=IERC20Fixture(s);}
    function flashLoan(address token,uint256 assets,bytes calldata data) external {require(token==address(stable));uint256 beforeBalance=stable.balanceOf(address(this));stable.transfer(msg.sender,assets);IMoolahCallback(msg.sender).onMoolahFlashLoan(assets,data);stable.transferFrom(msg.sender,address(this),assets);require(stable.balanceOf(address(this))>=beforeBalance,"repayment");}
}

contract LockedTreasury { receive() external payable {} }
