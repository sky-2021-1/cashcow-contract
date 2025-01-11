// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// IERC20接口
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPancakeRouter02 {
    function WETH() external pure returns (address);
    
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

// 简化版的CashCow代币合约
contract CashCow is IERC20 {
    // 添加所有权转移事件
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    string public name = "CashCow";
    string public symbol = "CSC";
    uint8 public decimals = 18;
    uint256 public override totalSupply;
    
    // 费用比例
    uint256 public constant BUY_FEE = 2;  // 2% 买入费用
    uint256 public constant SELL_FEE = 3; // 3% 卖出费用
    uint256 public constant MIN_TOKENS_REMAINING = 1 * 10**18; // 1个代币最小持有量
    
    // 收款钱包
    address public constant WALLET1 = 0x4174Ff054269e86f7974b0325d2Fd453a5aB433f; // 40%
    address public constant WALLET2 = 0xd5Bb75AeEcbAD4BC04788a511D8024FC0BBE0Ee5; // 60%
    
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955; // BSC上的USDT地址
    
    address public owner;
    address public pancakeRouter;
    
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    
    bool private _inSwapAndLiquify;
    uint256 public numTokensToSwap = 5000 * 10**18; // 修改为5000个代币才触发兑换
    
    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    constructor(address _pancakeRouter) {
        owner = msg.sender;
        pancakeRouter = _pancakeRouter;
        _mint(msg.sender, 1000000000 * 10**decimals); // 铸造10亿代币
        allowance[address(this)][_pancakeRouter] = type(uint256).max;
        emit Approval(address(this), _pancakeRouter, type(uint256).max);
    }
    
    receive() external payable {}
    
    function transfer(address to, uint256 amount) external override returns (bool) {
        return _transfer(msg.sender, to, amount);
    }
    
    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }
    
    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(from != address(0) && to != address(0), "Invalid address");
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        // 检查最小持币量（除了owner）
        if (from != owner) {
            require(balanceOf[from] - amount >= MIN_TOKENS_REMAINING, "Must keep at least 1 token");
        }
        
        uint256 fee = 0;
        bool takeFee = !_inSwapAndLiquify;
        
        // 计算费用
        if (takeFee) {
            if (from == pancakeRouter) {
                fee = (amount * BUY_FEE) / 100;
            } else if (to == pancakeRouter) {
                fee = (amount * SELL_FEE) / 100;
            }
        }
        
        // 处理费用
        if (fee > 0) {
            balanceOf[from] -= fee;
            balanceOf[address(this)] += fee;
            emit Transfer(from, address(this), fee);
            amount -= fee;
            
            // 当累积的代币达到阈值时，将其兑换为BNB并分配
            if (balanceOf[address(this)] >= numTokensToSwap && !_inSwapAndLiquify) {
                swapAndDistribute();
            }
        }
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
    
    function _mint(address account, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[account] += amount;
        emit Transfer(address(0), account, amount);
    }
    
    // 兑换并分配
    function swapAndDistribute() private lockTheSwap {
        uint256 totalAmount = balanceOf[address(this)];
        if (totalAmount == 0) return;
        
        // 计算分配比例
        uint256 amount1 = (totalAmount * 40) / 100; // 40% 给钱包1
        uint256 amount2 = totalAmount - amount1;    // 60% 给钱包2
        
        // 默认兑换为USDT并发送
        swapTokensForUSDTAndSend(amount1, WALLET1);
        swapTokensForUSDTAndSend(amount2, WALLET2);
    }
    
    // 将代币兑换为USDT并发送到指定地址
    function swapTokensForUSDTAndSend(uint256 tokenAmount, address to) private {
        // 生成交易路径
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = USDT;
        
        try IPancakeRouter02(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // 接受任何数量的USDT
            path,
            to,  // USDT直接发送到指定地址
            block.timestamp
        ) {} catch {
            // 如果USDT兑换失败，尝试兑换为BNB
            swapTokensForBNBAndSend(tokenAmount, to);
        }
    }
    
    // 保留BNB兑换作为备选方案
    function swapTokensForBNBAndSend(uint256 tokenAmount, address to) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = IPancakeRouter02(pancakeRouter).WETH();
        
        try IPancakeRouter02(pancakeRouter).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            to,
            block.timestamp
        ) {} catch {}
    }
    
    // 设置触发兑换的代币数量
    function setNumTokensToSwap(uint256 _numTokens) external onlyOwner {
        numTokensToSwap = _numTokens * 10**18;
    }
    
    // 手动触发USDT兑换
    function manualSwapToUSDT() external onlyOwner {
        swapAndDistribute();
    }
    
    // 手动触发BNB兑换（作为备选）
    function manualSwapToBNB() external onlyOwner {
        uint256 totalAmount = balanceOf[address(this)];
        if (totalAmount == 0) return;
        
        uint256 amount1 = (totalAmount * 40) / 100;
        uint256 amount2 = totalAmount - amount1;
        
        swapTokensForBNBAndSend(amount1, WALLET1);
        swapTokensForBNBAndSend(amount2, WALLET2);
    }
    
    // 紧急提取BNB
    function withdrawBNB() external onlyOwner {
        (bool success,) = owner.call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }
    
    // 紧急提取代币
    function withdrawToken(address tokenAddress, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).transfer(owner, amount);
    }
    
    // 转移所有权
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
    
    // 放弃所有权
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }
} 
