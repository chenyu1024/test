// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;
import "@openzeppelin/contracts/access/Ownable.sol";

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}
interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);

    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
    external
    returns (uint[] memory amounts);

    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    returns (uint[] memory amounts);

    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);

    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}
interface IERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}
/*
    1. 假设是eth 且 在univ2有WETH池子
*/
contract Swap2Token is Ownable {
    uint8 public _swapRate = 50; // 1:2
    address public _router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public _WETH = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    // 精确兑换，回流储蓄钱包
    address private _storageWallet = 0xD22752Cb93751d6d732eE751448C45c72C37DeD2;

    event UpdateSwapRate(uint8 rate);
    event UpdateStorageWallet(address newWallet);
    event RecycleToken(address indexed sender, uint256 amount);
    event SwapOnce(address indexed sender); // swap自带amount log

    function updateSwapRate(uint8 _rate) external onlyOwner {
        require(_rate > 0 && _rate < 100, "rate format err");
        _swapRate = _rate;
        emit UpdateSwapRate(_rate);
    }

    function updateStorageWallet(address _new) external onlyOwner {
        require(_new != address(0), "0x err");
        _storageWallet = _new;
        emit UpdateStorageWallet(_new);
    }

    function swapByRate(bool _exactSwap, uint256 _aAmountIn, address _aToken, address _bToken) external {
        // verify pair pool
        address _factory = IUniswapV2Router01(_router).factory();
        address aLp = IUniswapV2Factory(_factory).getPair(_aToken, _WETH);
        require(aLp != address(0), "pairA not exist");
        address bLp = IUniswapV2Factory(_factory).getPair(_bToken, _WETH);
        require(bLp != address(0), "pairB not exist");

        // A -> B
        address[] memory path = new address[](3);
        path[0] = _aToken;
        path[1] = _WETH;
        path[2] = _bToken;
        uint256 bAmountOut = IUniswapV2Router01(_router).getAmountsOut(_aAmountIn, path)[path.length-1];
        // 根据汇率，预期换出bToken数量
        uint256 _minBTokenAmount = bAmountOut * _swapRate / 100;
        require(_minBTokenAmount >= _aAmountIn, "low swap rate");
        uint256 startBalance = IERC20(_bToken).balanceOf(address(this));
        IUniswapV2Router01(_router).swapExactTokensForTokens(
        _aAmountIn,
        _minBTokenAmount,
        path,
        address(this),
        block.timestamp
        );
        uint256 endBalance = IERC20(_bToken).balanceOf(address(this));
        IERC20(_bToken).transfer(address(msg.sender), _minBTokenAmount);
        // 是否是精确兑换 超出的汇率余额放到指定储蓄钱包
        if (_exactSwap) {
            uint256 resAmount = endBalance - startBalance;
            if (resAmount > 0) {
                IERC20(_bToken).transfer(_storageWallet, resAmount);
                emit RecycleToken(msg.sender, resAmount);
            }
        }
        emit SwapOnce(address(msg.sender));
    }
}
