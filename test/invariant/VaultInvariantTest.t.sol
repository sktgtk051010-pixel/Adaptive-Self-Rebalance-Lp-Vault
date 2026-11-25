// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../src/vault/AdaptiveLPVault.sol";

contract VaultInvariantHandler is BaseTest {
    // 检测标记：vault 执行成功但结果不符预期时置位，而不是 revert。
    // 若在此 revert，Foundry 会把该次调用判为失败并回滚状态，错误就被"跳过"吞掉；
    // 置位后状态保留，由 invariant_handlerAssertionsHold 统一断言。
    bool public depositNoShareGain;
    bool public withdrawAmountMismatch;
    bool public withdrawShareMismatch;

    constructor() {
        setUp();
    }

    // 模糊测试动作：Alice存入随机金额的WETH和USDC，验证份额增加
    function depositAlice(uint256 wethAmt, uint256 usdcAmt) public {
        wethAmt = bound(wethAmt, 0.01 ether, 50 ether);
        usdcAmt = bound(usdcAmt, 20e6, 100_000e6);

        if (weth.balanceOf(alice) < wethAmt || usdc.balanceOf(alice) < usdcAmt) {
            _mintTokens(alice, wethAmt * 2, usdcAmt * 2);
        }

        uint256 sharesBefore = vault.balanceOf(alice);
        _deposit(alice, wethAmt, usdcAmt);
        uint256 sharesAfter = vault.balanceOf(alice);

        if (sharesAfter <= sharesBefore) depositNoShareGain = true;
    }

    // 模糊测试动作：Bob存入随机金额的WETH和USDC，验证份额增加
    function depositBob(uint256 wethAmt, uint256 usdcAmt) public {
        wethAmt = bound(wethAmt, 0.01 ether, 50 ether);
        usdcAmt = bound(usdcAmt, 20e6, 100_000e6);

        if (weth.balanceOf(bob) < wethAmt || usdc.balanceOf(bob) < usdcAmt) {
            _mintTokens(bob, wethAmt * 2, usdcAmt * 2);
        }

        uint256 sharesBefore = vault.balanceOf(bob);
        _deposit(bob, wethAmt, usdcAmt);
        uint256 sharesAfter = vault.balanceOf(bob);

        if (sharesAfter <= sharesBefore) depositNoShareGain = true;
    }

    // 模糊测试动作：Charlie存入随机金额的WETH和USDC，验证份额增加
    function depositCharlie(uint256 wethAmt, uint256 usdcAmt) public {
        wethAmt = bound(wethAmt, 0.01 ether, 50 ether);
        usdcAmt = bound(usdcAmt, 20e6, 100_000e6);

        if (weth.balanceOf(charlie) < wethAmt || usdc.balanceOf(charlie) < usdcAmt) {
            _mintTokens(charlie, wethAmt * 2, usdcAmt * 2);
        }

        uint256 sharesBefore = vault.balanceOf(charlie);
        _deposit(charlie, wethAmt, usdcAmt);
        uint256 sharesAfter = vault.balanceOf(charlie);

        if (sharesAfter <= sharesBefore) depositNoShareGain = true;
    }

    // 模糊测试动作：Alice赎回随机比例（1%-50%）的份额，验证代币到账和份额减少
    function withdrawAlice(uint256 sharePct) public {
        uint256 shares = vault.balanceOf(alice);
        if (shares == 0) return;

        sharePct = bound(sharePct, 1, 50);
        uint256 sharesToWithdraw = (shares * sharePct) / 100;
        if (sharesToWithdraw == 0) return;

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(sharesToWithdraw, 0, 0);

        if (weth.balanceOf(alice) != wethBefore + wethOut) withdrawAmountMismatch = true;
        if (usdc.balanceOf(alice) != usdcBefore + usdcOut) withdrawAmountMismatch = true;
        if (vault.balanceOf(alice) != shares - sharesToWithdraw) withdrawShareMismatch = true;
    }

    // 模糊测试动作：Bob赎回随机比例（1%-50%）的份额，验证代币到账和份额减少
    function withdrawBob(uint256 sharePct) public {
        uint256 shares = vault.balanceOf(bob);
        if (shares == 0) return;

        sharePct = bound(sharePct, 1, 50);
        uint256 sharesToWithdraw = (shares * sharePct) / 100;
        if (sharesToWithdraw == 0) return;

        uint256 wethBefore = weth.balanceOf(bob);
        uint256 usdcBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(sharesToWithdraw, 0, 0);

        if (weth.balanceOf(bob) != wethBefore + wethOut) withdrawAmountMismatch = true;
        if (usdc.balanceOf(bob) != usdcBefore + usdcOut) withdrawAmountMismatch = true;
        if (vault.balanceOf(bob) != shares - sharesToWithdraw) withdrawShareMismatch = true;
    }

    // 模糊测试动作：Charlie赎回随机比例（1%-50%）的份额，验证代币到账和份额减少
    function withdrawCharlie(uint256 sharePct) public {
        uint256 shares = vault.balanceOf(charlie);
        if (shares == 0) return;

        sharePct = bound(sharePct, 1, 50);
        uint256 sharesToWithdraw = (shares * sharePct) / 100;
        if (sharesToWithdraw == 0) return;

        uint256 wethBefore = weth.balanceOf(charlie);
        uint256 usdcBefore = usdc.balanceOf(charlie);

        vm.prank(charlie);
        (uint256 wethOut, uint256 usdcOut) = vault.withdrawDual(sharesToWithdraw, 0, 0);

        if (weth.balanceOf(charlie) != wethBefore + wethOut) withdrawAmountMismatch = true;
        if (usdc.balanceOf(charlie) != usdcBefore + usdcOut) withdrawAmountMismatch = true;
        if (vault.balanceOf(charlie) != shares - sharesToWithdraw) withdrawShareMismatch = true;
    }

    // 模糊测试动作：跳过700秒后执行再平衡（金库非空时）
    function rebalance() public {
        if (vault.totalSupply() == 0) return;

        skip(700);
        vault.rebalance();
    }
}

