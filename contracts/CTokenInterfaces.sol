// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ComptrollerInterface.sol";
import "./InterestRateModel.sol";
import "./EIP20NonStandardInterface.sol";
import "./ErrorReporter.sol";

contract CTokenStorage {
    /**
     * @dev Guard variable for re-entrancy checks
     */
    bool internal _notEntered;

    /**
     * @notice EIP-20 token name for this token
     */
    string public name;

    /**
     * @notice EIP-20 token symbol for this token
     */
    string public symbol;

    /**
     * @notice EIP-20 token decimals for this token
     */
    uint8 public decimals;

    // Maximum borrow rate that can ever be applied (.0005% / block)
    uint internal constant borrowRateMaxMantissa = 0.0005e16;

    // Maximum fraction of interest that can be set aside for reserves
    uint internal constant reserveFactorMaxMantissa = 1e18;

    /**
     * @notice Administrator for this contract
     */
    address payable public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address payable public pendingAdmin;

    /**
     * @notice Contract which oversees inter-cToken operations
     */
    // 类似风控的意思，主要在用户贷款和还款时候会用到。比如评估当前抵押品是否足以给你这么多贷款
    ComptrollerInterface public comptroller;

    /**
     * @notice Model which tells what the current interest rate should be
     */
    // 存款利率模型
    InterestRateModel public interestRateModel;

    // Initial exchange rate used when minting the first CTokens (used when totalSupply = 0)
    // Ctoken 值多少Token，这里是一个初始值
    uint internal initialExchangeRateMantissa;

    /**
     * @notice Fraction of interest currently set aside for reserves
     */
    // 从借款利息中提取到协议储备金的比例, 所以借款利息会比存款人获得的利息高，其中有一部分是协议持有
    uint public reserveFactorMantissa;

    /**
     * @notice Block number that interest was last accrued at
     */
    // 上次更新利率的 block index, 对应ETH区块链上的区块号
    uint public accrualBlockNumber;

    /**
     * @notice Accumulator of the total earned interest rate since the opening of the market
     */
    // newBorrowIndex = oldBorrowIndex + (oldBorrowIndex * borrowRate * timeDelta) / 1e18
    // 上面是Compound V2的利率模型 FV = PV(1 + x * t), borrowIndex初始值设置为1，表示没有利息
    // 有了初始值后，后续每个Block均可以计算出最新时刻的复利率，也就是 borrowIndex 是递增的
    // borrowRate 和资金池的资金使用率有关，可以理解为只需要知道资金使用率，就可以算出当前的borrowRate
    // 整体的借款利率由 interestRateModel 负责计算，不同CToken可以有不同的利率模型
    uint public borrowIndex;

    /**
     * @notice Total amount of outstanding borrows of the underlying in this market
     */
    // 当前市场总共借出的底层资产Token数量, 包括借款利息
    // 在 Compound 协议中，借贷的是底层资产（underlying asset），对于 CUSDT 来说是 USDT
    // CUSDT合约不支持借出 CUSDT Token，智能提供存入 USDT，获得对应数量的CUSDT
    // 比如你想借 xxxx token, 最终访问的就是 Cxxx 合约，存款、借款信息存储在对应的Cxxx 合约中
    // 比如质押ETH，借出 USDT；这些信息机存储在CUSDT合约中，这个合约中的totalBorrows也会累加，它的单位也是底层货币
    // 借 USDT 必须访问 CUSDT合约，利息也是用USDT累计
    uint public totalBorrows;

    /**
     * @notice Total amount of reserves of the underlying held in this market
     */
    // 当前市场合约本身总共持有的Token数量, 用户贷款利息的一个固定比例会累计到这里
    // 
    uint public totalReserves;

    /**
     * @notice Total number of tokens in circulation
     */
    // 当前市场总共发出去的CToken数量，CToken数量本身没有利息的概念，一个CToken值多少Token，由 exchangerate决定
    // exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
    uint public totalSupply;

    // Official record of token balances for each account
    // 存储每个用户地址Ctoken的余额，如果是CUSDT则对应每个用户CUSDT账户余额
    // 用户存款时，会给用户铸造CToken，对应就是累计用户的 accountTokens[用户地址] += 本次存款铸造的CToken数量
    // 同时给用户铸造的CToken数量也会累计到totalSupply中
    // 用户取款redeem的时候也会扣除accountTokens[用户地址]中的CToken数量，以及从totalSupply中扣除
    mapping(address => uint) internal accountTokens;

    // Approved token transfer amounts on behalf of others
    // address(比如你的账户地址)  -> (addr(比如Compound合约地址), uint(比如授权Compound最多操作你账户的ctoken数量))
    // 比如参加LP的时候，如果进入到清算阶段，则需要从你的账户转走一定数量的Ctoken给清算方。
    // 比如第一次参加LP或者lending的时候，有个approve阶段，该阶段就是授权允许合约从你的账户转出Ctoken，没有显示指定上限，默认是能操作你账户所有的资金
    mapping(address => mapping(address => uint)) internal transferAllowances;

    /**
     * @notice Container for borrow balance information
     * @member principal Total balance (with accrued interest), after applying the most recent balance-changing action
     * @member interestIndex Global borrowIndex as of the most recent balance-changing action
     */
    struct BorrowSnapshot {
        // 只在借款、还款和用户清算时候更新：new_principal = principal * borrowIndex/interestIndex,
        // 并且将 interestIndex 赋值为当前的borrowIndex
        uint principal; // 贷款总额，包括累计的利息
        // 最近一次的利息系数, 在用户最后一次借款或还款时的值
        uint interestIndex; 
    }

    // Mapping of account addresses to outstanding borrow balances
    mapping(address => BorrowSnapshot) internal accountBorrows;

    /**
     * @notice Share of seized collateral that is added to reserves
     */
    // 清算时，协议会将部分抵押品转给清算人，这里的2.8%指的是协议本身也会扣留2.8%的抵押品
    // 储备金用于增强协议的稳定性，例如弥补坏账、资助协议开发或治理。
    // 比如B抵押ETH借了1000 usdt,A帮B清算500 USDT,A 会获得超额8%的奖励，即价值 500 * 1.08 = 540 价值的ETH
    // 这些ETH来自B的抵押品。这些不全是A所有，其中 2.8%会被协议扣除: 540 * 0.028, A 能到手的：540 * (1-0.028) = 524.88
    // A 的收益：524.88/500 = 104.976%
    uint public constant protocolSeizeShareMantissa = 2.8e16; //2.8%
}

