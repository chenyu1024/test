// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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
企业用户可以挂单
普通大众可以选择指定的单子,进行换汇操作.
企业单子的内容包含
tokenA=>tokenB 的费率
tokenA 的可换汇下限,
tokenA 的可换汇上限
tokenB 的可换汇数量
tokenA,
tokenB,
...
企业用户可以创建很多 tokenA tokenB tokenC .... 的单子.
企业用户可以修改 单子的费率, 上下限制, 充值tokenB 以及 撤单....
普通大众 可以凭借 tokenA 与 该单子进行换汇操作,
平台会针对不同的 token, 收取一定的平台费(为用户兑换出来的代币基础上收取一定比例的代理), 在换汇时收取.
*/
contract SwapDemo is Ownable, ReentrancyGuard {

    constructor(address _receiveEoa) {
        swapFeeWallet = _receiveEoa; // 平台接收swapFee
    }

    struct SwapOrder {
        State status; // 单子状态
        uint16 exchangeRate; // 最小汇率 1:1000 , 即0.1%
        uint256 makeTime; // 发单时间
        uint256 tokenAExchangeMin; // 下限
        uint256 tokenAExchangeMax; // 上限
        uint256 tokenBBalance; // maker的保证金（可换汇数量
        address tokenA;
        address tokenB;
        address maker;
    }
    // 订单编号(从1开始
    uint32 public orderId = 1;
    // 平台手续费收款账户
    address public swapFeeWallet;
    // 未成交,已撤单
    enum State { Pending, Canceled}
    // 企业用户列表
    mapping(address => bool) public vipUsers;
    // 挂单列表
    mapping(uint256 => SwapOrder) public swapOrders;
    // 平台手续费（token=>rate)
    mapping(address => uint256) public swapFees;

    modifier onlyVip(address maker) {
        require(vipUsers[maker], "not vip");
        _;
    }
    modifier onlyMaker(uint32 swapOrderId, address maker) {
        require(swapOrders[swapOrderId].maker == maker, "auth err");
        _;
    }

    modifier antiContract(address from) {
        uint256 size;
        assembly { size := extcodesize(from) }
        require(!(size > 0), "anti contract");
        _;
    }
    // 挂单 订单id，挂单时间，挂单上下限，保证金，maker
    event MakeOrder(uint32, uint256, uint256, uint256, uint256, address);
    // 吃单 订单id，吃单时间，吃单数量，taker
    event TakeOrder(uint32, uint256, uint256, address);
    // 更新挂单 订单id，汇率，更新时间，挂单上下限，tokenB
    event UpdateSwap(uint32, uint16, uint256, uint256, uint256, address);
    // 撤单 订单id，撤单时间
    event Cancel(uint32, uint256);
    // 充值 订单id，充值数量，充值token
    event AddOrderToken(uint32, uint256, address);

    // 更改每个token对应的手续费
    function updateSwapFees(uint256[] memory fees, address[] memory tokens) external onlyOwner {
        require(fees.length == tokens.length && fees.length > 0, "data err");
        for (uint256 i = 0; i < fees.length; i++) {
            require(tokens[i] != address(0), "format err");
            require(fees[i] > 0 && fees[i] <= 100, "format err");
            swapFees[tokens[i]] = fees[i];
        }
    }

    // 更新企业用户
    function updateVipUsersStatus(bool status, address[] memory vipUserList) external onlyOwner {
        require(vipUserList.length > 0, "len err");
        for(uint256 i = 0; i < vipUserList.length; i++) {
            vipUsers[vipUserList[i]] = status;
        }
    }

    // 发单
    function make(
        uint16 rate,
        uint256 tokenBAmount,
        uint256 min,
        uint256 max,
        address tokenA,
        address tokenB
    ) external onlyVip(msg.sender) antiContract(msg.sender) nonReentrant {
        // check args
        require(rate > 0, "rate err");
        require(tokenBAmount > 0, "amount err");
        require(min < max && min > 0, "scope err");
        require(tokenA != tokenB && tokenA != address(0) && tokenB != address(0), "address err");
        // 需要链下用eoaA签名对此合约的approve
        bool suc = IERC20(tokenB).transferFrom(msg.sender, address(this), tokenBAmount);
        require(suc, "transfer err");

        SwapOrder storage so = swapOrders[orderId];
        so.exchangeRate = rate;
        so.tokenAExchangeMin = min;
        so.tokenAExchangeMax = max;
        so.tokenBBalance = tokenBAmount;
        so.status = State.Pending;
        so.makeTime = block.timestamp;
        so.tokenA = tokenA;
        so.tokenB = tokenB;
        so.maker = msg.sender;

    unchecked {
        orderId++;
    }
        emit MakeOrder(orderId-1, block.timestamp, min, max, tokenBAmount, msg.sender);
    }

    // 编辑单子
    function updateSwapOrder(
        uint16 rate,
        uint32 swapOrderId,
        uint256 tokenAMin,
        uint256 tokenAMax,
        address swapDest
    ) external onlyMaker(swapOrderId, msg.sender) {
        require(swapOrders[swapOrderId].status == State.Pending, "status err");
        // 如果更换了tokenB 需要退款并且充值
        address tokenB = swapOrders[swapOrderId].tokenB;
        uint256 balance = swapOrders[swapOrderId].tokenBBalance;
        if (tokenB != swapDest) {
            if (balance > 0) {
                IERC20(tokenB).transfer(msg.sender, balance);
            }
        }
        swapOrders[swapOrderId].exchangeRate = rate;
        swapOrders[swapOrderId].tokenAExchangeMin = tokenAMin;
        swapOrders[swapOrderId].tokenAExchangeMax = tokenAMax;
        swapOrders[swapOrderId].tokenB = swapDest;
        emit UpdateSwap(swapOrderId, rate, block.timestamp, tokenAMin, tokenAMax, tokenB);
    }

    // 换汇操作
    function swap(uint32 swapOrderId, uint256 tokenAAmount, address taker) private returns (bool) {
        address tokenB = swapOrders[swapOrderId].tokenB;
        bool suc = IERC20(tokenB).transferFrom(address(this), msg.sender, tokenAAmount);
        require(suc, "transfer err");

        // check非交易状态
        if (swapOrders[swapOrderId].status != State.Pending) {
            return false;
        }
        uint256 rate = swapOrders[swapOrderId].exchangeRate;
        uint256 tokenBExchangeAmount = tokenAAmount / rate / 1000;
        // 平台费率
        uint256 swapFee = swapFees[tokenB];
        uint256 swapFeePay = tokenBExchangeAmount * swapFee / 100;
        // taker收到的tokenB
        uint256 takerReceive = tokenBExchangeAmount - swapFeePay;
        IERC20(tokenB).transfer(taker, takerReceive);
        IERC20(tokenB).transfer(swapFeeWallet, swapFeePay);

        // update order
        swapOrders[swapOrderId].tokenBBalance -= tokenBExchangeAmount;
        emit TakeOrder(swapOrderId, block.timestamp, takerReceive, msg.sender);
        return true;
    }

    // 撤单
    function cancelOrder(uint32 swapOrderId) external onlyMaker(swapOrderId, msg.sender){
        require(swapOrders[swapOrderId].status == State.Pending, "state err");
        swapOrders[swapOrderId].status = State.Canceled;
        // 退款
        if (swapOrders[swapOrderId].tokenBBalance > 0) {
            IERC20(swapOrders[swapOrderId].tokenB).transfer(msg.sender, swapOrders[swapOrderId].tokenBBalance);
            swapOrders[swapOrderId].tokenBBalance = 0;
        }
        emit Cancel(swapOrderId, block.timestamp);
    }

    // 吃单
    function take(uint32 swapOrderId, uint256 tokenAAmount) external nonReentrant antiContract(msg.sender) {
        uint256 min = swapOrders[swapOrderId].tokenAExchangeMin;
        uint256 max = swapOrders[swapOrderId].tokenAExchangeMax;
        require(tokenAAmount > min && tokenAAmount < max, "amount err");

        bool swapSuc = swap(swapOrderId, tokenAAmount, msg.sender);
        require(swapSuc, "swap fail");
    }

    // 充值
    function addSecurityDeposit(uint32 swapOrderId, uint256 addAmount) external nonReentrant antiContract(msg.sender) onlyMaker(swapOrderId, msg.sender) {
        // transfer to contract(need approve
        address tokenB = swapOrders[swapOrderId].tokenB;
        bool suc = IERC20(tokenB).transferFrom(msg.sender, address(this), addAmount);
        require(suc, "add err");
        // update order
        swapOrders[swapOrderId].tokenBBalance += addAmount;
        emit AddOrderToken(swapOrderId, addAmount, tokenB);
    }
}
