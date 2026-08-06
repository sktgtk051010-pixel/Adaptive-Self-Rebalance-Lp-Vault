# Adaptive LP Vault Frontend

Web3 交互前端，对标 Gamma UI/UX。

## 使用方法

1. 确保已部署合约到 Sepolia 测试网
2. 在 `app.js` 中更新 `ADDRESSES` 为实际部署地址
3. 用浏览器打开 `index.html`（推荐使用本地 HTTP 服务器）
4. 连接 MetaMask 钱包（需切换到 Sepolia 测试网）

## 功能模块

- **钱包连接**：MetaMask 连接，Sepolia 网络检测
- **存取款**：WETH+USDC 双币存入，份额赎回
- **数据看板**：TVL、TWAP 价格、资金分布可视化
- **再平衡**：手动触发再平衡，领取激励奖励
- **治理中心**：查看治理参数

## 本地运行

```bash
# 使用任意 HTTP 服务器
npx serve .
# 或
python -m http.server 8080
```