abstract contract CTokenInterface is CTokenStorage {
    /**
     * @notice Indicator that this is a CToken contract (for inspection)
     */
    bool public constant isCToken = true;

    /*** Market Events ***/

    /**
     * @notice Event emitted when interest is accrued
     */
    event AccrueInterest(
        uint cashPrior,
        uint interestAccumulated,
        uint borrowIndex,
        uint totalBorrows
    );

    /**
     * @notice Event emitted when tokens are minted
     */
    event Mint(address minter, uint mintAmount, uint mintTokens);

    /**
     * @notice Event emitted when tokens are redeemed
     */
    event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);

    /**
     * @notice Event emitted when underlying is borrowed
     */
    event Borrow(
        address borrower,
        uint borrowAmount,
        uint accountBorrows,
        uint totalBorrows
    );

    /**
     * @notice Event emitted when a borrow is repaid
     */
    event RepayBorrow(
        address payer,
        address borrower,
        uint repayAmount,
        uint accountBorrows,
        uint totalBorrows
    );

    /**
     * @notice Event emitted when a borrow is liquidated
     */
    event LiquidateBorrow(
        address liquidator,
        address borrower,
        uint repayAmount,
        address cTokenCollateral,
        uint seizeTokens
    );

    /*** Admin Events ***/

    /**
     * @notice Event emitted when pendingAdmin is changed
     */
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /**
     * @notice Event emitted when pendingAdmin is accepted, which means admin is updated
     */
    event NewAdmin(address oldAdmin, address newAdmin);

    /**
     * @notice Event emitted when comptroller is changed
     */
    event NewComptroller(
        ComptrollerInterface oldComptroller,
        ComptrollerInterface newComptroller
    );

    /**
     * @notice Event emitted when interestRateModel is changed
     */
    event NewMarketInterestRateModel(
        InterestRateModel oldInterestRateModel,
        InterestRateModel newInterestRateModel
    );

    /**
     * @notice Event emitted when the reserve factor is changed
     */
    event NewReserveFactor(
        uint oldReserveFactorMantissa,
        uint newReserveFactorMantissa
    );

    /**
     * @notice Event emitted when the reserves are added
     */
    event ReservesAdded(
        address benefactor,
        uint addAmount,
        uint newTotalReserves
    );

    /**
     * @notice Event emitted when the reserves are reduced
     */
    event ReservesReduced(
        address admin,
        uint reduceAmount,
        uint newTotalReserves
    );

    /**
     * @notice EIP20 Transfer event
     */
    event Transfer(address indexed from, address indexed to, uint amount);

    /**
     * @notice EIP20 Approval event
     */
    event Approval(address indexed owner, address indexed spender, uint amount);

    /*** User Interface ***/

    function transfer(address dst, uint amount) external virtual returns (bool);
    function transferFrom(
        address src,
        address dst,
        uint amount
    ) external virtual returns (bool);
    function approve(
        address spender,
        uint amount
    ) external virtual returns (bool);
    function allowance(
        address owner,
        address spender
    ) external view virtual returns (uint);
    function balanceOf(address owner) external view virtual returns (uint);
    function balanceOfUnderlying(address owner) external virtual returns (uint);
    function getAccountSnapshot(
        address account
    ) external view virtual returns (uint, uint, uint, uint);
    function borrowRatePerBlock() external view virtual returns (uint);
    function supplyRatePerBlock() external view virtual returns (uint);
    function totalBorrowsCurrent() external virtual returns (uint);
    function borrowBalanceCurrent(
        address account
    ) external virtual returns (uint);
    function borrowBalanceStored(
        address account
    ) external view virtual returns (uint);
    function exchangeRateCurrent() external virtual returns (uint);
    function exchangeRateStored() external view virtual returns (uint);
    function getCash() external view virtual returns (uint);
    function accrueInterest() external virtual returns (uint);
    function seize(
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external virtual returns (uint);

    /*** Admin Functions ***/

    function _setPendingAdmin(
        address payable newPendingAdmin
    ) external virtual returns (uint);
    function _acceptAdmin() external virtual returns (uint);
    function _setComptroller(
        ComptrollerInterface newComptroller
    ) external virtual returns (uint);
    function _setReserveFactor(
        uint newReserveFactorMantissa
    ) external virtual returns (uint);
    function _reduceReserves(uint reduceAmount) external virtual returns (uint);
    function _setInterestRateModel(
        InterestRateModel newInterestRateModel
    ) external virtual returns (uint);
}

