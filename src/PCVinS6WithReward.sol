// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPcvStorage} from "./PCV_editable_strategy/interfaces/IPcvStorage.sol";
import {PcvStruct} from "./PCV_editable_strategy/libraries/PcvStruct.sol";
import {Ownable} from "./openzeppelin/Ownable.sol";
import {IERC20Extra} from "./interfaces/IERC20Extra.sol";
import {IERC20} from "./interfaces/IERC20Extra.sol";
import {IPcvRewardPool} from "./PCV_editable_strategy/interfaces/IPcvRewardPool.sol";

// === S6 
import "./interfaces/IUniswapV2Pair.sol";
import {Hcommon} from "./subaction/Hcommon.sol";
import "./interfaces/IHQuickSwap.sol";
import "./interfaces/IHQuickStaking.sol";
// === S6 END

interface IWMATIC {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function decimals() external view returns(uint8);
}

 interface Comptroller{
    // PCV fund utilization counting, for the purpose of judge the availability of the fund
    function canUsePcvFund(address account) external view returns (bool) ;
}

// ===== S6

interface IHDpLend{
    function deposit(address token,uint256 amount) external  ;
    function borrow(address token,uint256 amount) external ;
    function withdraw(address token,uint256 amount) external;
    function repayBorrow(address token,uint256 amount) external ;
    function borrowedAmount(address token,address account) external view returns(uint borrowed);
}

// settlement contract
interface ISettlement{
    // params (PCV Address, total shares) 
    function netAssetValue(address pcv) external view returns (uint netAssets, uint totalDebt, uint netWorth);
    //Return: base unit, pledge rate
    function tokenConfig(address token) external view returns(address _token,string memory symbol,string memory soure,uint collateralRate,bool available);
    // Returns: total assets, total liabilities
    function pcvAssetsAndDebt(address pcv) external view returns(uint256,uint256);
}

// ====== S6 END

