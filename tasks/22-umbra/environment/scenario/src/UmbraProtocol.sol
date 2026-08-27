// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./LocalPrimitives.sol";
import "./UmbraRouting.sol";

contract UmbraAssetVault {
    address public immutable asset;
    address public router;
    uint256 public totalShares;
    uint256 public accountedAssets;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        asset = asset_;
    }

    function bind(address router_) external {
        require(router == address(0), "bound");
        router = router_;
    }

    function bootstrap(uint256 amount, address receiver) external {
        require(totalShares == 0, "bootstrapped");
        IERC20Like(asset).transferFrom(msg.sender, address(this), amount);
        totalShares = amount;
        accountedAssets = amount;
        balanceOf[receiver] = amount;
    }

    function credit(address receiver, uint256 reportedAssets) external returns (uint256 shares) {
        require(msg.sender == router && receiver != address(0), "router");
        shares = reportedAssets * totalShares / accountedAssets;
        totalShares += shares;
        accountedAssets += reportedAssets;
        balanceOf[receiver] += shares;
    }

    function redeem(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = shares * accountedAssets / totalShares;
        balanceOf[msg.sender] -= shares;
        totalShares -= shares;
        accountedAssets -= assets;
        IERC20Like(asset).transfer(receiver, assets);
    }
}

contract UmbraVaultRouter {
    address public administrator = msg.sender;
    address public settlementAsset;
    address public protectedReserve;
    address public liquidityBank;
    address public registry;
    address public adapterFactory;
    address public executor;

    function configure(address cash, address vault, address bank, address registry_, address factory, address executor_)
        external
    {
        require(msg.sender == administrator && settlementAsset == address(0), "configuration");
        settlementAsset = cash;
        protectedReserve = vault;
        liquidityBank = bank;
        registry = registry_;
        adapterFactory = factory;
        executor = executor_;
        administrator = address(0);
    }

    function deposit(address input, uint256 amount, UmbraRouteExecutor.Hop[] calldata route, address receiver)
        external
        returns (uint256 shares)
    {
        IERC20Like(input).transferFrom(msg.sender, executor, amount);
        (address output, uint256 reported) = UmbraRouteExecutor(executor).execute(input, amount, route, protectedReserve);
        require(output == settlementAsset && reported != 0, "settlement");
        shares = UmbraAssetVault(protectedReserve).credit(receiver, reported);
    }
}
