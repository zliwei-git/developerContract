// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IPcvStorage.sol";
import "../openzeppelin/Ownable.sol";
import "./interfaces/IERC20Extra.sol";
import "./libraries/PcvStruct.sol";
import "./interfaces/IHQuickSwap.sol";
import "./subaction/Hcommon.sol";
import "./interfaces/IHAaveV2.sol";
import "./libraries/Errors.sol";
import "./interfaces/ICreditDelegationToken.sol";

interface IWMATIC {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function decimals() external view returns(uint8);
}

interface Comptroller{
    // PCV fund utilization counting, for the purpose of judge the availability of the fund
    function canUsePcvFund(address account) external view returns (bool) ;
}

// settlement contract
interface ISettlement{
    // params (PCV Address, total shares) 
    // return netWorth.decimals = 18
    function netAssetValue(address pcv) external view returns (uint netAssets, uint totalDebt, uint netWorth);
}

contract PcvProxy is IERC20{

// ===============
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    uint public minInvest;
    uint public maxInvest;
    address public owner;
    bool public stopInvest = false;
// ===============

    IPcvStorage public pcvStorage;
    address public settleAsset;
    uint _percentBase = 1e4;

    //strategyId => strategy
    mapping(uint => PcvStruct.Strategy) public strategys;
    uint strategyIdCount = 0;
    uint public investStrategyId = 0;
    uint public redeemStrategyId = 0;

    IHAaveV2 hAave = IHAaveV2(Hcommon.hAaveV2());
    IHQuickSwap hSwap = IHQuickSwap(Hcommon.hQuickswap());

    enum StrategyType{
        INVEST,
        REDEEM
    }

    constructor(address _pcvStorage,address _owner,address _settleAsset,uint _minInvest,uint _maxInvest){
        pcvStorage = IPcvStorage(_pcvStorage);
        _name = "DP PCV TOKEN";
        _symbol = "DPPCV";
        settleAsset = _settleAsset;
        minInvest = _minInvest;
        maxInvest = _maxInvest;
        owner = _owner;
    }

    event InvestEvent(address indexed storageContract,address indexed pcv,uint InvestAmount,uint pcvShares,uint netWorth);
    event RedeemEvent(address indexed storageContract,address indexed pcv,uint redeemAmount,uint pcvShares,uint netWorth);
    event addStrategyEvent(address indexed storageContract,address indexed pcv,uint strategyId);
    event InvestStrategy(address indexed pcvStorage,address indexed pcv,uint strategyId);
    event RedeemStrategy(address indexed pcvStorage,address indexed pcv,uint strategyId);
    event investLimit(address indexed pcvStorage,address indexed pcv,uint min,uint max);

    function addStrategy(
        StrategyType strategytype,
        uint[] memory protocolNum,
        uint[] memory methodNum,
        address[][] memory inputTokens,
        address[][] memory outputTokens,
        uint[][] memory inputPercent
    ) external onlyOwner{
        uint len = protocolNum.length;
        require(len > 0,Errors.SG_INVALID_METHOD_LENGTH);
        require(len == methodNum.length,Errors.SG_INVALID_METHOD_LENGTH);
        require(len <= 20,Errors.SG_OPERATIONS_OUT_OF_RANGE);
        require(_checkToken(len,inputTokens,outputTokens),Errors.SG_TOKEN_NOT_SUPPROT);
        require(_checkProtocol(protocolNum,methodNum),Errors.SG_PROTOCOL_NOT_SUPPORT);
        // require(_checkInputPercentage(inputPercent),Errors.SG_PERCENTAGE_OUT_OF_LIMIT);

        uint newId = strategyIdCount + 1;
        PcvStruct.Strategy memory stgy = PcvStruct.Strategy({
            strategyId:newId,
            protocolNum:protocolNum,
            methodNum:methodNum,
            inputTokens:inputTokens,
            outputTokens:outputTokens,
            inputPercent:inputPercent,
            available:true
            });
        strategys[newId] = stgy;
        strategyIdCount = newId;
        if(strategytype == StrategyType.INVEST){
            _setInvestStrategy(newId);
        }else{
            _setRedeemStrategy(newId);
        }
        
        emit addStrategyEvent(address(pcvStorage),address(this),newId);
    }

    function _checkInputPercentage(uint[][] memory inputPercentage) internal view returns(bool isPass){
         isPass = true;
        uint percentBase = _percentBase;
        uint len = inputPercentage.length;
        for(uint i = 0; i < len;i++){
            for(uint j = 0; j < inputPercentage[i].length;j++){
                if(inputPercentage[i][j] > percentBase){
                    isPass = false;
                    break;
                } 
            }
            if(!isPass) break;
        }
    }

    function _checkProtocol(uint[] memory protocolNum,uint[] memory methodNum) internal view returns(bool){
        (bool support,,) = pcvStorage.checkProtocols(protocolNum,methodNum);
        return support;
    }

    function _checkToken(uint length,address[][] memory inTokens,address[][] memory outTokens) internal view returns(bool support) {
        uint allOutTokens = 0;
        for(uint s = 0; s < inTokens.length;s++){
            allOutTokens += inTokens[s].length;
        }

        for(uint s = 0; s < outTokens.length;s++){
            allOutTokens += outTokens[s].length;
        }

        address [] memory allTokens = new address[](allOutTokens);
        uint idx = 0;
        for(uint p = 0 ; p < length;p++){
            for(uint i = 0; i< inTokens[p].length;i++){
                allTokens[idx] = inTokens[p][i];
                idx ++;
            }
            for(uint o = 0; o < outTokens[p].length;o++){
                allTokens[idx] = outTokens[p][o];
                idx ++;
            }
        }
        support = pcvStorage.isAllSupportAssets(allTokens);
    }

    modifier onlyOwner(){
        require(msg.sender == owner,"Caller is not owner");
        _;
    }

    function invest(uint256 amount) external payable {
        require(amount <= maxInvest && amount >= minInvest,"Investment exceeds the limit");
        bool ismatic = _isMatic(settleAsset);

        (,, uint networth) = ISettlement(_settlement()).netAssetValue(address(this));

        // mint pcvToken
        uint8 decimal = IERC20Extra(settleAsset).decimals();
        uint worthDecimal = networthDecimals();
   
        uint shares = amount * 10 ** (worthDecimal + worthDecimal - decimal) / networth; // shareDecimals == worthDecimals

        if(ismatic){
            IWMATIC(payable(_wmatic())).deposit{value:amount}();
            settleAsset = _wmatic();
        }else{
             bool transRes = IERC20(settleAsset).transferFrom(msg.sender,address(this), amount);
             require(transRes,"Invest failed");
        }
         _mint(msg.sender,shares);

        if(investStrategyId > 0){
            investControl(amount);
        }

        emit InvestEvent(address(pcvStorage),address(this),amount,shares,networth);
    }

    function redeem(uint256 amount) external payable{
        uint256 balance = balanceOf(msg.sender);
        require(balance >= amount,"not enough balance to redeem");

        (,, uint netWorth) = ISettlement(pcvStorage.settlement()).netAssetValue(address(this));

        uint8 decimal = pcvShareDecimals() + networthDecimals() - IERC20Extra(settleAsset).decimals();
        uint256 redeemAmount = amount * netWorth / 10 ** decimal;

        if(redeemStrategyId > 0){
            redeemControl(redeemAmount);
        }

        uint256 pcvBalance = IERC20(settleAsset).balanceOf(address(this));
        require(pcvBalance >= redeemAmount,"PCV has not enough asset to do redeem");

        _burn(msg.sender,amount);

        if(_isMatic(settleAsset)){
            IWMATIC(settleAsset).withdraw(redeemAmount);
            payable(msg.sender).transfer(redeemAmount);
        }else{
            IERC20(settleAsset).transfer(msg.sender, redeemAmount);
        }
        emit RedeemEvent(address(pcvStorage),address(this),redeemAmount,amount,netWorth);
    }

    function investStop(bool stop) public onlyOwner{
        stopInvest = stop;
    }
    
    function investControl(uint amount) internal{
        _execStrategy(investStrategyId,amount);
    }

    function redeemControl(uint256 redeemAmount) internal{
        _execStrategy(redeemStrategyId,redeemAmount);
    }

    function _execStrategy(uint strategyId,uint amount) internal {
        PcvStruct.Strategy memory stgy = strategys[strategyId];
        uint steps = stgy.protocolNum.length;
        for(uint i = 0; i < steps; i++){
            if(stgy.protocolNum[i] == 1){
                _execAave(stgy,i,amount);
            }
            if(stgy.protocolNum[i] == 2){   
                _execQuickswap(stgy,i,amount);
            }
        }
    }

    // 0 deposit,1 withdraw, 2 borrow, 3 repay
    function _execAave(PcvStruct.Strategy memory stgy,uint step,uint amount) internal {
        uint methodNum = stgy.methodNum[step];
        address asset = stgy.inputTokens[step][0];
        uint percent = stgy.inputPercent[step][0];
        // IHAaveV2 aave = IHAaveV2(Hcommon.hAaveV2());
 
        if(methodNum == 0){
            uint inAmount =  amount * percent / _percentBase;
            inAmount = valueTransfer(asset,inAmount);
            _deposit(asset,inAmount);
            return;
        }
        // withdraw
        if(methodNum == 1){
            uint inAmount = amount * percent / _percentBase; 
            inAmount = valueTransfer(asset, inAmount);
            _withdraw(asset,inAmount);
            return;
        }
        // borrow
        if(methodNum == 2){
            uint inAmount = amount * percent / _percentBase;
            inAmount = valueTransfer(asset, inAmount);
            _borrow(asset,inAmount);
            return;
        }
        // repay
        if(methodNum == 3){
            uint inAmount = amount * percent / _percentBase;
            _repay(asset,inAmount);
            return;
        }
    }

    function _execQuickswap(PcvStruct.Strategy memory stgy,uint step,uint amount) internal {
        uint methodNum = stgy.methodNum[step];
        uint percent = stgy.inputPercent[step][0];
         // swap
        if(methodNum == 0){
            address inAsset = stgy.inputTokens[step][0];
            address outAsset = stgy.outputTokens[step][0];
            uint inAmount = amount * percent / _percentBase;
            inAmount = valueTransfer(inAsset,inAmount);
            _swapTokens(inAsset,outAsset,inAmount);
            return;
        }
        // addLiquidity
        if(methodNum == 1){
            address token0 = stgy.inputTokens[step][0];
            address token1 = stgy.inputTokens[step][1];
            uint inAmount0 = amount * percent / _percentBase;
            inAmount0 = valueTransfer(token0,inAmount0);
            uint inAmount1 = amount * stgy.inputPercent[step][1] / _percentBase;
            inAmount1 = valueTransfer(token1,inAmount1);
            _addLiquidity(token0,token1,inAmount0,inAmount1);
            return;
        }
        // removeLiquidity
        if(methodNum == 2){
            address token0 = stgy.outputTokens[step][0];
            address token1 = stgy.outputTokens[step][1];
            address LpToken = IHQuickSwap(Hcommon.hQuickswap()).getPair(token0,token1);
            uint LpValue = amount * percent / _percentBase; 
            uint LpAmount = valueTransfer(LpToken,LpValue);
            _removeLiquidity(LpToken,LpAmount);
            return;
        }
    }

    function valueTransfer(address targetAsset,uint settleAssetAmount) internal view returns(uint targetAmount){
            address settle = settleAsset;
            if(targetAsset == settle){
                targetAmount = settleAssetAmount;
                return targetAmount;
            }
            uint targetPrice = Hcommon.getPrice(targetAsset,settle);
            uint8 targetDecimals = IERC20Extra(targetAsset).decimals();
            uint8  settleDecimals = IERC20Extra(settle).decimals();
            if(targetDecimals >= settleDecimals){
                targetAmount = (settleAssetAmount * 10 ** settleDecimals / targetPrice) * 10 ** (targetDecimals - settleDecimals);
            }else{
                targetAmount = (settleAssetAmount * 10 ** settleDecimals / targetPrice) / 10 ** (settleDecimals - targetDecimals);
            }
    }

    function getSettleAsset() public view returns(address){
        return settleAsset;
    }

    function _settleAssetDecimals() internal view returns(uint8){
        return IERC20Extra(settleAsset).decimals();
    }

    function _setInvestStrategy(uint strategyId) internal {
        // require(investStrategyId == 0 ,Errors.SG_ALREADY_EXIST);
        investStrategyId = strategyId;
        emit InvestStrategy(address(pcvStorage),address(this),strategyId);
    }

    function _setRedeemStrategy(uint strategyId) internal {
        // require(redeemStrategyId == 0 ,Errors.SG_ALREADY_EXIST);
        redeemStrategyId = strategyId;
        emit RedeemStrategy(address(pcvStorage),address(this),strategyId);
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

    function setInvestLimit(uint _minInvest,uint _maxInvest) external onlyOwner{
        require(minInvest <= maxInvest,"data error");
        minInvest = _minInvest;
        maxInvest = _maxInvest;
        emit investLimit(address(pcvStorage),address(this),_minInvest, _maxInvest);
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


   // hProtocol start ======

    // aave deposit
    function _deposit(address asset,uint amount) internal {
        IERC20(asset).transfer(Hcommon.hAaveV2(),amount);
        hAave.deposit(asset,amount);
    }

    // aave withdraw
    function _withdraw(address asset , uint amount) internal {
        address aToken = hAave.getAToken(asset);
        IERC20(aToken).transfer(address(hAave),amount);
        hAave.withdraw(asset,amount);
    }

     // aave borrow
    function _borrow(address asset,uint amount) internal {
        address debtToken = hAave.getDebtToken(asset);
        ICreditDelegationToken(debtToken).approveDelegation(address(hAave),amount);
        hAave.borrow(asset,amount);
    }

     // aave repay
    function _repay(address asset,uint amount) internal{
        uint balance = IERC20(asset).balanceOf(address(this));
        if(balance == 0) {return;}
        IERC20(asset).transfer(Hcommon.hAaveV2(),amount);
        hAave.repay(asset,amount);
    }

    // Add liquidity
    function _addLiquidity(address token0,address token1,uint amount0, uint amount1) internal {

            address LpToken = IHQuickSwap(Hcommon.hQuickswap()).getPair(token0,token1);
            uint lpBalance = IERC20(LpToken).balanceOf(address(this));

            IERC20(token0).transfer(address(hSwap),amount0);
            IERC20(token1).transfer(address(hSwap),amount1);

            IHQuickSwap(hSwap).addLiquidity(token0,token1,amount0,amount1);

            uint newLpBalance = Hcommon.getBalance(LpToken,address(this));

            require(newLpBalance > lpBalance,"addLiquidity fail");
    }

    // redemption liquidity
    function _removeLiquidity(address LpToken,uint removeAmount) internal returns(bool){  
        if(removeAmount == 0){return true;}
        require (Hcommon.getBalance(LpToken,address(this)) >= removeAmount,Errors.SWAP_NOT_ENOUGH_LP);
        IERC20(LpToken).transfer(address(hSwap),removeAmount);
        hSwap.removeLiquidity(LpToken,removeAmount);
        return true;
    }

    function _swapTokens(address inToken,address outToken,uint amountIn) internal {
        IERC20(inToken).transfer(Hcommon.hQuickswap(),amountIn);
        hSwap.swapTokens(inToken,outToken,amountIn); 
    }
   // hProtocol end ======


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
        require(owner != address(0), "ERC20: approve from the zero address");
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

    // about token end ===

    function getStrategyInfo(uint strategyId) public view returns(uint256 _strategyId,
        uint[] memory protocolNum,
        uint[] memory methodNum, 
        bool available,
        address[][] memory inputTokens,
        address[][] memory outputTokens,
        uint256[][] memory inputPercent){
          
        _strategyId =  strategys[strategyId].strategyId;
        available = strategys[strategyId].available;
        protocolNum = strategys[strategyId].protocolNum;
        methodNum = strategys[strategyId].methodNum;
        inputTokens = strategys[strategyId].inputTokens;
        outputTokens = strategys[strategyId].outputTokens;
        inputPercent = strategys[strategyId].inputPercent;
    }
}

