// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./CTokenInterfaces.sol";

/**
 * @title Compound's CErc20Delegator Contract
 * @notice CTokens which wrap an EIP-20 underlying and delegate to an implementation
 * @author Compound
 */
//  CErc20Delegator.sol 就是代理合约，cUSDC 合约（0x39AA39c021dfbaE8faC545936693aC917d5E7563）的实际部署文件。
// 代理合约职责：
// 存储状态：持有 cUSDC 的状态变量，如：
// accountTokens[address]：用户 cUSDC 余额。
// totalSupply：cUSDC 总供应量。
// implementation：实现合约地址（如 0x<delegate_address>）。
// comptroller：Comptroller 地址（0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B）。
// interestRateModel：利率模型地址。
// underlying：基础资产地址（USDC 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48）。
// 接收调用：作为用户交互的入口，接收所有函数调用（如 mint、redeem）。
// 委托逻辑：通过 delegatecall 将调用转发到实现合约（CErc20Delegate.sol），保留代理合约的存储上下文。
// 支持升级：提供 setImplementation 函数（需管理员权限），更新 implementation 地址以指向新的实现合约。

// 关键点：
// 不包含业务逻辑，仅存储状态和转发调用。
// 通过 fallback 函数捕获所有未定义的调用，委托给实现合约。
// 管理员可调用 _setImplementation 升级逻辑，保持 cUSDC 地址不变。

// delegatecall 确保实现合约操作代理的存储，这样实现合约就可以任意替换
// cUSDC 部署一个当前合约即可（0x39AA39c021dfbaE8faC545936693aC917d5E7563），
// 可提供更新/替换内部实现，进而做到合约升级并且可以保持cUSDC地址不变

/*
delegatecall 确保实现合约操作代理的存储，这样实现合约就可以任意替换。我没有理解是怎么达到“确保实现合约操作代理的存储”这个目标的
contract CErc20Delegate is CErc20, CDelegateInterface
contract CErc20 is CToken, CErc20Interface
abstract contract CToken is
    CTokenInterface,
    ExponentialNoError,
    TokenErrorReporter
abstract contract CTokenInterface is CTokenStorage

CTokenStorage 里面存储了很多状态，比如totalSupply、totalBorrows、accountTokens。
以mint为例，执行mint的是一个CErc20Delegate实现合约，这个合约实现了CTokenStorage，CTokenStorage 里面有很多状态，
其中mint就会修改accountTokens、totalSupply等变量。如果使用NewCErc20Delegate替换掉当前的CErc20Delegate，
那么当前CErc20Delegate CTokenStorage中的状态信息不就丢了，并且状态信息存储在CErc20Delegate的CTokenStorage成员属性中，
也没有做到“实现合约操作代理的存储”，因为实现合约的CTokenStorage中存储了很多属性
*/
/*
简单回答，代理合约和实现合约都实现了CTokenStorage接口，合约交互接口也确实将部分状态信息存储在CTokenStorage中
关键在于接口调用是通过代理合约的 callee_impl.delegatecall(data)实现接口调用的
delegatecall 接口保证的语义是执行callee_impl接口的代码逻辑，状态信息/变量 确实操作的调用方，也就是代理合约
的变量状态信息。即变量的读写操作发生在代理合约（CErc20Delegator）的存储槽中。

CErc20Delegate 的 CTokenStorage 定义了状态变量的布局（即变量的顺序和类型），但实际存储在 CErc20Delegator 中。
delegatecall 确保实现合约的代码操作的是代理合约的存储槽，而不是实现合约自己的存储。

1. 代理模式和 delegatecall 的基本原理
在 Compound V2 中，CErc20Delegator 是代理合约，CErc20Delegate 是实现合约，CTokenStorage 定义了状态变量（如 totalSupply、accountTokens）。代理模式的关键在于：
存储与逻辑分离：代理合约（CErc20Delegator）存储所有状态变量（totalSupply、accountTokens 等），实现合约（CErc20Delegate）只提供逻辑代码。
delegatecall 的作用：delegatecall 是一种低级调用方式，当代理合约调用实现合约的函数时，执行的是实现合约的代码，但操作的是代理合约的存储。
delegatecall 的核心特性
普通 call：调用目标合约的代码，使用目标合约的存储，msg.sender 和 msg.value 保持不变。
delegatecall：调用目标合约的代码，但使用调用者（代理合约）的存储，msg.sender 和 msg.value 保持不变。
效果：实现合约（CErc20Delegate）的代码运行时，读写的存储槽（storage slots）是代理合约（CErc20Delegator）的，而不是实现合约的。
这意味着，即使 CErc20Delegate 继承了 CTokenStorage 并定义了状态变量（如 totalSupply），这些变量在 CErc20Delegate 中不会被使用，因为 delegatecall 确保所有存储操作发生在代理合约的存储中。

CTokenStorage 定义了状态变量（如 totalSupply、accountTokens），并且 CErc20Delegate 继承了 CTokenStorage，因此可能认为状态存储在实现合约中。然而，在 Compound V2 的代理模式中，状态变量实际存储在代理合约（CErc20Delegator）中。以下是原因和机制：

2.1 代理合约定义存储
CErc20Delegator 合约继承了 CTokenStorage（通过 CErc20 和相关接口），因此它包含了所有状态变量（如 totalSupply、accountTokens）。
这些状态变量的实际存储槽（storage slots）位于 CErc20Delegator 的存储中。
实现合约（CErc20Delegate）虽然也继承了 CTokenStorage 并定义了相同的状态变量，但这些变量在 CErc20Delegate 中从不直接使用，因为 delegatecall 使实现合约的代码操作代理合约的存储。


CErc20Delegate 继承 CTokenStorage 是为了：
定义与代理合约相同的存储布局，确保 delegatecall 时变量映射正确。
提供代码中访问这些变量的接口（例如，accountTokens[msg.sender] += mintAmount）。
但 CErc20Delegate 本身不会直接存储数据，因为它的代码通过 delegatecall 在代理合约的存储上下文中执行。

delegatecall 的机制：delegatecall 使实现合约的代码在代理合约的存储上下文中运行。所有状态读写（totalSupply、accountTokens 等）都发生在 CErc20Delegator 的存储槽中。
存储布局一致性：CErc20Delegate 和 CErc20Delegator 都继承 CTokenStorage，确保变量的槽分配一致。
代理合约持有状态：状态变量的实际数据存储在 CErc20Delegator 中，CErc20Delegate 只是提供逻辑。
*/

