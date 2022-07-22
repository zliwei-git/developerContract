// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
//pragma experimental ABIEncoderV2;

import "../openzeppelin/Ownable.sol";
import "../token/ERC20Interface.sol";
import "../libs/Exponential.sol";

interface IPriceOracle {

    function getUnderlyingPrice(address _pToken) external view returns (uint);
}

/*interface IPERC20 {
    function getAccountSnapshot(address account) external view returns (uint, uint, uint, uint);
}*/

interface IPcv {
    // Get the PCV designated subscription token address
    function getSettleAsset() external view returns(address);

    function totalSupply() external view returns (uint256);
}

interface IPcvStorage {
    // PCV holding assets
    function getPcvAssets(address pcv) external view returns(address [] memory);
}

interface Assets {
    function netAssets(address token, address pcv) external view returns (uint256 amount, uint256 debt);
}

// Asset settlement
contract PcvExchangeRate is OwnableUpgradeSafe, Exponential{

    event NewPriceOracle(IPriceOracle oldPriceOracle, address newPriceOracle);

    event NewPcvStorage(IPcvStorage old, address newPcvStorage);

    event NewAssetsProtocolList(address token, string belong);

    event NewTokenConfig(address token, string symbol, string source, uint collateralRate, bool available);

    // Any collateral pledge rate must not exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18;

    uint internal constant scale = 1e18;

    IPriceOracle public oracle;

    // PCV storage contract
    IPcvStorage public pcvStorage;

    // TOKEN Configuration list
    mapping(address => TokenConfig) public tokenConfig;
    // TOKEN array of whitelists
    address[] public tokenAssetsList;

    // Array list of sub-settlement contracts
    Protocol[] public assetsProtocolList;
    // protocol
    mapping(string => address) internal protocolMap;

    // Initial voucher equity
    uint256 public exchangeRateMantissa;

    // TOKEN configuration structure
    struct TokenConfig {
        address token;
        string symbol;
        string source;
        uint baseUnit;
        uint collateralRate;
        bool available;
    }

    struct AssetField {
        uint256 totalAmount;
        uint256 netAssets;
        uint256 totalDebt;
        //uint debt;
        uint256 netWorth;
        uint256 availableAmount;
        uint256 fundsUtilization;
        uint256 singleAmount;
        uint256 singleDebt;
    }

    struct Protocol {
        address token;
        string belong;
    }

    function allWhitelistAssets()external view returns(address[] memory){
        return tokenAssetsList;
    }

    function initialize(uint _exchangeRateMantissa) public initializer {
        require(_exchangeRateMantissa > 0, "initial exchange rate must be greater than zero.");
        exchangeRateMantissa = _exchangeRateMantissa;

        super.__Ownable_init();
    }

    function setPriceOracle(address newOracle) external onlyOwner {
        IPriceOracle oldOracle = oracle;
        oracle = IPriceOracle(newOracle);
        emit NewPriceOracle(oldOracle, newOracle);
    }

    function setPcvStorage(address newPcvStorage) external onlyOwner {
        IPcvStorage old = pcvStorage;
        pcvStorage = IPcvStorage(newPcvStorage);
        emit NewPcvStorage(old, newPcvStorage);
    }


    function setAssetsProtocolList(address token, string memory belong) public onlyOwner {
        for (uint i = 0; i < assetsProtocolList.length; i++) {
            Protocol memory asset = assetsProtocolList[i];
            require(asset.token != token, "The token already exists");
        }
        assetsProtocolList.push(Protocol({
        token : token,
        belong : belong
        }));
        protocolMap[belong] = token;
        emit NewAssetsProtocolList(token, belong);
    }

    function removeAssetsProtocolList(address token) public onlyOwner {
        uint len = assetsProtocolList.length;
        uint assetIndex = len;
        string memory belong;
        for (uint i = 0; i < assetsProtocolList.length; i++) {
            Protocol memory asset = assetsProtocolList[i];
            if (asset.token == token) {
                belong = asset.belong;
                assetIndex = i;
                break;
            }
        }
        assetsProtocolList[assetIndex] = assetsProtocolList[len - 1];
        assetsProtocolList.pop();
        delete protocolMap[belong];
    }

    /**
     * @notice Set Token Whitelist Asset List
     * @dev token
     * @param token
     * @param symbol
     * @param source
     * @param collateralRate
     */
    function addTokenAssetsList(address token, string memory symbol, string memory source, uint collateralRate) public onlyOwner {
        require(collateralRate <= collateralFactorMaxMantissa && collateralRate > 0, "The pledge rate exceeds the specified value");
        TokenConfig storage config = tokenConfig[token];
        require(config.token != token, "The token already exists");
        config.token = token;
        config.symbol = symbol;
        config.source = source;

        config.baseUnit = baseUnit;
        config.collateralRate = collateralRate;
        config.available = true;

        tokenAssetsList.push(token);
        emit NewTokenConfig(token, symbol, source, collateralRate, config.available);
    }

    /**
     * @notice Update asset token configuration
     * @dev token If it does not exist, the modification will fail
     * @param token
     * @param source
     * @param collateralRate
     * @param available
     */
    function updataTokenConfig(address token, string memory source, uint collateralRate, bool available) public onlyOwner {
        require(collateralRate <= collateralFactorMaxMantissa && collateralRate > 0, "The pledge rate exceeds the specified value");
        TokenConfig storage config = tokenConfig[token];
        require(config.token == token, "token does not exist");
        config.token = token;
        config.source = source;
        config.collateralRate = collateralRate;
        config.available = available;

        if (available){
            bool isExist = false;
            for (uint i = 0; i < tokenAssetsList.length; i++) {
                address assetToken = tokenAssetsList[i];
                if (assetToken == token) {
                    isExist = true;
                    break;
                }
            }
            if (!isExist){
                tokenAssetsList.push(token);
            }
        } else {
            uint len = tokenAssetsList.length;
            uint assetIndex = len;
            for (uint i = 0; i < tokenAssetsList.length; i++) {
                address asset = tokenAssetsList[i];
                if (asset == token) {
                    assetIndex = i;
                    break;
                }
            }
            tokenAssetsList[assetIndex] = tokenAssetsList[len - 1];
            tokenAssetsList.pop();
        }
        emit NewTokenConfig(token, config.symbol, source, collateralRate, available);
    }

    /**
     * @notice Get PCV Share Net Value
     * @dev
     * @param pcv
     * return (netAssets, totalDebt, netWorth) Net assets, total liabilities, net worth (specified number of subscription tokens)
     */
    function netAssetValue(address pcv) external view returns (uint netAssets, uint totalDebt, uint netWorth) {
        (, netAssets, totalDebt, netWorth) = exchangeRateStoredInternal(pcv);
    }

    /**
     * @notice PCV Net worth statistics
     * @dev
     * @param pcv
     * @return (uint, uint, uint, uint)
     */
    function exchangeRateStoredInternal(address pcv) internal view returns (uint, uint, uint, uint) {
        uint256 totalSupply = IPcv(pcv).totalSupply();
        if (totalSupply == 0) {
            // If no tokens are minted：exchangeRateMantissa
            return (0, 0, 0, exchangeRateMantissa);
        } else {
            AssetField memory vars;
            vars.totalAmount = 0;
            vars.totalDebt = 0;
            // Get the array of PCV holding assets
            address[] memory assetsList = pcvStorage.getPcvAssets(pcv);
            for (uint i = 0; i < assetsList.length; i++) {
                TokenConfig memory config = tokenConfig[assetsList[i]];
                if (config.available == true) {
                    address protocol = protocolMap[config.source];
                    // Get the total amount of assets and total liabilities of a single position,
                    // and accumulate the data
                    (vars.singleAmount, vars.singleDebt) = Assets(protocol).netAssets(config.token, pcv);
                    if (vars.singleAmount > 0) {
                        vars.totalAmount = add_(vars.totalAmount, vars.singleAmount);
                    }
                    if (vars.singleDebt > 0) {
                        vars.totalDebt = add_(vars.totalDebt, vars.singleDebt);
                    }
                }
            }

            vars.netAssets = sub_(vars.totalAmount, vars.totalDebt);

            vars.netWorth = div_(mul_(vars.netAssets, scale), totalSupply);
            // Get the PCV designated subscription token address
            address investToken = IPcv(pcv).getSettleAsset();
            uint investTokenPrice = oracle.getUnderlyingPrice(investToken);
            // Convert the net value to the specified number of subscription tokens
            vars.netWorth = div_(mul_(vars.netWorth, scale), investTokenPrice);
            return (vars.totalAmount, vars.netAssets, vars.totalDebt, vars.netWorth);
        }
    }


    /**
     * @notice Get pcv available amount, debt
     * @dev
     * @param pcv
     * @return (uint, uint) total assets, total liabilities
     */
    function pcvAssetsAndDebt(address pcv) public view returns (uint, uint) {
        uint amount = 0;
        uint debt = 0;
        address[] memory assetsList = pcvStorage.getPcvAssets(pcv);
        for (uint i = 0; i < assetsList.length; i++) {
            address token = assetsList[i];
            TokenConfig memory config = tokenConfig[token];
            if (config.available == true) {
                address protocol = protocolMap[config.source];
                (uint tokenAmount, uint tokenDebt) = Assets(protocol).netAssets(token, pcv);
                if (tokenAmount > 0) {
                    // Process data, calculate loanable amount
                    tokenAmount = mul_(tokenAmount, config.collateralRate);
                    tokenAmount = div_(tokenAmount, scale);
                    amount = add_(amount, tokenAmount);
                }
                if (tokenDebt > 0) {
                    debt = add_(debt, tokenDebt);
                }
            }

        }

        return (amount, debt);
    }

    /**
     * @notice Get pcv asset details data
     * @dev
     * @param pcv
     * @return (uint, uint, uint, uint, uint, uint) Total Assets, Net Assets, Total Liabilities, Net Value (Number of Subscription Tokens), Borrowable Amount, Fund Utilization
     */
    function getTokenAssetsData(address pcv) external view returns(uint, uint, uint, uint, uint, uint) {
        AssetField memory vars;
        (vars.totalAmount, vars.netAssets, vars.totalDebt, vars.netWorth) = exchangeRateStoredInternal(pcv);
        (vars.availableAmount, ) = pcvAssetsAndDebt(pcv);
        vars.fundsUtilization = div_(mul_(vars.totalDebt, scale), vars.availableAmount);
        return (vars.totalAmount, vars.netAssets, vars.totalDebt, vars.netWorth, vars.availableAmount, vars.fundsUtilization);
    }

    /**
     * @notice Obtain the maximum amount of PCV single asset that can be borrowed, desirable
     * @dev
     * @param pcv
     * @param token
     * return (maxBorrowAmount, maxBorrow, maxRedeemAmount, maxRedeem)
     */
    function pcvMaxBorrowAndRedeem(address pcv, address token) external view returns(uint maxBorrowAmount, uint maxBorrow, uint maxRedeemAmount, uint maxRedeem){
        AssetField memory vars;
        TokenConfig memory config = tokenConfig[token];
        (vars.availableAmount, vars.totalDebt) = pcvAssetsAndDebt(pcv);
        uint amount = sub_(vars.availableAmount, vars.totalDebt);
        maxBorrowAmount = div_(amount, sub_(scale, config.collateralRate));
        (maxRedeemAmount, , , ) = exchangeRateStoredInternal(pcv);
        uint price = oracle.getUnderlyingPrice(token);
        maxBorrow = div_(mul_(maxBorrowAmount, scale), price);
        maxRedeem = div_(mul_(maxRedeemAmount, scale), price);
        return (maxBorrowAmount, maxBorrow, maxRedeemAmount, maxRedeem);
    }

    // Get single asset amount, liability
    function pcvAssetAndDebt(address token, address pcv)external view returns(uint pledgeRate, uint amount, uint debt){
        TokenConfig memory config = tokenConfig[token];
        require(config.token == token, "The token does not exist in the whitelist");
        address protocol = protocolMap[config.source];
        (uint tokenAmount, uint tokenDebt) = Assets(protocol).netAssets(token, pcv);

        pledgeRate = config.collateralRate;
        amount = tokenAmount;
        debt = tokenDebt;
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

}