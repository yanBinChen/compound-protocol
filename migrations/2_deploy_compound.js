const Unitroller = artifacts.require("Unitroller");
const Comptroller = artifacts.require("Comptroller");
const SimplePriceOracle = artifacts.require("SimplePriceOracle");
const MockERC20 = artifacts.require("MockERC20");
const CErc20 = artifacts.require("CErc20");
const WhitePaperInterestRateModel = artifacts.require("WhitePaperInterestRateModel");

module.exports = async function (deployer) {
    // 部署 MockERC20（模拟 DAI）
    await deployer.deploy(MockERC20, web3.utils.toWei("1000000", "ether")); // 100万代币
    const underlying = await MockERC20.deployed();

    // 部署 SimplePriceOracle
    await deployer.deploy(SimplePriceOracle);
    const priceOracle = await SimplePriceOracle.deployed();

    // 部署 Unitroller（代理）
    await deployer.deploy(Unitroller);
    const unitroller = await Unitroller.deployed();

    // 部署 Comptroller（实现）
    await deployer.deploy(Comptroller);
    const comptroller = await Comptroller.deployed();

    // 设置 Unitroller 的实现
    await unitroller._setPendingImplementation(comptroller.address);
    await comptroller._become(unitroller.address);

    // 设置 PriceOracle
    const comptrollerProxy = await Comptroller.at(unitroller.address);
    await comptrollerProxy._setPriceOracle(priceOracle.address);

    // 部署 WhitePaperInterestRateModel
    const baseRatePerYear = web3.utils.toWei("0.02", "ether"); // 2% 年利率
    const multiplierPerYear = web3.utils.toWei("0.1", "ether"); // 10% 斜率
    await deployer.deploy(WhitePaperInterestRateModel, baseRatePerYear, multiplierPerYear);
    const interestRateModel = await WhitePaperInterestRateModel.deployed();

    // 部署 cToken（例如 cDAI）
    await deployer.deploy(
        CErc20,
        underlying.address,
        comptrollerProxy.address,
        interestRateModel.address,
        web3.utils.toWei("0.02", "ether"), // 初始汇率
        "Compound Mock Token",
        "cMOCK",
        8 // 小数位
    );
    const cToken = await CErc20.deployed();

    // 添加 cToken 到市场
    await comptrollerProxy._supportMarket(cToken.address);

    // 设置价格（1 MOCK = 1 ETH）
    await priceOracle.setUnderlyingPrice(cToken.address, web3.utils.toWei("1", "ether"));
};