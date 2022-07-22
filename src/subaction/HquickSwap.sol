// SPDX-License-Identifier: MIT
pragma solidity >=0.6.6;
import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "../interfaces/IUniswapV2Factory.sol";

interface SettlementOracle{
    // get underlying address by pToken address
    function getUnderlyingPrice(address _token) external view returns (uint);
}

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
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


library UniswapV2Library {
    using SafeMath for uint;

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
            ))));
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'UniswapV2Library: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) internal pure returns (uint amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(address factory, uint amountIn, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address factory, uint amountOut, address[] memory path) internal view returns (uint[] memory amounts) {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');
        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}


library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
}


interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IERC20Extra is IERC20{
    function decimals() external view returns(uint8);
}

contract HquickSwap {

    address public router = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff; 
    address public factory = 0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32;
    address public dQuick = 0xf28164A485B0B2C90639E47b0f377b4a438a16B1;
    address wmatic = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address quick = 0x831753DD7087CaC61aB5644b308642cc1c33Dc13;
    address usdc = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    function swapTokensForEth(address tokenIn,uint256 tokenAmount) external {
        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = IUniswapV2Router02(router).WETH();

        IERC20(tokenIn).approve(router, tokenAmount);

        // make the swap
        IUniswapV2Router02(router).swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            msg.sender,
            block.timestamp
        );
    }

    function swapTokens(address tokenIn,address tokenOut,uint amountIn) public {
        address [] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint balance = IERC20(tokenIn).balanceOf(address(this));
        if(balance == 0) {return;}
        
        IERC20(tokenIn).approve(router,amountIn);
        IUniswapV2Router02(router).swapExactTokensForTokens(
            amountIn,
            0,
            path,
            msg.sender,
            block.timestamp
        );
        uint newBalance = IERC20(tokenIn).balanceOf(address(this));  
        require(balance > newBalance,"swap fail");
    }

    function approveTest(address token,uint amount) public  {
        IERC20(token).approve(router, amount);
    }

    function addLiquidity(address token1, address token2 ,uint256 amount1,uint256 amount2) external {
        IERC20(token1).approve(router, amount1);
        IERC20(token2).approve(router, amount2);
        // Add liquidity
        (,,uint liquidity) = IUniswapV2Router02(router).addLiquidity(
            token1,
            token2,
            amount1,
            amount2,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            msg.sender,
            block.timestamp);
        require(liquidity > 0,"add Liquidity failed");
        if(_tokenBalance(token1) > 0){
            IERC20(token1).transfer(msg.sender, _tokenBalance(token1));
        }
        if(_tokenBalance(token2) > 0){
            IERC20(token2).transfer(msg.sender, _tokenBalance(token2));
        }
        
    }

    function removeLiquidity(address tokenA,address tokenB,uint removeAmount) external returns (uint amountA, uint amountB){
        address lpToken = getPair(tokenA,tokenB);
        IERC20(lpToken).approve(router,removeAmount);

        uint lpTokenBalance = _tokenBalance(lpToken);
        (amountA , amountB) = IUniswapV2Router02(router).removeLiquidity(
            tokenA,
            tokenB,
            removeAmount,
            0,
            0,
            msg.sender,
            block.timestamp
        );
        require(lpTokenBalance > _tokenBalance(lpToken));
    }

    function removeLiquidity(address LpToken,uint removeAmount) external returns (uint amountA, uint amountB) {
        IUniswapV2Pair pair = IUniswapV2Pair(LpToken);
        address token0 = pair.token0(); 
        address token1 = pair.token1();
        address lpToken = _getPair(token0,token1);
        IERC20(lpToken).approve(router,removeAmount);

        uint lpTokenBalance = _tokenBalance(lpToken);

        (amountA , amountB) = IUniswapV2Router02(router).removeLiquidity(
            token0,
            token1,
            removeAmount,
            0,
            0,
            msg.sender,
            block.timestamp
        );
        require(lpTokenBalance > _tokenBalance(lpToken));
    }

    function addLiquidityEth(address otherToken ,uint256 tokenAmount, uint256 ethAmount) external {
        IERC20(otherToken).approve(router, tokenAmount);

        address LpToken = _getPair(otherToken,IUniswapV2Router02(router).WETH());
        uint balance = _tokenBalance(LpToken);

        uint b1 = _tokenBalance(otherToken);
        uint b2 = address(this).balance;

        // Add liquidity
        IUniswapV2Router02(router).addLiquidityETH{value: ethAmount}(
            otherToken,
            tokenAmount,
            tokenAmount * 95/100, // slippage is unavoidable
            ethAmount * 95/100, // slippage is unavoidable
            address(this),
            block.timestamp + 1
        );
        uint newBalance = _tokenBalance(LpToken);
        require(newBalance > balance);
        IERC20(LpToken).transfer(msg.sender,newBalance - balance);
        IERC20(otherToken).transfer(msg.sender,tokenAmount - (b1 - _tokenBalance(otherToken)));
        payable(msg.sender).transfer(ethAmount - ( b2 - address(this).balance ));

    }

    function _getPair(address token0,address token1) internal view returns(address){
        return IUniswapV2Factory(factory).getPair(token0,token1);
    }

    function getPair(address token0,address token1) public view returns(address){
        return _getPair(token0,token1);
    }

    // input token0 amount, output token1 amount
    function getAmountsOut(uint amountIn ,address[] calldata path) external view returns (uint[] memory amounts){
      amounts = UniswapV2Library.getAmountsOut(factory, amountIn,path) ;
    }

    // input lpTokenAmount, output tokenA amount,tokenB amount
    function getReserves(address LpToken,uint amount) public view returns(address token0,address token1,uint amount0,uint amount1){
        IUniswapV2Pair pair = IUniswapV2Pair(LpToken);
        token0 = pair.token0(); 
        token1 = pair.token1();
        (uint112 reserve0, uint112 reserve1,) =  pair.getReserves();
        uint lpTokenDecimals = uint(pair.decimals());
        uint proportion = amount * 10**lpTokenDecimals / pair.totalSupply();
        amount0 = proportion * uint(reserve0) / 10**lpTokenDecimals;
        amount1 = proportion * uint(reserve1) / 10**lpTokenDecimals;

    }

    function _tokenBalance(address token) private view returns(uint){
       return IERC20(token).balanceOf(address(this));
    }

    function dQuickToUsdc(uint amount) external {
        uint dquickBalance = _tokenBalance(dQuick);
        if( dquickBalance == 0){return;}
        IdQuick(dQuick).leave(dquickBalance);
        uint quickBalance = _tokenBalance(quick);
        if(quickBalance == 0){return;}
        swapTokens(address(quick),usdc,quickBalance);
    }

}

interface IdQuick is IERC20{

    // Enter the lair. Pay some QUICK. Earn some dragon QUICK.
    function enter(uint256 _quickAmount) external;

    // Leave the lair. Claim back your QUICK.
    function leave(uint256 _dQuickAmount) external ;

    // returns the total amount of QUICK an address has in the contract including fees earned
    function QUICKBalance(address _account) external view returns (uint256 quickAmount_) ;

    //returns how much QUICK someone gets for depositing dQUICK
    function dQUICKForQUICK(uint256 _dQuickAmount) external view returns (uint256 quickAmount_) ;
   
    //returns how much dQUICK someone gets for depositing QUICK
    function QUICKForDQUICK(uint256 _quickAmount) external view returns (uint256 dQuickAmount_) ;
}