// 交互流程：
// 用户调用 cUSDC（CErc20Delegator.sol）的 mint 函数。
// CErc20Delegator.sol 通过 delegatecall 转发到 CErc20Delegate.sol。
// CErc20Delegate.sol 执行逻辑，调用 Comptroller（0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B）和 InterestRateModel，更新代理合约的存储。
contract CErc20Delegator is
    CTokenInterface,
    CErc20Interface,
    CDelegatorInterface
{
    /**
     * @notice Construct a new money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     * @param admin_ Address of the administrator of this token
     * @param implementation_ The address of the implementation the contract delegates to
     * @param becomeImplementationData The encoded args for becomeImplementation
     */
    constructor(
        address underlying_,
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_,
        address implementation_, // 合约实现的地址
        bytes memory becomeImplementationData
    ) {
        // Creator of the contract is admin during initialization
        admin = payable(msg.sender);

        // First delegate gets to initialize the delegator (i.e. storage contract)
        delegateTo(
            implementation_,
            abi.encodeWithSignature(
                "initialize(address,address,address,uint256,string,string,uint8)",
                underlying_,
                comptroller_,
                interestRateModel_,
                initialExchangeRateMantissa_,
                name_,
                symbol_,
                decimals_
            )
        );

        // New implementations always get set via the settor (post-initialize)
        _setImplementation(implementation_, false, becomeImplementationData);

        // Set the proper admin now that initialization is done
        admin = admin_;
    }

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param implementation_ The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    //  旧实现（CErc20Delegate）可能通过 _resignImplementation 清理状态（如果需要）。
    // 新实现（NewCErc20Delegate）通过 _becomeImplementation 初始化，确保与代理合约的存储兼容。
    // 代理合约的存储（totalSupply、accountTokens 等）保持不变，NewCErc20Delegate 的 mint 函数通过 delegatecall 继续操作相同的存储槽。
    function _setImplementation(
        address implementation_,
        bool allowResign,
        bytes memory becomeImplementationData
    ) public override {
        require(
            msg.sender == admin,
            "CErc20Delegator::_setImplementation: Caller must be admin"
        );

        if (allowResign) {
            delegateToImplementation(
                abi.encodeWithSignature("_resignImplementation()")
            );
        }

        address oldImplementation = implementation;
        implementation = implementation_;

        delegateToImplementation(
            abi.encodeWithSignature(
                "_becomeImplementation(bytes)",
                becomeImplementationData
            )
        );

        emit NewImplementation(oldImplementation, implementation);
    }

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mint(uint mintAmount) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("mint(uint256)", mintAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender redeems cTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of cTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint redeemTokens) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("redeem(uint256)", redeemTokens)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to redeem
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlying(
        uint redeemAmount
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("redeemUnderlying(uint256)", redeemAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrow(uint borrowAmount) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("borrow(uint256)", borrowAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay, or -1 for the full outstanding amount
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrow(uint repayAmount) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("repayBorrow(uint256)", repayAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay, or -1 for the full outstanding amount
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrowBehalf(
        address borrower,
        uint repayAmount
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "repayBorrowBehalf(address,uint256)",
                borrower,
                repayAmount
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this cToken to be liquidated
     * @param cTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(
        address borrower,
        uint repayAmount,
        CTokenInterface cTokenCollateral
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "liquidateBorrow(address,uint256,address)",
                borrower,
                repayAmount,
                cTokenCollateral
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(
        address dst,
        uint amount
    ) external override returns (bool) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("transfer(address,uint256)", dst, amount)
        );
        return abi.decode(data, (bool));
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external override returns (bool) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                src,
                dst,
                amount
            )
        );
        return abi.decode(data, (bool));
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (-1 means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(
        address spender,
        uint256 amount
    ) external override returns (bool) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        return abi.decode(data, (bool));
    }

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return The number of tokens allowed to be spent (-1 means infinite)
     */
    function allowance(
        address owner,
        address spender
    ) external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature(
                "allowance(address,address)",
                owner,
                spender
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("balanceOf(address)", owner)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Get the underlying balance of the `owner`
     * @dev This also accrues interest in a transaction
     * @param owner The address of the account to query
     * @return The amount of underlying owned by `owner`
     */
    function balanceOfUnderlying(
        address owner
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("balanceOfUnderlying(address)", owner)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Get a snapshot of the account's balances, and the cached exchange rate
     * @dev This is used by comptroller to more efficiently perform liquidity checks.
     * @param account Address of the account to snapshot
     * @return (possible error, token balance, borrow balance, exchange rate mantissa)
     */
    function getAccountSnapshot(
        address account
    ) external view override returns (uint, uint, uint, uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("getAccountSnapshot(address)", account)
        );
        return abi.decode(data, (uint, uint, uint, uint));
    }

    /**
     * @notice Returns the current per-block borrow interest rate for this cToken
     * @return The borrow interest rate per block, scaled by 1e18
     */
    function borrowRatePerBlock() external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("borrowRatePerBlock()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Returns the current per-block supply interest rate for this cToken
     * @return The supply interest rate per block, scaled by 1e18
     */
    function supplyRatePerBlock() external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("supplyRatePerBlock()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Returns the current total borrows plus accrued interest
     * @return The total borrows with interest
     */
    function totalBorrowsCurrent() external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("totalBorrowsCurrent()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
     * @param account The address whose balance should be calculated after updating borrowIndex
     * @return The calculated balance
     */
    function borrowBalanceCurrent(
        address account
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("borrowBalanceCurrent(address)", account)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return The calculated balance
     */
    function borrowBalanceStored(
        address account
    ) public view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("borrowBalanceStored(address)", account)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrue interest then return the up-to-date exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateCurrent() public override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("exchangeRateCurrent()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the CToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() public view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("exchangeRateStored()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Get cash balance of this cToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("getCash()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves.
     * @dev This calculates interest accrued from the last checkpointed block
     *      up to the current block and writes new checkpoint to storage.
     */
    function accrueInterest() public override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("accrueInterest()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Will fail unless called by another cToken during the process of liquidation.
     *  Its absolutely critical to use msg.sender as the borrowed cToken and not a parameter.
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of cTokens to seize
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seize(
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "seize(address,address,uint256)",
                liquidator,
                borrower,
                seizeTokens
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice A public function to sweep accidental ERC-20 transfers to this contract. Tokens are sent to admin (timelock)
     * @param token The address of the ERC-20 token to sweep
     */
    function sweepToken(EIP20NonStandardInterface token) external override {
        delegateToImplementation(
            abi.encodeWithSignature("sweepToken(address)", token)
        );
    }

    /*** Admin Functions ***/

    /**
     * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @param newPendingAdmin New pending admin.
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPendingAdmin(
        address payable newPendingAdmin
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "_setPendingAdmin(address)",
                newPendingAdmin
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sets a new comptroller for the market
     * @dev Admin function to set a new comptroller
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setComptroller(
        ComptrollerInterface newComptroller
    ) public override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("_setComptroller(address)", newComptroller)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
     * @dev Admin function to accrue interest and set a new reserve factor
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setReserveFactor(
        uint newReserveFactorMantissa
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "_setReserveFactor(uint256)",
                newReserveFactorMantissa
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
     * @dev Admin function for pending admin to accept role and update admin
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _acceptAdmin() external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("_acceptAdmin()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrues interest and adds reserves by transferring from admin
     * @param addAmount Amount of reserves to add
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves(uint addAmount) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("_addReserves(uint256)", addAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReserves(
        uint reduceAmount
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("_reduceReserves(uint256)", reduceAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrues interest and updates the interest rate model using _setInterestRateModelFresh
     * @dev Admin function to accrue interest and update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModel(
        InterestRateModel newInterestRateModel
    ) public override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "_setInterestRateModel(address)",
                newInterestRateModel
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Internal method to delegate execution to another contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     * @param callee The contract to delegatecall
     * @param data The raw data to delegatecall
     * @return The returned bytes from the delegatecall
     */
    //      callee.delegatecall(data) 是 Solidity 中用于执行 委托调用（delegatecall）的一条语句。它的作用是将当前函数的调用逻辑委托给指定的目标合约地址（callee），但在当前合约的上下文中执行代码。具体来说：
    // callee: 目标合约的地址，在 CErc20Delegator 中通常是 implementation，即当前的实现合约地址。
    // data: 编码后的函数调用数据，包含函数签名和参数（例如 abi.encodeWithSignature("mint(uint256)", mintAmount)）。
    // delegatecall: 一种低级调用方式，与普通 call 不同，它在调用目标合约的代码时，使用调用者的存储、上下文和状态（如 msg.sender、msg.value 和存储变量）。

    //     在代理合约的上下文中执行代码
    // 存储上下文: 与普通 call 不同，delegatecall 使用调用者（即代理合约）的存储空间。这意味着实现合约的代码在执行时，操作的是代理合约的存储变量（例如余额、利率等）。
    // 保持用户交互一致性: 用户与代理合约交互（调用 mint 等函数），但实际逻辑在实现合约中执行。msg.sender 和 msg.value 保持为用户的原始值，确保逻辑与用户期望一致。
    function delegateTo(
        address callee,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = callee.delegatecall(data);
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
        return returnData;
    }

    /**
     * @notice Delegates execution to the implementation contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     * @param data The raw data to delegatecall
     * @return The returned bytes from the delegatecall
     */
    function delegateToImplementation(
        bytes memory data
    ) public returns (bytes memory) {
        return delegateTo(implementation, data);
    }

    /**
     * @notice Delegates execution to an implementation contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     *  There are an additional 2 prefix uints from the wrapper returndata, which we ignore since we make an extra hop.
     * @param data The raw data to delegatecall
     * @return The returned bytes from the delegatecall
     */
    function delegateToViewImplementation(
        bytes memory data
    ) public view returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).staticcall(
            abi.encodeWithSignature("delegateToImplementation(bytes)", data)
        );
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
        return abi.decode(returnData, (bytes));
    }

    /**
     * @notice Delegates execution to an implementation contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     */
    fallback() external payable {
        require(
            msg.value == 0,
            "CErc20Delegator:fallback: cannot send value to fallback"
        );

        // delegate all other functions to current implementation
        (bool success, ) = implementation.delegatecall(msg.data);

        assembly {
            let free_mem_ptr := mload(0x40)
            returndatacopy(free_mem_ptr, 0, returndatasize())

            switch success
            case 0 {
                revert(free_mem_ptr, returndatasize())
            }
            default {
                return(free_mem_ptr, returndatasize())
            }
        }
    }
}