contract CErc20Storage {
    /**
     * @notice Underlying asset for this CToken
     */
    address public underlying; // Token的合约地址
}

abstract contract CErc20Interface is CErc20Storage {
    /*** User Interface ***/

    function mint(uint mintAmount) external virtual returns (uint);
    function redeem(uint redeemTokens) external virtual returns (uint);
    function redeemUnderlying(
        uint redeemAmount
    ) external virtual returns (uint);
    function borrow(uint borrowAmount) external virtual returns (uint);
    function repayBorrow(uint repayAmount) external virtual returns (uint);
    function repayBorrowBehalf(
        address borrower,
        uint repayAmount
    ) external virtual returns (uint);
    function liquidateBorrow(
        address borrower,
        uint repayAmount,
        CTokenInterface cTokenCollateral
    ) external virtual returns (uint);
    function sweepToken(EIP20NonStandardInterface token) external virtual;

    /*** Admin Functions ***/

    function _addReserves(uint addAmount) external virtual returns (uint);
}

contract CDelegationStorage {
    /**
     * @notice Implementation address for this contract
     */
    address public implementation;
}

abstract contract CDelegatorInterface is CDelegationStorage {
    /**
     * @notice Emitted when implementation is changed
     */
    event NewImplementation(
        address oldImplementation,
        address newImplementation
    );

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param implementation_ The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(
        address implementation_,
        bool allowResign,
        bytes memory becomeImplementationData
    ) external virtual;
}

abstract contract CDelegateInterface is CDelegationStorage {
    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @dev Should revert if any issues arise which make it unfit for delegation
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) external virtual;

    /**
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() external virtual;
}