contract VaultInvariantTest is Test {
    VaultInvariantHandler public handler;

    function setUp() public {
        handler = new VaultInvariantHandler();
        targetContract(address(handler));
    }

    // 不变量：所有用户份额之和 + 死份额（DEAD_SHARES=1e6）始终等于总供应量（份额守恒）
    function invariant_sharesConservation() public view {
        uint256 totalSupply = handler.vault().totalSupply();
        if (totalSupply == 0) return; // 空金库：尚无任何份额（含死份额）

        uint256 sumOfBalances = handler.vault().balanceOf(handler.alice()) + handler.vault().balanceOf(handler.bob())
            + handler.vault().balanceOf(handler.charlie());

        assertEq(sumOfBalances + 1e6, totalSupply, "sum of user balances + dead shares should equal totalSupply");
    }

    // 不变量：所有用户可赎回资产之和不超过金库总资产（偿付能力，无资不抵债）
    function invariant_solvency() public view {
        uint256 totalAssets = handler.vault().totalAssets();

        uint256 aliceAssets = handler.vault().convertToAssets(handler.vault().balanceOf(handler.alice()));
        uint256 bobAssets = handler.vault().convertToAssets(handler.vault().balanceOf(handler.bob()));
        uint256 charlieAssets = handler.vault().convertToAssets(handler.vault().balanceOf(handler.charlie()));
        uint256 sumOfUserAssets = aliceAssets + bobAssets + charlieAssets;

        assertLe(sumOfUserAssets, totalAssets, "sum of user assets should not exceed totalAssets (insolvency detected)");
    }

    // 不变量：handler 的检测标记全程未被置位
    // 覆盖三个业务正确性检查：存款必须增加份额、撤资金额必须与真实余额差一致、撤资必须烧掉对应份额
    function invariant_handlerAssertionsHold() public view {
        assertFalse(handler.depositNoShareGain(), "deposit succeeded without increasing shares");
        assertFalse(handler.withdrawAmountMismatch(), "withdraw returned amount mismatches balance delta");
        assertFalse(handler.withdrawShareMismatch(), "withdraw did not burn requested shares");
    }
}
