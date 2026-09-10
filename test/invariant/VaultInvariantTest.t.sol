// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../base/BaseTest.t.sol";
import {AdaptiveLPVault} from "../../src/vault/AdaptiveLPVault.sol";

contract VaultInvariantHandler is BaseTest {
    uint256 public depositCount;
    uint256 public withdrawCount;
    uint256 public rebalanceCount;

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

        require(sharesAfter > sharesBefore, "deposit should increase shares");
        depositCount++;
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

        require(sharesAfter > sharesBefore, "deposit should increase shares");
        depositCount++;
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

        require(sharesAfter > sharesBefore, "deposit should increase shares");
        depositCount++;
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

        require(weth.balanceOf(alice) == wethBefore + wethOut, "weth balance mismatch");
        require(usdc.balanceOf(alice) == usdcBefore + usdcOut, "usdc balance mismatch");
        require(vault.balanceOf(alice) == shares - sharesToWithdraw, "shares should decrease");

        withdrawCount++;
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

        require(weth.balanceOf(bob) == wethBefore + wethOut, "weth balance mismatch");
        require(usdc.balanceOf(bob) == usdcBefore + usdcOut, "usdc balance mismatch");
        require(vault.balanceOf(bob) == shares - sharesToWithdraw, "shares should decrease");

        withdrawCount++;
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

        require(weth.balanceOf(charlie) == wethBefore + wethOut, "weth balance mismatch");
        require(usdc.balanceOf(charlie) == usdcBefore + usdcOut, "usdc balance mismatch");
        require(vault.balanceOf(charlie) == shares - sharesToWithdraw, "shares should decrease");

        withdrawCount++;
    }

    // 模糊测试动作：跳过700秒后执行再平衡（金库非空时）
    function rebalance() public {
        if (vault.totalSupply() == 0) return;

        skip(700);
        vault.rebalance();
        rebalanceCount++;
    }
}

contract VaultInvariantTest is Test {
    VaultInvariantHandler public handler;

    function setUp() public {
        handler = new VaultInvariantHandler();
        targetContract(address(handler));
    }

    // 不变量：所有用户份额之和始终等于总供应量（份额守恒）
    function invariant_sharesConservation() public view {
        uint256 totalSupply = handler.vault().totalSupply();
        uint256 sumOfBalances =
            handler.vault().balanceOf(handler.alice())
            + handler.vault().balanceOf(handler.bob())
            + handler.vault().balanceOf(handler.charlie());

        assertEq(sumOfBalances, totalSupply, "sum of user balances should equal totalSupply");
    }

    // 不变量：所有用户可赎回资产之和不超过金库总资产（偿付能力，无资不抵债）
    function invariant_solvency() public view {
        uint256 totalAssets = handler.vault().totalAssets();

        uint256 aliceAssets = handler.vault().convertToAssets(handler.vault().balanceOf(handler.alice()));
        uint256 bobAssets = handler.vault().convertToAssets(handler.vault().balanceOf(handler.bob()));
        uint256 charlieAssets = handler.vault().convertToAssets(handler.vault().balanceOf(handler.charlie()));
        uint256 sumOfUserAssets = aliceAssets + bobAssets + charlieAssets;

        assertLe(
            sumOfUserAssets,
            totalAssets + 1,
            "sum of user assets should not exceed totalAssets (insolvency detected)"
        );
    }

    // 不变量：convertToShares(totalAssets)始终约等于totalSupply（份额价格稳定，1%误差内）
    function invariant_sharePriceStability() public view {
        uint256 totalSupply = handler.vault().totalSupply();
        if (totalSupply == 0) return;

        uint256 totalAssets = handler.vault().totalAssets();
        uint256 sharesFromAssets = handler.vault().convertToShares(totalAssets);

        assertApproxEqRel(
            sharesFromAssets,
            totalSupply,
            0.01e18,
            "convertToShares(totalAssets) should approx equal totalSupply"
        );
    }

    // 不变量：单个用户的份额不超过总供应量（无超额铸造）
    function invariant_noUserExceedsTotalSupply() public view {
        uint256 totalSupply = handler.vault().totalSupply();

        assertLe(handler.vault().balanceOf(handler.alice()), totalSupply, "alice balance exceeds totalSupply");
        assertLe(handler.vault().balanceOf(handler.bob()), totalSupply, "bob balance exceeds totalSupply");
        assertLe(handler.vault().balanceOf(handler.charlie()), totalSupply, "charlie balance exceeds totalSupply");
    }
}
