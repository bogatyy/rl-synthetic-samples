// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

interface IERC20Router {
    function balanceOf(address owner) external view returns (uint256);
}

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeFactoryRouter {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface IPancakePairRouter {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function mint(address) external returns (uint256);
    function burn(address) external returns (uint256, uint256);
    function swap(uint256, uint256, address, bytes calldata) external;
    function transferFrom(address, address, uint256) external returns (bool);
    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external;
}

library PancakeTransferHelper {
    function safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Pancake: APPROVE_FAILED");
    }

    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Pancake: TRANSFER_FAILED");
    }

    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Pancake: TRANSFER_FROM_FAILED");
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}("");
        require(success, "Pancake: ETH_TRANSFER_FAILED");
    }
}

library PancakeLibrary {
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "PancakeLibrary: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "PancakeLibrary: ZERO_ADDRESS");
    }

    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        pair = IPancakeFactoryRouter(factory).getPair(tokenA, tokenB);
    }

    function getReserves(address factory, address tokenA, address tokenB)
        internal view returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        address pair = pairFor(factory, tokenA, tokenB);
        require(pair != address(0), "PancakeLibrary: PAIR_NOT_FOUND");
        (uint112 reserve0, uint112 reserve1,) = IPancakePairRouter(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "PancakeLibrary: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "PancakeLibrary: INSUFFICIENT_LIQUIDITY");
        amountB = amountA * reserveB / reserveA;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal pure returns (uint256 amountOut)
    {
        require(amountIn > 0, "PancakeLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "PancakeLibrary: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 9_975;
        amountOut = amountInWithFee * reserveOut / (reserveIn * 10_000 + amountInWithFee);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal pure returns (uint256 amountIn)
    {
        require(amountOut > 0, "PancakeLibrary: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > amountOut, "PancakeLibrary: INSUFFICIENT_LIQUIDITY");
        amountIn = reserveIn * amountOut * 10_000 / ((reserveOut - amountOut) * 9_975) + 1;
    }

    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal view returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "PancakeLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; ++i) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal view returns (uint256[] memory amounts)
    {
        require(path.length >= 2, "PancakeLibrary: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; --i) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}

/// @notice PancakeSwap V2 router behavior, including liquidity, exact-in/out,
/// native-asset, permit, multihop, and fee-on-transfer paths.
contract PancakeRouter {
    address public immutable factory;
    address public immutable WETH;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "PancakeRouter: EXPIRED");
        _;
    }

    constructor(address factory_, address wrappedNative_) {
        factory = factory_;
        WETH = wrappedNative_;
    }

    receive() external payable { require(msg.sender == WETH, "PancakeRouter: NATIVE_ONLY"); }

    function _addLiquidity(
        address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        if (IPancakeFactoryRouter(factory).getPair(tokenA, tokenB) == address(0)) {
            IPancakeFactoryRouter(factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = PancakeLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) return (amountADesired, amountBDesired);
        uint256 amountBOptimal = PancakeLibrary.quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "PancakeRouter: INSUFFICIENT_B_AMOUNT");
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = PancakeLibrary.quote(amountBDesired, reserveB, reserveA);
        require(amountAOptimal >= amountAMin, "PancakeRouter: INSUFFICIENT_A_AMOUNT");
        return (amountAOptimal, amountBDesired);
    }

    function addLiquidity(
        address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = PancakeLibrary.pairFor(factory, tokenA, tokenB);
        PancakeTransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        PancakeTransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IPancakePairRouter(pair).mint(to);
    }

    function addLiquidityETH(
        address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable ensure(deadline) returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        (amountToken, amountETH) = _addLiquidity(
            token, WETH, amountTokenDesired, msg.value, amountTokenMin, amountETHMin
        );
        address pair = PancakeLibrary.pairFor(factory, token, WETH);
        PancakeTransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWrappedNative(WETH).deposit{value: amountETH}();
        require(IWrappedNative(WETH).transfer(pair, amountETH), "PancakeRouter: WETH_TRANSFER");
        liquidity = IPancakePairRouter(pair).mint(to);
        if (msg.value > amountETH) PancakeTransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    function removeLiquidity(
        address tokenA, address tokenB, uint256 liquidity, uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) public ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = PancakeLibrary.pairFor(factory, tokenA, tokenB);
        require(pair != address(0), "PancakeRouter: PAIR_NOT_FOUND");
        require(
            IPancakePairRouter(pair).transferFrom(msg.sender, pair, liquidity),
            "PancakeRouter: LP_TRANSFER"
        );
        (uint256 amount0, uint256 amount1) = IPancakePairRouter(pair).burn(to);
        (address token0,) = PancakeLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, "PancakeRouter: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "PancakeRouter: INSUFFICIENT_B_AMOUNT");
    }

    function removeLiquidityETH(
        address token, uint256 liquidity, uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) public ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token, WETH, liquidity, amountTokenMin, amountETHMin, address(this), deadline
        );
        PancakeTransferHelper.safeTransfer(token, to, amountToken);
        IWrappedNative(WETH).withdraw(amountETH);
        PancakeTransferHelper.safeTransferETH(to, amountETH);
    }

    function removeLiquidityWithPermit(
        address tokenA, address tokenB, uint256 liquidity, uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline, bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint256 amountA, uint256 amountB) {
        address pair = PancakeLibrary.pairFor(factory, tokenA, tokenB);
        IPancakePairRouter(pair).permit(
            msg.sender, address(this), approveMax ? type(uint256).max : liquidity, deadline, v, r, s
        );
        return removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    function removeLiquidityETHWithPermit(
        address token, uint256 liquidity, uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline, bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH) {
        address pair = PancakeLibrary.pairFor(factory, token, WETH);
        IPancakePairRouter(pair).permit(
            msg.sender, address(this), approveMax ? type(uint256).max : liquidity, deadline, v, r, s
        );
        return removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public ensure(deadline) returns (uint256 amountETH) {
        (, amountETH) = removeLiquidity(
            token, WETH, liquidity, amountTokenMin, amountETHMin, address(this), deadline
        );
        PancakeTransferHelper.safeTransfer(token, to, IERC20Router(token).balanceOf(address(this)));
        IWrappedNative(WETH).withdraw(amountETH);
        PancakeTransferHelper.safeTransferETH(to, amountETH);
    }

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountETH) {
        address pair = PancakeLibrary.pairFor(factory, token, WETH);
        IPancakePairRouter(pair).permit(
            msg.sender, address(this), approveMax ? type(uint256).max : liquidity, deadline, v, r, s
        );
        return removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    function _swap(uint256[] memory amounts, address[] memory path, address to) internal {
        for (uint256 i; i < path.length - 1; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = PancakeLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address recipient = i < path.length - 2
                ? PancakeLibrary.pairFor(factory, output, path[i + 2]) : to;
            IPancakePairRouter(PancakeLibrary.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, recipient, ""
            );
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = PancakeLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        PancakeTransferHelper.safeTransferFrom(path[0], msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut, uint256 amountInMax, address[] calldata path, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = PancakeLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "PancakeRouter: EXCESSIVE_INPUT_AMOUNT");
        PancakeTransferHelper.safeTransferFrom(path[0], msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external payable ensure(deadline) returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "PancakeRouter: INVALID_PATH");
        amounts = PancakeLibrary.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWrappedNative(WETH).deposit{value: amounts[0]}();
        require(IWrappedNative(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]), "PancakeRouter: WETH_TRANSFER");
        _swap(amounts, path, to);
    }

    function swapTokensForExactETH(
        uint256 amountOut, uint256 amountInMax, address[] calldata path, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "PancakeRouter: INVALID_PATH");
        amounts = PancakeLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "PancakeRouter: EXCESSIVE_INPUT_AMOUNT");
        PancakeTransferHelper.safeTransferFrom(path[0], msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWrappedNative(WETH).withdraw(amounts[amounts.length - 1]);
        PancakeTransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "PancakeRouter: INVALID_PATH");
        amounts = PancakeLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        PancakeTransferHelper.safeTransferFrom(path[0], msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWrappedNative(WETH).withdraw(amounts[amounts.length - 1]);
        PancakeTransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external payable ensure(deadline) returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "PancakeRouter: INVALID_PATH");
        amounts = PancakeLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, "PancakeRouter: EXCESSIVE_INPUT_AMOUNT");
        IWrappedNative(WETH).deposit{value: amounts[0]}();
        require(IWrappedNative(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), amounts[0]), "PancakeRouter: WETH_TRANSFER");
        _swap(amounts, path, to);
        if (msg.value > amounts[0]) PancakeTransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    function _swapSupportingFeeOnTransferTokens(address[] memory path, address to) internal {
        for (uint256 i; i < path.length - 1; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = PancakeLibrary.sortTokens(input, output);
            IPancakePairRouter pair = IPancakePairRouter(PancakeLibrary.pairFor(factory, input, output));
            (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
            (uint256 reserveInput, uint256 reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            uint256 amountInput = IERC20Router(input).balanceOf(address(pair)) - reserveInput;
            uint256 amountOutput = PancakeLibrary.getAmountOut(amountInput, reserveInput, reserveOutput);
            (uint256 amount0Out, uint256 amount1Out) = input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            address recipient = i < path.length - 2
                ? PancakeLibrary.pairFor(factory, output, path[i + 2]) : to;
            pair.swap(amount0Out, amount1Out, recipient, "");
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external ensure(deadline) {
        PancakeTransferHelper.safeTransferFrom(path[0], msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amountIn);
        uint256 balanceBefore = IERC20Router(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(IERC20Router(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external payable ensure(deadline) {
        require(path[0] == WETH, "PancakeRouter: INVALID_PATH");
        IWrappedNative(WETH).deposit{value: msg.value}();
        require(IWrappedNative(WETH).transfer(PancakeLibrary.pairFor(factory, path[0], path[1]), msg.value), "PancakeRouter: WETH_TRANSFER");
        uint256 balanceBefore = IERC20Router(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(IERC20Router(path[path.length - 1]).balanceOf(to) - balanceBefore >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline
    ) external ensure(deadline) {
        require(path[path.length - 1] == WETH, "PancakeRouter: INVALID_PATH");
        PancakeTransferHelper.safeTransferFrom(path[0], msg.sender, PancakeLibrary.pairFor(factory, path[0], path[1]), amountIn);
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint256 amountOut = IERC20Router(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IWrappedNative(WETH).withdraw(amountOut);
        PancakeTransferHelper.safeTransferETH(to, amountOut);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256) {
        return PancakeLibrary.quote(amountA, reserveA, reserveB);
    }
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return PancakeLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256) {
        return PancakeLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory) {
        return PancakeLibrary.getAmountsOut(factory, amountIn, path);
    }
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory) {
        return PancakeLibrary.getAmountsIn(factory, amountOut, path);
    }
}
