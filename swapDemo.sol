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
        uint256 exchangeRate; // 最小汇率 1:1000 , 即0.1%
        uint256 tokenAExchangeMin; // 最低保证金 根据maker的保证金
        uint256 tokenAExchangeMax; // 超过保证金，需要maker补单
        uint256 tokenBMakerNeedAdd; // maker需要充值的tokenB数量
        uint256 tokenBBalance; // maker的保证金（可换汇数量
        uint256 makeTime; // 发单时间
        uint256 takerTime; // 吃单时间
        address tokenA;
        address tokenB;
        address maker;
    }

    // 订单编号(从1开始
    uint256 public orderId = 1;
    // 平台手续费收款账户
    address public swapFeeWallet;
    // 未成交,已成交,已撤单,待充值
    enum State { Pending, Closed, Canceled, Waiting}
    // 企业用户列表
    mapping(address => bool) public vipUsers;
    // 订单列表
    mapping(uint256 => SwapOrder) public swapOrders;
    // 平台手续费（token=>rate)
    mapping(address => uint256) public swapFees;

    modifier onlyVip(address maker) {
        require(vipUsers[maker], "not vip");
        _;
    }

    modifier antiContract(address from) {
        uint256 size;
        assembly { size := extcodesize(from) }
        require(!(size > 0), "anti contract");
        _;
    }

    event MakeOrder(uint256, address);
    event UpdateSwapOrder(uint256);
    event Cancel(uint256);
    event TakeOrder(uint256);

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
        uint256 rate,
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
        emit MakeOrder(orderId-1, msg.sender);
    }

    // 编辑单子
    function updateSwapOrder(
        uint256 swapOrderId,
        uint256 rate,
        uint256 tokenAMin,
        uint256 tokenAMax,
        address swapDest
    ) external {
        require(swapOrders[swapOrderId].maker == msg.sender, "auth err");
        require(swapOrders[swapOrderId].status == State.Pending, "status err");
        swapOrders[swapOrderId].exchangeRate = rate;
        swapOrders[swapOrderId].tokenAExchangeMin = tokenAMin;
        swapOrders[swapOrderId].tokenAExchangeMax = tokenAMax;
        swapOrders[swapOrderId].tokenB = swapDest;
        emit UpdateSwapOrder(swapOrderId);
    }

    // 换汇操作
    function swap(uint256 swapIndex, uint256 tokenAAmount, address taker) private returns (bool) {
        uint256 min = swapOrders[swapIndex].tokenAExchangeMin;
        uint256 max = swapOrders[swapIndex].tokenAExchangeMax;
        require(tokenAAmount >= min && tokenAAmount <= max, "amount err");
        // check非交易状态
        if (swapOrders[swapIndex].status != State.Pending) {
            return false;
        }
        // maker的TokenB保证金
        uint256 securityFund = swapOrders[swapIndex].tokenBBalance;
        address tokenB = swapOrders[swapIndex].tokenB;

        uint256 rate = swapOrders[swapIndex].exchangeRate;
        uint256 tokenBExchangeAmount = tokenAAmount / rate / 1000;
        if (tokenBExchangeAmount > securityFund) {
            // 需要maker充值的tokenB数量
            uint256 needAddAmount = tokenBExchangeAmount - securityFund;
            swapOrders[swapIndex].takerTime = block.timestamp;
            swapOrders[swapIndex].tokenBMakerNeedAdd = needAddAmount;
            swapOrders[swapIndex].status = State.Waiting;
            return true;
        }
        uint256 swapFee = swapFees[tokenB];
        uint256 swapFeePay = tokenBExchangeAmount * swapFee / 100;
        // taker should receive tokenB amount
        uint256 takerReceive = tokenBExchangeAmount - swapFeePay;
        IERC20(tokenB).transfer(taker, takerReceive);
        IERC20(tokenB).transfer(swapFeeWallet, swapFeePay);
        // update order
        swapOrders[swapIndex].status = State.Closed;
        emit TakeOrder(orderId);
        return true;
    }

    // 撤单
    function cancelOrder(uint256 swapOrderId) external {
        require(swapOrders[swapOrderId].maker == msg.sender, "auth err");
        // 只有等待吃单的order才可以撤单
        require(swapOrders[swapOrderId].status == State.Pending, "state err");
        swapOrders[swapOrderId].status = State.Canceled;
        emit Cancel(swapOrderId);
    }

    // 吃单
    function take(uint256 swapOrderId, uint256 tokenAAmount) external nonReentrant antiContract(msg.sender) {
        uint256 min = swapOrders[swapOrderId].tokenAExchangeMin;
        uint256 max = swapOrders[swapOrderId].tokenAExchangeMax;
        address tokenB = swapOrders[swapOrderId].tokenB;
        require(tokenAAmount > min && tokenAAmount < max, "amount err");

        bool suc = IERC20(tokenB).transferFrom(msg.sender, address(this), tokenAAmount);
        require(suc, "transfer err");

        bool swapSuc = swap(swapOrderId, tokenAAmount, msg.sender);
        require(swapSuc, "swap fail");
    }

    // 补单充值
    function addSecurityDeposit(uint256 swapOrderId, uint256 addAmount) external {
        require(swapOrders[swapOrderId].maker == msg.sender, "auth err");
        require(swapOrders[swapOrderId].status == State.Waiting, "status err");
        require(addAmount == swapOrders[swapOrderId].tokenBMakerNeedAdd, "amount err");
        // transfer to contract( need approve 手动
        address tokenB = swapOrders[swapOrderId].tokenB;
        bool suc = IERC20(tokenB).transferFrom(msg.sender, address(this), addAmount);
        require(suc, "transfer err");
        // update order
        swapOrders[swapOrderId].tokenBMakerNeedAdd = 0;
        swapOrders[swapOrderId].tokenBBalance += addAmount;
        swapOrders[swapOrderId].takerTime = block.timestamp;
        swapOrders[swapOrderId].status = State.Closed;
        emit TakeOrder(swapOrderId);
    }
}
