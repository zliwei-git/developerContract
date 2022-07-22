// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "../openzeppelin/Ownable.sol";
import "./libraries/PcvStruct.sol";

contract PcvStorage is Ownable{

    address public pcvFactory;

    address public settlement;  // settlement contract
    address public comptroller;  // comptroller contract

    // pcv => PcvInfo
    mapping (address => PcvStruct.PcvInfo) public pcvMap;
    //pcvOwner => (pcv => isExist)
    mapping (address => mapping (address => bool))  userPcvMap;

    mapping(address => bool) supportAssets;
    address[] supportAssetsList;

    // protocol number => mapping
    mapping(uint => PcvStruct.HProtocol) public hProtocols;
    uint public allProtocol = 0;

    // pcv => strategyId
    mapping(address => uint) public pcvStrategys;

    mapping(address => address[]) _pcvAssets;
    mapping(address => mapping(address => bool)) _pcvAssetsMap;

    event addPcvEvent(address indexed storageContract,address indexed pcvOwner, address indexed pcv);
    event addStrategyEvent(address indexed pcv,uint strategyId);
    event removeStrategyEvent(address indexed pcv,uint256);
    event removeSupportOperateEvent(address ,address,bytes); // (owner,protocol,method)
    event setPcvFactoryEvent(address,address); // (oldAddress ,newAddress)
    event stopPCVevent(address);
    event Approval(address indexed pcv ,address indexed owner, address indexed spender, uint256 value);
    event autoExecuteEvent(bool oldValue,bool newValue);
    event setAutoStrategyEvent(uint256 oldStrategy,uint256 newStrategy);
    event setCollect(address oldAccount ,address newAccount);

    function addPcv(address pcvOwner,address pcv,address settleAsset,uint256 minInvest,uint256 maxInvest,uint version) external onlyFactory{
        PcvStruct.PcvInfo memory newPcv = PcvStruct.PcvInfo({
        factory:_msgSender(),
        owner:pcvOwner,
        available:true,
        collectAccount:address(0),
        settleAsset:settleAsset,
        minInvest:minInvest,
        maxInvest:maxInvest,
        version:version
        });
        pcvMap[pcv] = newPcv;
        userPcvMap[pcvOwner][pcv] = true;
        _recordPcvAssets(pcv,supportAssetsList);
        emit addPcvEvent(address(this),pcvOwner,pcv);
    }

    function addPcv(address pcvOwner,address pcv,address settleAsset,address[] memory assetsList) external onlyOwner{
        PcvStruct.PcvInfo memory newPcv = PcvStruct.PcvInfo({
        factory:_msgSender(),
        owner:pcvOwner,
        available:true,
        collectAccount:address(0),
        settleAsset:settleAsset,
        minInvest:0,
        maxInvest:0,
        version:0
        });
        pcvMap[pcv] = newPcv;
        userPcvMap[pcvOwner][pcv] = true;
        _recordPcvAssets(pcv,assetsList);
        emit addPcvEvent(address(this),pcvOwner,pcv);
    }

    function removeStrategy(uint strategyId) external onlyPcv{
        pcvStrategys[msg.sender] = strategyId;
        emit addStrategyEvent(msg.sender,strategyId);
    }

    function getPcvInfo(address pcv) external view returns(PcvStruct.PcvInfo memory){
        return  pcvMap[pcv];
    }

    function setPcvFactory(address newPcvFactory)external onlyOwner{
        require(newPcvFactory != address(0),"parameters error");
        address oldAddress = pcvFactory;
        pcvFactory = newPcvFactory;
        emit setPcvFactoryEvent(oldAddress,newPcvFactory);
    }

    modifier onlyFactory(){
        require(_msgSender() == pcvFactory,"no permissions");
        _;
    }

    modifier onlyPcv(){
        address pcv = _msgSender();
        PcvStruct.PcvInfo memory info =  pcvMap[pcv];
        require(info.available == true,"no permissions");
        _;
    }

    function stopPCV(address pcv) external {
        PcvStruct.PcvInfo memory info = pcvMap[pcv];
        require(info.owner == _msgSender(),"no permissions ");
        info.available = false;
        userPcvMap[_msgSender()][pcv] = false;
        emit stopPCVevent(pcv);
    }

    function pcvIsExsit(address owner,address pcv) external view returns(bool){
        return userPcvMap[owner][pcv];
    }

    function pcvIsExsit(address pcv) external view returns(bool){
        PcvStruct.PcvInfo memory info = pcvMap[pcv];
        return info.available;
    }

    function getCollectAccount(address PCV) external view returns(address){
        PcvStruct.PcvInfo memory info = pcvMap[PCV];
        return info.collectAccount;
    }

    // set the contract address of the settlement contract
    function setSettlement(address settleContract) external{
        settlement = settleContract;
    }

    // get PCV position assets
    function getPcvAssets(address pcv) public view returns(address [] memory assets){
        assets = _pcvAssets[pcv];
    }

    function addSupportAssets(address[] memory assets) public onlyOwner{
        address asset;
        uint count = assets.length;
        for(uint i = 0; i < count;i++){
            asset = assets[i];
            if(!supportAssets[asset] && asset != address(0)){
                supportAssets[asset] = true;
                supportAssetsList.push(asset);
            }
        }
    }
    

    function removeAssets(address asset) public onlyOwner{
       require(supportAssets[asset],"Asset is not found");
       delete supportAssets[asset];
       uint count = supportAssetsList.length;
       for(uint i = 0 ; i< count;i++){
           if(supportAssetsList[i] == asset){
               supportAssetsList[i] = supportAssetsList[count - 1];
               supportAssetsList.pop();
               break;
           }
       }
    }

    function _recordPcvAssets(address pcv,address [] memory newAssets) internal{
       for(uint n = 0; n < newAssets.length;n++){
                if(_pcvAssetsMap[pcv][newAssets[n]]){
                    continue;
                }
                _pcvAssetsMap[pcv][newAssets[n]] = true;
                _pcvAssets[pcv].push(newAssets[n]);
       }
    }

    function recordPcvAssets(address pcv,address [] memory newAssets) external onlyPcv{
        _recordPcvAssets(pcv,newAssets);
    }

    function isAllSupportAssets(address [] memory assets) external view returns(bool support){
        support = true;
        uint count = assets.length;
       for(uint n = 0; n < count;n++){
                if(!supportAssets[assets[n]]){
                    support = false;
                    break;
                    }
                }
    }

    function setComtroller(address _comptroller) external {
        comptroller = _comptroller;
    }

    //notes:The order of the methods is consistent with that in the contract
    function addHProtocol(string memory _source, address _protocol,string[] memory _methods) public onlyOwner{
      require(!isExistSource(_source),"Source is already exist");
      require(_protocol != address(0),"Incorrect protocol");
      uint nextNum = allProtocol+1;
      PcvStruct.HProtocol memory protocol = PcvStruct.HProtocol({
          num:nextNum,
          source:_source,
          protocol:_protocol,
          variable:true,
          methods:_methods});
      hProtocols[nextNum] = protocol;
      allProtocol = nextNum;
    }

    function updateHProtocol(uint number, address newProtocol,string[] memory _methods) public onlyOwner{
       PcvStruct.HProtocol memory protocol = hProtocols[number];
       require(protocol.variable,"Protocol is not exist");
       hProtocols[number].protocol = newProtocol;
       hProtocols[number].methods = _methods;
    }

    function reomveProtocol(uint number) public onlyOwner{
        require(hProtocols[number].variable,"Protocol is not exist or unvariable");
        hProtocols[number].variable = false;
    }
    event RemoveProtocol(uint number);

    function isExistSource(string memory _source) internal view returns(bool exist){
        uint count = allProtocol;
        exist = false;
        bytes32 _sourceCode = keccak256(abi.encode(_source));
        for(uint i = 1; i<= count;i++){
           exist = keccak256(abi.encode(hProtocols[i].source)) == _sourceCode;
           if(exist){
               break;
           }
        }
    }

    function checkProtocols(uint[] memory _protocolNum,uint[] memory _methodNum) external view returns(bool available,uint protocolNum,uint methodNum){
            uint count = _protocolNum.length;
            PcvStruct.HProtocol memory protocol ;
            available = true;
            for(uint i = 0; i < count;i++){
               protocol = hProtocols[_protocolNum[i]];
               if(!protocol.variable){
                   available = false;
                   protocolNum = _protocolNum[i];
                   methodNum = _methodNum[i];
                   break;
               }
               if(methodNum >=  protocol.methods.length){
                   available = false;
                   protocolNum = _protocolNum[i];
                   methodNum = _methodNum[i];
                   break;
               }
            }
    }
}