contract PCVinS6 is IERC20{

    uint256 private _totalSupply;
    string private _name = "DP PCV TOKEN";
    string private _symbol = "DPPCV";
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public settleAsset;
    uint public minInvest;
    uint public maxInvest;
    address public owner;
    bool public stopInvest = false;
    IPcvStorage public pcvStorage;

    address public rewardsAccount;
    uint public highestNetworth = 1e18;
    uint _basePercent = 1e4;
    IPcvRewardPool public rewardPool;
    
    constructor(address _pcvStorage,address _settleAsset,address _rewardsAccount,address _rewardPool){
        pcvStorage = IPcvStorage(_pcvStorage);
        settleAsset = _settleAsset;        
        rewardsAccount =_rewardsAccount;
        owner = msg.sender;
        rewardPool = IPcvRewardPool(_rewardPool);
    }

    event executeEvent(uint256 strategyId, uint256 amount);
    event InvestEvent(address indexed storageContract,address indexed pcv,uint InvestAmount,uint pcvShares,uint netWorth);
    event RedeemEvent(address indexed storageContract,address indexed pcv,uint redeemAmount,uint pcvShares,uint netWorth);

    modifier pcvAvailable(){
        PcvStruct.PcvInfo memory info = pcvStorage.getPcvInfo(address(this));
        require(info.available,"PCV unavailable");
        _;
    }

    // === about reward start ===

    function setRewarAccount(address newAccount) external onlyOwner{
        rewardsAccount = newAccount;
    }

    function _newNetworthAndSupply() internal view returns(uint newNetworth,uint newTotalSupply,uint netAssets){
        (uint _netAssets,, uint _networth) = ISettlement(_settlement()).netAssetValue(address(this));
        netAssets = netAssets * 1e18 / Hcommon.getPriceByUsd(settleAsset) / 10 ** (18 - IERC20Extra(settleAsset).decimals()); //  / 10 ** (18 - IERC20Extra(tokenA).decimals()); // 转换成计价币种精度

        if(_networth <= highestNetworth || rewardsAccount == address(0)) {
            newNetworth = _networth;
            newTotalSupply = _totalSupply;
            return(newNetworth,newTotalSupply,_netAssets);
            }
        newNetworth =  _networth - (_networth-highestNetworth) * 2000 / _basePercent;
        newTotalSupply = _netAssets * 1e18 / newNetworth;
        netAssets = _netAssets;
    }

    function newNetworthAndSupply() public view returns(uint newNetworth,uint newTotalSupply){
       (newNetworth,newTotalSupply,) = _newNetworthAndSupply();
    }

    function incrReward() public view returns(uint shares){
        if(rewardsAccount == address(0)){
            return 0;
        }
        (,uint newTotalSupply,) = _newNetworthAndSupply();
        shares = newTotalSupply - _totalSupply;
    }

    function updateReward() external{
        _updateReward();
    }

    function _updateReward() internal returns(uint networth){
         (uint _networth,uint newTotalSupply,) = _newNetworthAndSupply();
         if(rewardsAccount == address(0)){return _networth;}

         if(newTotalSupply > _totalSupply){
             uint incrShares = newTotalSupply - _totalSupply;
             _mint(address(rewardPool),incrShares);
             rewardPool.updateReward(address(this),incrShares);
         }
         if(_networth > highestNetworth){
             highestNetworth = _networth;
         } 
        networth = _networth;
    }

    // === about reward end ===


    function invest(uint256 amount) external payable pcvAvailable{
        require(amount <= maxInvest && amount >= minInvest,"Investment exceeds the limit");
        address _settleAsset = settleAsset;
        bool ismatic = _isMatic(_settleAsset);
        
        // fetch pcvToken value, calculate how many pcvToken can be exchanged
        uint networth = _updateReward();
    
        uint worthDecimal = networthDecimals();
        uint8 worthDiff = networthDecimals() - IERC20Extra(_settleAsset).decimals();
        uint shares = amount * 10 ** (worthDecimal + worthDiff) / networth; // shareDecimals == worthDecimals
        
        if(ismatic){
            IWMATIC(payable(_wmatic())).deposit{value:amount}();
            _settleAsset = _wmatic();
        }else{
             bool transRes = IERC20(_settleAsset).transferFrom(msg.sender,address(this), amount);
             require(transRes,"Invest failed");
        }
        
        _mint(msg.sender,shares);

        investControl(_settleAsset,positionToken() ,amount);
        require(_canUseFund(),"Fail by utilization");

        emit InvestEvent(address(pcvStorage),address(this),amount,shares,networth);
    }

    function redeem(uint256 amount) external payable{
        uint256 balance = balanceOf(msg.sender);
        require(balance >= amount,"not enough balance to redeem");
        
        uint networth = _updateReward();

        address _settleAsset = settleAsset; // save gas
        uint8 decimal = pcvShareDecimals() + networthDecimals() - IERC20Extra(_settleAsset).decimals();
        uint256 redeemAmount = amount * networth / 10 ** decimal;

        withdrawControl(_settleAsset,positionToken(),redeemAmount);

        uint256 pcvBalance = IERC20(_settleAsset).balanceOf(address(this));
        require(pcvBalance >= redeemAmount,"PCV has not enough asset to do redeem");

        _burn(msg.sender,amount);
        if(_isMatic(_settleAsset)){
            IWMATIC(_settleAsset).withdraw(redeemAmount);
            payable(msg.sender).transfer(redeemAmount);
        }else{
            IERC20(_settleAsset).transfer(msg.sender, redeemAmount);
        }
        require(_canUseFund(),"Fail by utilization");
        emit RedeemEvent(address(pcvStorage),address(this),redeemAmount,amount,networth);
    }

    function getSettleAsset() public view returns(address){
        return settleAsset;
    }

    function _isMatic(address token) internal pure returns(bool){
        bool isMatic = (token == 0x0000000000000000000000000000000000001010 ||
         token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE );
        return isMatic;
    }

    function _paramError(string memory param) internal pure returns(string memory ){
        return string(abi.encodePacked("parameters error: ", param));
    }

    function _wmatic() internal pure returns(address){
        return 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    }

    function _settlement() internal view returns(address){
        return pcvStorage.settlement();
    }

    function addAssetsWhiteList(address[] memory newTokens) public onlyOwner{
        uint len = newTokens.length;
        for(uint i = 0;i< len;i++ ){
            require(newTokens[i] != address(0),"Asset cannot be address 0 ");
        }
        pcvStorage.recordPcvAssets(newTokens);
    }

    function setInvestLimit(uint _minInvest,uint _maxInvest) external onlyOwner{
        require(minInvest <= maxInvest,"data error");
        minInvest = _minInvest;
        maxInvest = _maxInvest;
    }

    // liquidate preprocess
    function preLiquidate(address token,uint amount) external returns(bool res){
        require(msg.sender == pcvStorage.liquidator(),"caller is not liquidator");
       res = IERC20(token).approve(msg.sender,amount);
    }

    function pcvShareDecimals() private pure returns(uint8){
            return 18;
    }

    function networthDecimals() private pure returns(uint8){
            return 18;
    }

    function _canUseFund() internal view returns(bool) {
        address ctr = pcvStorage.comptroller();
        return Comptroller(ctr).canUsePcvFund(address(this));
    }


// ========== S6 Strategy =========

    // Balance Position Variable
    struct BalancePosition{
        uint posLP;
        int pos;
        uint posFromLp;
        address LpToken;
        address inToken;
        address outToken;
        bool isPosLow;
        bool isInvest;
        uint investAmount;
    }

    function withdrawControl(address withdrawToken,address otherToken,uint withdrawAmount) internal {
        balancePosition(withdrawToken,false,0);
        balanceUtilization( withdrawToken, otherToken, withdrawAmount,false);

        bool borrowRes = _borrowIfNotEnough(withdrawToken,withdrawAmount);
        require(borrowRes,"Borrow fail");
    }

    function investControl(address investToken,address otherToken,uint investAmount) internal { 
         balancePosition(investToken,true,investAmount);
         balanceUtilization(investToken, otherToken, investAmount,true);
    }

    // @param standardToken Denominated currency
    function balancePosition(address priceToken,bool isInvest,uint investAmount) internal {
        address posToken = positionToken();
        address hSwap = Hcommon.hQuickswap();
        uint debtAmount = IHDpLend(Hcommon.hDpLend()).borrowedAmount(posToken,address(this));
        address LpToken = IHQuickSwap(hSwap).getPair(posToken,priceToken);

        _claimedReward(LpToken);

        uint posLP = _getAllLP(LpToken);
        uint posFromLp = 0;
        if(posLP > 0){
        (address token0,,uint amount0,uint amount1) = IHQuickSwap(hSwap).getReserves(LpToken,posLP);
         posFromLp = token0 == posToken ? amount0 : amount1; 
        }
        uint oldBalance = Hcommon.getBalance(posToken,address(this));
        int pos = int(posFromLp + oldBalance) - int(debtAmount);
        if(pos == 0 ) return;
        if(pos > 0 ){
             // reduce position
            BalancePosition memory balancePos = BalancePosition({
             posLP:posLP,
             pos:pos,
             posFromLp:posFromLp,
             LpToken:LpToken,
             inToken:posToken,
             outToken:priceToken,
             isPosLow:false,
             isInvest:isInvest,
             investAmount:investAmount});
           _balancePosition(balancePos);
        }else{
            // increase position
            BalancePosition memory balancePos = BalancePosition({
             posLP:posLP,
             pos:pos,
             posFromLp:posFromLp,
             LpToken:LpToken,
             inToken: priceToken,
             outToken:posToken,
             isPosLow:true,
             isInvest:isInvest,
             investAmount:investAmount});
           _balancePosition(balancePos);
        }
        _repay(priceToken);
        _repay(posToken);
    }

    function _balancePosition(BalancePosition memory balancePos) internal {
          if(balancePos.posFromLp > 0){
              // Calculate the amount of removeLp according to the LP:wamtic ratio
              uint removeLp = balancePos.isPosLow 
              ? balancePos.posLP * uint(balancePos.pos * -1) / balancePos.posFromLp
              : balancePos.posLP * uint(balancePos.pos) / balancePos.posFromLp;
              _removeLiquidity(balancePos.LpToken, removeLp);
          }

        uint swapAmount = Hcommon.getBalance(balancePos.inToken,address(this));
        if(balancePos.isInvest && balancePos.inToken == getSettleAsset()){
            swapAmount -= balancePos.investAmount;
        }
        if(swapAmount == 0){
            return;
        }
        IERC20(balancePos.inToken).transfer(Hcommon.hQuickswap(),swapAmount);
        IHQuickSwap(Hcommon.hQuickswap()).swapTokens(balancePos.inToken,balancePos.outToken,swapAmount); 
    }

    // Balance capital utilization by operating LP tokens
    function balanceUtilization(address tokenA,address tokenB,uint amountOftokenA,bool isAddAmount) internal {
        address wrappedSwap = Hcommon.hQuickswap();
        address LpToken = IHQuickSwap(wrappedSwap).getPair(tokenA,tokenB);
        (uint netAssets,,)= ISettlement(_settlement()).netAssetValue(address(this));
        netAssets = netAssets * 1e18 / Hcommon.getPriceByUsd(tokenA) / 10 ** (18 - IERC20Extra(tokenA).decimals()); //Convert to Invoice Currency Precision
        uint allLpValue = getAllLpValue(LpToken, tokenA); 

        uint LpPledgeRate = pledgeRate(LpToken);
        uint denominator = isAddAmount ?  netAssets : (netAssets - amountOftokenA);
        int withdrawLpValue = int(denominator * 1e18 / (1e18 - LpPledgeRate * Hcommon.riskRate() / 1e18)) - int(allLpValue);
        if(withdrawLpValue > 0){

        require(addLiquidity(tokenA,tokenB,uint(withdrawLpValue)),"BalanceUtilization:Add Liquidity fail");

        }else if(withdrawLpValue < 0){
            uint uintLpValue = uint(withdrawLpValue * -1);
            uint LpPrice = Hcommon.getPrice(LpToken,tokenA);
            uint8 tokenADecimals = IERC20Extra(tokenA).decimals();
            uint8 LpDecimals = IERC20Extra(LpToken).decimals();
            uint withdrawLpAmount =  uintLpValue * 10 ** (tokenADecimals+LpDecimals-tokenADecimals)  / LpPrice;
            require(removeLiquidityAndRepay(LpToken,withdrawLpAmount),"BalanceUtilization:Remove liquidity fail");
     }
    }

    function getAllLpValue(address LpToken,address standardToken) public view returns(uint allLpValue){
        uint LpTokenBalance = _getAllLP(LpToken);
        uint LpPrice = Hcommon.getPrice(LpToken,standardToken);
        uint8 LpDecimals = IERC20Extra(LpToken).decimals();
         allLpValue = LpTokenBalance * LpPrice / 10 ** LpDecimals; 
    }

    function getAllLP(address LP) public view returns(uint allLP){
        allLP = _getAllLP(LP);
    }

    function _getAllLP(address LP) internal view returns(uint allLP){
        allLP = Hcommon.getBalance(LP,address(this)) + IHQuickStaking(Hcommon.hQuickStaking()).balanceOf(LP,address(this));
    }

    function addLiquidity(address token0,address token1,uint valueOfToken0) public returns(bool){

            uint token1Price = Hcommon.getPrice(token1,token0);

            uint amount0 = valueOfToken0/2;
            uint amount1 = valueOfToken0 * 10 ** IERC20Extra(token0).decimals()/2/token1Price;

            amount1 = Hcommon.changeDecimals(token0,token1,amount1);

            bool borrowRes = _borrowIfNotEnough(token0, amount0) && _borrowIfNotEnough(token1, amount1);

            if(!borrowRes){
                return false;
            }
            address LpToken = IHQuickSwap(Hcommon.hQuickswap()).getPair(token0,token1);
            uint lpBalance = IERC20(LpToken).balanceOf(address(this));

            address hswap = Hcommon.hQuickswap();
            IERC20(token0).transfer(hswap,amount0);
            IERC20(token1).transfer(hswap,amount1);

            IHQuickSwap(hswap).addLiquidity(token0,token1,amount0,amount1);

            uint newLpBalance = Hcommon.getBalance(LpToken,address(this));

            require(newLpBalance > lpBalance,"addLiquidity fail");

            //  staking reward
           (bool stakeRes,) = Hcommon.hQuickStaking().delegatecall(abi.encodeWithSignature("stake(address,uint256)", LpToken,newLpBalance));
           require(stakeRes,"staking reward fail");
            return true;
    }

    function _borrowIfNotEnough(address token,uint amount) internal returns(bool){
        uint balance = IERC20(token).balanceOf(address(this));
        if(balance >= amount){ return true;}

          (bool bRes,) = Hcommon.hDpLend().delegatecall(
                 abi.encodeWithSignature("borrow(address,uint256)",
                 token,amount-balance)
                 );
                 uint newBalance = Hcommon.getBalance(token,address(this));
                 if(!bRes ||  newBalance == balance){ return false;}
                 return true;
    }

    function _removeLiquidity(address LpToken,uint removeAmount) internal returns(bool){        
        if(removeAmount == 0){return true;}
        uint balance = Hcommon.getBalance(LpToken,address(this));
        if(removeAmount > balance){
           uint unstakeAmount = removeAmount - balance;
           _unstake(LpToken,unstakeAmount);
           _claimedReward(LpToken);
        }

        IERC20(LpToken).transfer(Hcommon.hQuickswap(),removeAmount);
        IHQuickSwap(Hcommon.hQuickswap()).removeLiquidity(LpToken,removeAmount);
        return true;
    }

    function removeLiquidityAndRepay(address LpToken,uint withdrawAmount) public returns(bool){
        require(_removeLiquidity(LpToken, withdrawAmount),"remove liquidity fail");
        address token0 = IUniswapV2Pair(LpToken).token0();
        address token1 = IUniswapV2Pair(LpToken).token1();
        bool repayRes0 = _repay(token0);
        bool repayRes1 = _repay(token1);
       require(repayRes0 && repayRes1,"Repay fail");
       return true;
    }

    function _repay(address token) internal returns(bool){
        uint balance = IERC20(token).balanceOf(address(this));
        if(balance == 0){
            return true;
        }
        bytes memory repayCallData = abi.encodeWithSelector(IHDpLend.repayBorrow.selector,token,balance);
        (bool repayRes,) = Hcommon.hDpLend().delegatecall(repayCallData);
        return repayRes == true ? true : false;
    }

    function _unstake(address LpToken , uint amount) internal {
        uint stakeBalance = IHQuickStaking(Hcommon.hQuickStaking()).balanceOf(LpToken,address(this));
        // if(stakeBalance < amount) revert NotenoughLPunstake(amount);
           require(stakeBalance >= amount,"not enough LP Token");
           bytes memory withdrawData = abi.encodeWithSelector(IHQuickStaking.withdraw.selector,LpToken,amount);
            (bool unstakeRes,) = Hcommon.hQuickStaking().delegatecall(withdrawData);
            require(unstakeRes,"withdraw staking fail");
    }

    bool public transDquick = true;
    function DquickAutoToUsdc(bool autoTrans) public {
        require(msg.sender == owner,"caller is not owner");
        transDquick = autoTrans;
    }

    function _claimedReward(address LpToken) internal {
        bytes memory claimedData = abi.encodeWithSelector(IHQuickStaking.claimedReward.selector,LpToken);
            (bool claimedRes,) = Hcommon.hQuickStaking().delegatecall(claimedData);
            require(claimedRes,"claimed reward fail");
            if(transDquick){
                dQuickToUsdc();
            }
    }

    function dQuickToUsdc() public {
        IHQuickSwap hQuickSwap = IHQuickSwap(Hcommon.hQuickswap());
        address dquick = hQuickSwap.dQuick();
        uint dQuickBalance = IERC20(dquick).balanceOf(address(this));
        if(dQuickBalance == 0){return;}
        IERC20(dquick).transfer(address(hQuickSwap),dQuickBalance);
        hQuickSwap.dQuickToUsdc();
    }

    function pledgeRate(address token) internal view returns(uint _pledgeRate){
      (,,,_pledgeRate,) =  ISettlement(_settlement()).tokenConfig(token);
    }

    function positionToken() internal pure returns(address){
        return 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; // wmatic
    }

    function getPosition() public view returns(int pos){

        address posToken = positionToken();
        address hSwap = Hcommon.hQuickswap();
        uint debtAmount = IHDpLend(Hcommon.hDpLend()).borrowedAmount(posToken,address(this));
        address LpToken = IHQuickSwap(hSwap).getPair(posToken,settleAsset);

       (address rewardsA,address rewardsB) = IHQuickStaking(Hcommon.hQuickStaking()).rewardsToken(LpToken);
        (uint rewardsPos,) = posToken == rewardsA ? IHQuickStaking(Hcommon.hQuickStaking()).earnedRewards(address(this),LpToken) : (0,0);
        (,rewardsPos) = posToken == rewardsB ? IHQuickStaking(Hcommon.hQuickStaking()).earnedRewards(address(this),LpToken): (0,0);

        uint posLP = _getAllLP(LpToken);
        uint posFromLp = 0;
        if(posLP > 0){
        (address token0,,uint amount0,uint amount1) = IHQuickSwap(hSwap).getReserves(LpToken,posLP);
         posFromLp = token0 == posToken ? amount0 : amount1; 
        }
        uint oldBalance = Hcommon.getBalance(posToken,address(this));
        pos = int(posFromLp + oldBalance + rewardsPos) - int(debtAmount);
    }

    // ========= S6 END


// === about ERC20 token ===
 /**
     * @dev Returns the name of the token.
     */
    function name() public view returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public pure returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address _owner, address spender) public view virtual override returns (uint256) {
        return _allowances[_owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _balances[to] += amount;

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address _owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(_owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[_owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        address _owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(_owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(_owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    function _msgSender() internal view returns(address){
        return msg.sender;
    }

    modifier onlyOwner(){
        require(msg.sender == owner,"caller is not owner");
        _;
    }

    // about token end ===

}



