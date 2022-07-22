// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPcvStorage} from "../interfaces/IPcvStorage.sol";
import {IERC20Extra} from "../interfaces/IERC20Extra.sol";
import {IERC20} from "../interfaces/IERC20.sol";

interface IPERC20 {
    // Deposit ,requires token authorization
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    // repay borrow params => -1
    function repayBorrow(uint256 repayAmount) external returns (uint256);

    // return 4 params: 0, deposit amount, borrow amount, share net value
    function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint) ;
    // return borrow amount
    function borrowBalanceStored(address account) external view returns (uint);
    // underlying token of the pool
    function underlying() external view returns(address);
    function balanceOf(address owner) external view returns(uint256);
}

interface LendComptroller{
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);
    /**
     * PIGGY-MODIFY:
     * @notice Add assets to be included in account liquidity calculation
     * @param pTokens List of cToken market addresses to be activated
     * @return Whether to enter each corresponding market success indicator
     */
    function enterMarkets(address[] memory pTokens) external returns(uint[] memory);

    function exitMarket(address pTokenAddress) external returns (uint);

    // Query available loan (whether it is normal 0: normal, remaining loanable amount, loan asset premium)
    function getAccountLiquidity(address account) external view returns (uint, uint, uint) ;

    // Query the fund pool that has opened the pledge
    function getAssetsIn(address account) external view returns(address [] memory);
}

interface IPoolProvider{
    // get asset pool address by token address
    function getUnderlyingByPToken(address underlying) external view returns (address pToken);
    // return rate;  rate = token / pToken; pToken.decimals = 8;
    function currentExchangeRateStored(address pToken) external view returns (uint);
}

contract HLend {
    address _pcvStorage ;

    function deposit(address token,uint256 amount) external  {
        address pool = getPool(token);
        IERC20(token).approve(pool,amount);
        uint balance = _pTokenBalance(token);
        IPERC20(pool).mint(amount);
        require(balance > _pTokenBalance(token));
    }

    function borrow(address token,uint256 amount) external  {
        address pool = getPool(token);
        pledge(pool);
        uint balance = _pTokenBalance(token);
        IPERC20(pool).borrow(amount);
        require(balance < _tokenBalance(token));
        
        address[] memory assets = new address[](1);
        assets[0] = pool;
        IPcvStorage(_pcvStorage).recordPcvAssets(assets);
    }

    function withdrawByPToken(address pToken,uint256 amount) external {
        uint balance = _pTokenBalance(pToken);
        IPERC20(pToken).redeem(amount);
        require(balance > _pTokenBalance(pToken));
    }

    function withdraw(address token,uint256 amount) external{
        address pool = getPool(token);
        uint balance = _tokenBalance(token);
        IPERC20(pool).redeem(amount);
        require(balance < _pTokenBalance(token));
    }

    function repayBorrow(address token,uint256 amount) external {
            address pool = getPool(token);
            uint borrowed = IPERC20(pool).borrowBalanceStored(address(this));
            if(borrowed == 0){
                return;
            }
            IERC20(token).approve(pool,amount);
            uint balance = _pTokenBalance(token);
            if(amount <= borrowed){
                IPERC20(pool).repayBorrow(amount);
            }else{
                int repayAll = -1;
                IPERC20(pool).repayBorrow(uint(repayAll));
            }
        require(balance > _pTokenBalance(token));
        }


    // Turn on the pledge switch
    function pledge(address pool) internal {
        address comptorller = getLendComptroller();
        address [] memory assets = LendComptroller(comptorller).getAssetsIn(address(this));
        uint256 arrayLen = assets.length;
        bool hasPledge = false;
        for(uint256 i = 0;i<arrayLen;i++){
            if(pool == assets[i]){
                hasPledge = true;
            }
        }
        if(!hasPledge){
            address[] memory pledges = new address[](1);
            pledges[0] = pool;
            LendComptroller(comptorller).enterMarkets(pledges);
        }
    }

    function enterMarket(address[] memory pools) public{
            address comptorller = getLendComptroller();
            LendComptroller(comptorller).enterMarkets(pools);
    } 

    function  isEntermarket(address pToken) public view returns(address[] memory) {
        address comptorller = getLendComptroller();
        address[] memory assets = LendComptroller(comptorller).getAssetsIn(pToken);
        return assets;
    }

    function getPool(address token) public view returns(address ){
        // pool address
       return IPoolProvider(poolProvider()).getUnderlyingByPToken(token);
        
    }

    function getLendComptroller() internal pure returns(address comptroller ){
        comptroller = 0xE19bedCc1beDF52F63b401bd21f16529be33Fc7E;
        return comptroller;
    }

    // borrowed amount
    function borrowedAmount(address token,address account) public view returns(uint borrowed){
       borrowed = IPERC20(getPool(token)).borrowBalanceStored(account);
    }

    function poolProvider() public pure returns(address){
       return 0xf25ED06D388363052920D1B06924ce64Ef987eD6;
       }

    function pTokenDecimals() private pure returns(uint){
           return 8;
       }

    //@dev get pToken amount by token
    function getPTokenAmount(address token , uint amount) public view returns(uint pTokenAmount){
        address pToken = getPool(token);
        uint changeRate = IPoolProvider(poolProvider()).currentExchangeRateStored(pToken);
        uint tokenDecimals = IERC20Extra(token).decimals();
        uint _pTokenDecimals = pTokenDecimals();
        
        // 1e18 - pToken.decimals = 10; pToken.decimals = 8;
        uint changeRateScale = 10**(tokenDecimals + 18 -_pTokenDecimals);
        
        pTokenAmount = (tokenDecimals >= _pTokenDecimals) ?
        amount * changeRateScale / changeRate / 10**(tokenDecimals - _pTokenDecimals):
        amount * changeRateScale  / changeRate * 10**(_pTokenDecimals - tokenDecimals);
    }

    // @dev get token amount by pToken
    function getTokenAmount(address pToken , uint amount) public view returns(uint tokenAmount){
        uint changeRate = IPoolProvider(poolProvider()).currentExchangeRateStored(pToken);
         tokenAmount  =  amount * changeRate / 1e18;
    }
    
    function _tokenBalance(address token) private view returns(uint){
       return IERC20(token).balanceOf(address(this));
    }

    function _pTokenBalance(address pToken) private view returns(uint){
       return IPERC20(pToken).balanceOf(address(this));
    }
}



