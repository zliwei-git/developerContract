// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "../interfaces/IERC20.sol";

// QUICKSWAP dual mining
interface IStakingDualRewards{
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function exit() external ; // withdraw and getReward
    function getReward() external;
    function balanceOf(address account) external view returns (uint256);
    function stakingToken() external view returns(address);
}

// Quickswap Double mining package contract
// @dev Which LP-TOKEN mining needs to be supported, please initialize the configuration in the method poolConfig
contract HQuickDualStakingReward{

    constructor(){
        checkPoolConfig();
    }

    mapping(address => uint256) public pcvStaked;

    function stake(address lpToken,uint amount) external {
        uint balance = _LpBalance(lpToken);
        address pool = getPoolByLpToken(lpToken);
        if(pool == address(0)) return;

        IERC20(lpToken).approve(pool,amount);
        IStakingDualRewards(pool).stake(amount);
        require(balance > _LpBalance(lpToken),"StakingReward : stake failed");
    }

    function withdraw(address lpToken,uint amount) external {
        uint balance = _LpBalance(lpToken);
        address pool = getPoolByLpToken(lpToken);
        if(pool == address(0) || balanceOf(lpToken,address(this)) == 0){
            return;
        }
        IStakingDualRewards(pool).withdraw(amount);
        require(balance < _LpBalance(lpToken),"StakingReward : withdraw failed");
    }

    function withdrawAll(address lpToken) external {
        uint balance = _LpBalance(lpToken);
        address pool = getPoolByLpToken(lpToken);
        if(pool == address(0) || balanceOf(lpToken,address(this)) == 0){
            return;
        }
        IStakingDualRewards(pool).exit();
        require(balance < _LpBalance(lpToken),"StakingReward : withdraw failed");
    }

    function claimedReward(address lpToken) external{
        address pool = getPoolByLpToken(lpToken);
        if(pool == address(0)){
            return;
        }
        IStakingDualRewards(pool).getReward();
    }
 
    function balanceOf(address lpToken,address account) public view returns(uint){
         address pool = getPoolByLpToken(lpToken);
        if(pool == address(0)){
            return 0;
        }
        return IStakingDualRewards(pool).balanceOf(account);
    }

    function getPoolByLpToken(address lpToken) public pure returns(address pool) {
        (address [] memory pools,address [] memory lpTokens) = poolConfig();
        uint i = 0;
        while(i < lpTokens.length){
            if(lpTokens[i] == lpToken){
                pool = pools[i];
                break;
            }
        }
    }

    // Deploy contract to initialize POOL configuration
    function poolConfig() internal pure returns(address[] memory pools,address [] memory lpTokens){
        pools  = new address[](1);
        lpTokens = new address[](1);
        // USDC-WMATIC :0x6e7a5FAFcec6BB1e78bAE2A1F0B612012BF14827
        // pool(USDC-WMATIC): 0x14977e7e263ff79c4c3159f497d9551fbe769625
        pools[0] = 0x14977e7E263FF79c4c3159F497D9551fbE769625;
        lpTokens[0] = 0x6e7a5FAFcec6BB1e78bAE2A1F0B612012BF14827;
    }

    // Check whether the staking pool and lpToken in the configuration are correct
    function checkPoolConfig() private view{
        (address [] memory pools,address [] memory lpTokens) = poolConfig();
        for(uint i = 0; i < pools.length;i++){
            require(pools[i] != address(0) && lpTokens[i] != address(0),"Invalid pool config");
            require(IStakingDualRewards(pools[i]).stakingToken() == lpTokens[i],"Invalid pool config");
        }
    }

    function _LpBalance(address lpToken) internal view returns(uint){
        return IERC20(lpToken).balanceOf(address(this));
    }

}