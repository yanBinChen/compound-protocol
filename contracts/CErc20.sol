// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./CToken.sol";

interface CompLike {
    function delegate(address delegatee) external;
}

/**
 * @title Compound's CErc20 Contract
 * @notice CTokens which wrap an EIP-20 underlying
 * @author Compound
 */
contract CErc20 is CToken, CErc20Interface {
    /**
     * @notice Initialize the new money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     */
    function initialize(
        address underlying_,
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) public {
        // CToken initialize does the bulk of the work
        super.initialize(
            comptroller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_
        );

        // Set underlying and sanity check it
        underlying = underlying_;
        EIP20Interface(underlying).totalSupply();
    }

    /*** User Interface ***/

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    //  用户存款以获取利，比如存入USDT获取CUSDT, CUSDT会升值，进而可以获取存款利息
    function mint(uint mintAmount) external override returns (uint) {
        mintInternal(mintAmount);
        return NO_ERROR;
    }

    /**
     * @notice Sender redeems cTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of cTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    // 取款，CToken -> Token 的过程，
    function redeem(uint redeemTokens) external override returns (uint) {
        redeemInternal(redeemTokens);
        return NO_ERROR;
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
        redeemUnderlyingInternal(redeemAmount);
        return NO_ERROR;
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrow(uint borrowAmount) external override returns (uint) {
        borrowInternal(borrowAmount);
        return NO_ERROR;
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay, or -1 for the full outstanding amount
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrow(uint repayAmount) external override returns (uint) {
        repayBorrowInternal(repayAmount);
        return NO_ERROR;
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
        repayBorrowBehalfInternal(borrower, repayAmount);
        return NO_ERROR;
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this cToken to be liquidated
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @param cTokenCollateral The market in which to seize collateral from the borrower
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(
        address borrower,
        uint repayAmount,
        CTokenInterface cTokenCollateral
    ) external override returns (uint) {
        liquidateBorrowInternal(borrower, repayAmount, cTokenCollateral);
        return NO_ERROR;
    }

    /**
     * @notice A public function to sweep accidental ERC-20 transfers to this contract. Tokens are sent to admin (timelock)
     * @param token The address of the ERC-20 token to sweep
     */
    function sweepToken(EIP20NonStandardInterface token) external override {
        require(
            msg.sender == admin,
            "CErc20::sweepToken: only admin can sweep tokens"
        );
        require(
            address(token) != underlying,
            "CErc20::sweepToken: can not sweep underlying token"
        );
        uint256 balance = token.balanceOf(address(this));
        token.transfer(admin, balance);
    }

    /**
     * @notice The sender adds to reserves.
     * @param addAmount The amount fo underlying token to add as reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves(uint addAmount) external override returns (uint) {
        return _addReservesInternal(addAmount);
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal view virtual override returns (uint) {
        EIP20Interface token = EIP20Interface(underlying);
        return token.balanceOf(address(this));
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
     *      This will revert due to insufficient balance or insufficient allowance.
     *      This function returns the actual amount received,
     *      which may be less than `amount` if there is a fee attached to the transfer.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferIn(
        address from,
        uint amount
    ) internal virtual override returns (uint) {
        // Read from storage once
        address underlying_ = underlying;
        // 使用 EIP20NonStandardInterface 而不是标准 EIP20Interface，
        // 因为 Compound 设计时考虑了非标准 ERC-20 代币（某些代币可能不返回 bool 值或有非标准行为）。
        EIP20NonStandardInterface token = EIP20NonStandardInterface(
            underlying_
        );
        // 获取当前合约的余额，转账成功后再获取一次余额，两次的差值即为用户真正往当前合约转入的资金量
        // 当前函数返回值就是用户真正往当前合约转入的资金量
        // 这个是因为转账流程可能会扣除gas费之类的，某些非标准 ERC-20 代币可能转入的金额与请求的 amount 不完全一致（例如因费用或精度问题）。
        // 通过比较前后余额，确保记录的转入量准确，防止错误。
        uint balanceBefore = EIP20Interface(underlying_).balanceOf(
            address(this)
        );
        token.transferFrom(from, address(this), amount);

        bool success;
        // assembly 是Solidity 的高级调用（如 token.transferFrom) 无法直接处理非标准 ERC-20 代币的返回值（例如无返回值或返回意外数据）。
        // assembly 允许直接访问底层 EVM（以太坊虚拟机）的返回数据（returndata），提供更灵活的处理方式。
        // assembly 代码块的关键作用是兼容非标准 ERC-20 代币：
        // 早期的 ERC-20 代币（如 USDT）在 transfer 或 transferFrom 时可能不返回 bool 值，
        // 或者返回数据格式不符合标准。这会导致标准 Solidity 调用（如 require(token.transferFrom(...) == true)）失败。
        assembly {
            // returndatasize()：返回上一次外部调用（transferFrom）的返回数据大小（以字节为单位）。
            // 根据返回数据大小，决定如何处理：
            switch returndatasize()
            case 0 { // 无返回值（returndatasize() == 0）
                // This is a non-standard ERC-20
                // 某些非标准 ERC-20 代币（如早期的 USDT）在 transferFrom 成功时不返回任何数据
                // Compound 假设无返回值表示转账成功，将 success 设为 true（not(0) 在 EVM 中等价于 true）
                // 这是为了兼容非标准代币的行为。
                success := not(0) // set success to true
            }
            case 32 {  // 标准返回值（returndatasize() == 32）
                // This is a compliant ERC-20
                // 标准 ERC-20 代币的 transferFrom 返回一个 32 字节的 bool 值（true 表示成功，false 表示失败）。
                // returndatacopy(0, 0, 32)：将返回数据复制到内存位置 0（从返回数据的第 0 字节开始，复制 32 字节）。
                // mload(0)：从内存位置 0 读取 32 字节数据（即 bool 值），赋给 success。
                returndatacopy(0, 0, 32)
                success := mload(0) // Set `success = returndata` of override external call
            }
            default {
                // This is an excessively non-compliant ERC-20, revert.
                // 异常返回值（非 0 或 32 字节）
                // 调用 revert(0, 0)，触发交易回滚，防止处理未知行为。
                revert(0, 0)
            }
        }
        // 预期success为true，如果success为false，则返回错误，并会自动revert
        require(success, "TOKEN_TRANSFER_IN_FAILED");

        // Calculate the amount that was *actually* transferred
        // 获取当前合约的余额
        uint balanceAfter = EIP20Interface(underlying_).balanceOf(
            address(this)
        );
        // 某些非标准 ERC-20 代币可能转入的金额与请求的 amount 不完全一致（例如因费用或精度问题）。
        // 所以使用这种操作前后账户资金差值作为实际转账金额的方式去兼容
        return balanceAfter - balanceBefore; // underflow already checked above, just subtract
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False success from `transfer` and returns an explanatory
     *      error code rather than reverting. If caller has not called checked protocol's balance, this may revert due to
     *      insufficient cash held in this contract. If caller has checked protocol's balance prior to this call, and verified
     *      it is >= amount, this should not revert in normal conditions.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferOut(
        address payable to,
        uint amount
    ) internal virtual override {
        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        token.transfer(to, amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {
                // This is a non-standard ERC-20
                success := not(0) // set success to true
            }
            case 32 {
                // This is a compliant ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0) // Set `success = returndata` of override external call
            }
            default {
                // This is an excessively non-compliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_OUT_FAILED");
    }

    /**
     * @notice Admin call to delegate the votes of the COMP-like underlying
     * @param compLikeDelegatee The address to delegate votes to
     * @dev CTokens whose underlying are not CompLike should revert here
     */
    function _delegateCompLikeTo(address compLikeDelegatee) external {
        require(
            msg.sender == admin,
            "only the admin may set the comp-like delegate"
        );
        CompLike(underlying).delegate(compLikeDelegatee);
    }
}
