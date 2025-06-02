// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./CErc20.sol";

/**
 * @title Compound's CErc20Delegate Contract
 * @notice CTokens which wrap an EIP-20 underlying and are delegated to
 * @author Compound
 */
 //  这个是CErc20实例，也就是用户rpc是从 CErc20Delegate -> CErc20 -> CToken.sol的
//  CErc20Delegate 可以替换实现，进而实现实例的升级。真正的用户流量入口是CErc20Delegator.sol
// CErc20Delegator.sol 里面保存了 CErc20Delegate implementation 地址，替换这个地址即可实现合约的升级
// 更新代理合约的 implementation 地址（通过 setImplementation 函数，需管理员权限）
// 以太坊代理合约中，状态（如 accountTokens）仅存储在代理合约（CUSDT 0x39AA39c021dfbaE8faC545936693aC917d5E7563）
// delegatecall 确保实现合约操作代理的存储，这样实现合约就可以任意替换。CErc20Delegator.sol 就是代理合约

// 角色：实现合约（Implementation），提供 cUSDC 的实际业务逻辑。
// 职责：
// 实现逻辑：包含 CToken.sol 和 CErc20.sol 的所有功能，如：
// 存款（mint）：将 USDC 转入合约，铸造 cUSDC。
// 提取（redeem）：销毁 cUSDC，返回 USDC。
// 借贷（borrow）：检查 Comptroller 流动性，借出 USDC。
// 利息计算（accrueInterest）：根据 InterestRateModel 更新兑换率。
// ERC-20 功能（balanceOf、transfer）：管理 cUSDC 代币。
// 不存储状态：所有状态（如余额、总供应量）存储在代理合约（CErc20Delegator.sol）中，通过 delegatecall 操作。
// 可升级：新的 CErc20Delegate.sol 版本可部署，代理合约更新 implementation 地址指向新版本。

// 关键点：
// 继承 CToken.sol 和 CErc20.sol，实现所有 cToken 功能。
// 通过 delegatecall 在代理合约的存储上下文中执行。
// 可替换为新版本（如 NewCErc20Delegate.sol）以修复 bug 或添加功能。
contract CErc20Delegate is CErc20, CDelegateInterface {
    /**
     * @notice Construct an empty delegate
     */
    constructor() {}

    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) virtual override public {
        // Shh -- currently unused
        data;

        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            implementation = address(0);
        }

        require(msg.sender == admin, "only the admin may call _becomeImplementation");
    }

    /**
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() virtual override public {
        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            implementation = address(0);
        }

        require(msg.sender == admin, "only the admin may call _resignImplementation");
    }
}
