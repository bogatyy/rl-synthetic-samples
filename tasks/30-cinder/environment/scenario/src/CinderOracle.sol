// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ICinderWrappedAsset {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract CinderPriceBook {
    address public administrator = msg.sender;
    mapping(address => uint256) public priceInCash;
    mapping(address => address) public wrappedAsset;
    mapping(address => uint64) public lastUpdate;
    address[] private assets;

    event PriceConfigured(address indexed asset, uint256 price, uint64 update);

    function set(address asset, uint256 price) external {
        require(msg.sender == administrator && asset != address(0), "administrator");
        require(price >= 1_000 ether && price <= 500_000 ether, "price range");
        if (priceInCash[asset] == 0) assets.push(asset);
        priceInCash[asset] = price;
        lastUpdate[asset] = uint64(block.number);
        emit PriceConfigured(asset, price, uint64(block.number));
    }

    function setWrapper(address wrapper, address underlying) external {
        require(msg.sender == administrator && wrapper != address(0) && underlying != address(0), "administrator");
        require(wrappedAsset[wrapper] == address(0), "wrapper");
        wrappedAsset[wrapper] = underlying;
    }

    function valueInCash(address asset, uint256 amount) external view returns (uint256) {
        address current = asset;
        for (uint256 depth; depth < 8 && wrappedAsset[current] != address(0); ++depth) {
            amount = ICinderWrappedAsset(current).convertToAssets(amount);
            current = wrappedAsset[current];
        }
        uint256 price = priceInCash[current];
        require(price != 0, "price");
        return amount * price / 1 ether;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function assetAt(uint256 index) external view returns (address) {
        return assets[index];
    }

    function finishConfiguration() external {
        require(msg.sender == administrator && assets.length >= 8, "configuration");
        administrator = address(0);
    }
}
