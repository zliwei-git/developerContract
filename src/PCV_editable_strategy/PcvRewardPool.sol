// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./libraries/Errors.sol";

interface IPcvStorage{
    function pcvIsExsit(address pcv) external view returns(bool);
}

interface IPCV{
    function rewardsAccount() external view returns(address);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function incrReward() external view returns(uint256);
    function updateReward() external;

}

contract PcvRewardPool{

    IPcvStorage public pcvStorage ;

    struct Reward{
        uint rewardSnapshot;
        uint received;
    }

    mapping(address => Reward) public pcvReward;

     constructor(address _pcvStorage){
        pcvStorage = IPcvStorage(_pcvStorage); 
    }

    event claimedReward(address indexed pcvStorage,address pcv,uint receivedAmount);
    
    function claimReward(address PCV) external {
        require(_isPcvRewardAccount(PCV,msg.sender),Errors.PCV_IS_NOT_OWNER);
        IPCV(PCV).updateReward();
        Reward storage reward = pcvReward[PCV];
        require(reward.rewardSnapshot > reward.received,Errors.NO_REWARD_TO_CLAIM);
        uint receiveAmount = reward.rewardSnapshot - reward.received;
        reward.received += receiveAmount;
        IPCV(PCV).transfer(msg.sender,receiveAmount);
        emit claimedReward(address(pcvStorage),PCV,receiveAmount);
    }

    function updateReward(address PCV,uint amount) external isPcv{
            Reward storage reward = pcvReward[PCV];
            reward.rewardSnapshot += amount; 
    }

    modifier isPcv(){
        require(pcvStorage.pcvIsExsit(msg.sender),Errors.PCV_NOT_EXIST);
        _;
    }

    function _isPcvRewardAccount(address PCV,address account) internal view returns(bool){
        return account == IPCV(PCV).rewardsAccount();
    }

    function currentReward(address PCV) public view returns(uint totalReward,uint received,uint notYetReceived){
        uint incrReward = IPCV(PCV).incrReward();
        totalReward = pcvReward[PCV].rewardSnapshot + incrReward;
        received = pcvReward[PCV].received;
        notYetReceived = totalReward - received;
    }
}