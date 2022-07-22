// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "../openzeppelin/Ownable.sol";
import {IPcvStorage} from "./interfaces/IPcvStorage.sol";

interface IPcvCodeProvider{
    function getCode() external view returns(bytes memory );
    function createPcv(address pcvStorage,address pcvOwner, address settleAsset,uint minInvest,uint maxInvest) external returns(address);
}

contract PcvFactory is Ownable{
    IPcvStorage public pcvStorage;
    uint public version;
    address public pcvProvider;

    constructor(address storageContract,address codeProvider){
        pcvStorage = IPcvStorage(storageContract);
        pcvProvider = codeProvider;
    }

//    build a new Pcv
    function buildPcvProxy(address settleAsset,uint256 minInvest,uint256 maxInvest) external returns(address pcv){
        require(minInvest <= maxInvest," minInvest and maxInvest error");
        require(settleAsset != address(0),"pcvOwner and settleAsset error");
        pcv = _createAccount(msg.sender,settleAsset,minInvest,maxInvest);
        emit buildPCVproxy(msg.sender,pcv);
    }
    event buildPCVproxy(address indexed pcvOwner,address indexed pcv);

    function _storePcv(address pcvOwner,address pcv,address settleAsset,uint256 minInvest,uint256 maxInvest) internal {
        pcvStorage.addPcv(pcvOwner,pcv,settleAsset,minInvest,maxInvest,version);
    }

    function updatePcvProvider(address newPcvProvider) public onlyOwner{
        pcvProvider = newPcvProvider;
        version += 1;
    }

    function _createAccount(address _owner,address settleAsset, uint minInvest,uint maxInvest) internal returns(address pcvAddr)
    {
        pcvAddr = IPcvCodeProvider(pcvProvider).createPcv(address(pcvStorage),_owner,settleAsset,minInvest,maxInvest);
        _storePcv(_owner,pcvAddr,settleAsset, minInvest,maxInvest);
    }

    function setStore(address _pcvStorage) external onlyOwner {
        address oldStore = address(pcvStorage);
        pcvStorage = IPcvStorage(_pcvStorage);
        emit _setStore(oldStore,_pcvStorage);
    }
    event _setStore(address,address);
    
    function storePcvInfo(address pcvOwner,address pcv,address settleAsset,uint256 minInvest,uint256 maxInvest) public onlyOwner {
       pcvStorage.addPcv(pcvOwner,pcv,settleAsset,minInvest,maxInvest,0);
    }
}
