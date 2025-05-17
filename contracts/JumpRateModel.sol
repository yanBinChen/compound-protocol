// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./InterestRateModel.sol";

/**
 * @title Compound's JumpRateModel Contract
 * @author Compound
 */
contract JumpRateModel is InterestRateModel {
    event NewInterestParams(
        uint baseRatePerBlock,
        uint multiplierPerBlock,
        uint jumpMultiplierPerBlock,
        uint kink
    );

    // 代码里面很多都是乘以了 1e18, 因为 Solidity 不支持浮点数，这个相当于浮点数的精度
    // 1 个完整的代币（1 DAI）在智能合约中表示为 1 * 1e18（即 10^18 个最小单位，称为 wei，类似于以太坊的 ETH 使用 wei 作为最小单位）。
    // 以太坊的原生货币 ETH 使用 18 位精度（1 ETH = 10^18 wei）, 所以很多地方都延用了 1e18
    // 除了代币金额，其他用到小数的地方也都乘了le18, 例如 0.0001% 利率存储为 0.0001 * 1e18。
    // 主要点是solidity本身不支持小数运算
    uint256 private constant BASE = 1e18;

    /**
     * @notice The approximate number of blocks per year that is assumed by the interest rate model
     */
    // ETH 区块大约是15秒产生一个，一年大概是 2102400 个区块
    uint public constant blocksPerYear = 2102400;

    /**
     * @notice The multiplier of utilization rate that gives the slope of the interest rate
     */
    // 在利用率低于 kink（阈值）时，借款利率 = baseRatePerBlock + multiplierPerBlock * 资金利用率。
    uint public multiplierPerBlock;

    /**
     * @notice The base interest rate which is the y-intercept when utilization rate is 0
     */
    // 对应资金利用率为0时的借款利率，资金利用率为0对应还没有人借过款
    uint public baseRatePerBlock;

    /**
     * @notice The multiplierPerBlock after hitting a specified utilization point
     */
    // 当利用率 > kink 时，借款利率 = baseRatePerBlock + multiplierPerBlock * kink + jumpMultiplierPerBlock * (利用率 - kink)
    // 这时的借款利率是斜率为jumpMultiplierPerBlock的一条直线
    uint public jumpMultiplierPerBlock;

    /**
     * @notice The utilization point at which the jump multiplier is applied
     */
    // compound v2 的利率模型也是两段式，当资金利用率超过一个阈值时，借款利息和贷款利息就会陡增。
    // 通过这个机制来鼓励为资金池提供流动性，鼓励还款和用户注入资金赚取利息。当前找个值有个就是资金利用率的拐点
    // 采用“跳跃式”利率曲线，利用率低于某阈值（kink）时利率线性增长，超过阈值后利率快速上升（跳跃）。
    // 比如 klink等于0.8e18，对应资金利用率在 80%后，借款利率会急剧上升
    uint public kink;

    /**
     * @notice Construct an interest rate model
     * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by BASE)
     * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by BASE)
     * @param jumpMultiplierPerYear The multiplierPerBlock after hitting a specified utilization point
     * @param kink_ The utilization point at which the jump multiplier is applied
     */
    constructor(
        uint baseRatePerYear,
        uint multiplierPerYear,
        uint jumpMultiplierPerYear,
        uint kink_
    ) public {
        baseRatePerBlock = baseRatePerYear / blocksPerYear;
        multiplierPerBlock = multiplierPerYear / blocksPerYear;
        jumpMultiplierPerBlock = jumpMultiplierPerYear / blocksPerYear;
        kink = kink_;

        emit NewInterestParams(
            baseRatePerBlock,
            multiplierPerBlock,
            jumpMultiplierPerBlock,
            kink
        );
    }

    /**
     * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market (currently unused)
     * @return The utilization rate as a mantissa between [0, BASE]
     */
    function utilizationRate(
        uint cash,
        uint borrows,
        uint reserves
    ) public pure returns (uint) {
        // Utilization rate is 0 when there are no borrows
        if (borrows == 0) {
            return 0;
        }

        // 因为solidity 不支持小数，所以分子需要乘以BASE
        return (borrows * BASE) / (cash + borrows - reserves);
    }

    /**
     * @notice Calculates the current borrow rate per block, with the error code expected by the market
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @return The borrow rate percentage per block as a mantissa (scaled by BASE)
     */
    function getBorrowRate(
        uint cash,
        uint borrows,
        uint reserves
    ) public view override returns (uint) {
        // borrows / (cash + borrows - reserves)
        uint util = utilizationRate(cash, borrows, reserves);

        if (util <= kink) {
            // 利用率低于拐点
            // multiplierPerBlock和util都有BASE这个因子，所以这里需要除一个因子
            return ((util * multiplierPerBlock) / BASE) + baseRatePerBlock;
        } else {
            // 利用率超过拐点后的计算方式，本质是斜率为jumpMultiplierPerBlock的一条直线
            uint normalRate = ((kink * multiplierPerBlock) / BASE) +
                baseRatePerBlock;
            uint excessUtil = util - kink;
            return ((excessUtil * jumpMultiplierPerBlock) / BASE) + normalRate;
        }
    }

    /**
     * @notice Calculates the current supply rate per block
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @param reserveFactorMantissa The current reserve factor for the market
     * @return The supply rate percentage per block as a mantissa (scaled by BASE)
     */
    function getSupplyRate(
        uint cash,
        uint borrows,
        uint reserves,
        uint reserveFactorMantissa
    ) public view override returns (uint) {
        // 贷款利息中，协议需要保留一部分，剩余部分给资金注入方
        uint oneMinusReserveFactor = BASE - reserveFactorMantissa;

        // 上面那个借款函数，获得借款利率
        uint borrowRate = getBorrowRate(cash, borrows, reserves);
        // 贷款利率扣除协议保留的那部分资金，其余均为存款利率
        uint rateToPool = (borrowRate * oneMinusReserveFactor) / BASE;

        // 存款利息 = 资金利用率 * (借款利率 - 协议本身持有借款利息的比例)
        return (utilizationRate(cash, borrows, reserves) * rateToPool) / BASE;
    }
}
