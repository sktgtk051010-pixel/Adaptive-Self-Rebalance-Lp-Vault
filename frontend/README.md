
## 使用方法

1. 确保已部署合约到 Sepolia 测试网
2. 合约地址已内置至前端代码（`app.js` 中的 `ADDRESSES`），无需手动修改
3. 用浏览器打开 `index.html`（推荐使用本地 HTTP 服务器）
4. 连接 MetaMask 钱包（需切换到 Sepolia 测试网）

> 普通用户操作指引请参考项目根目录的 [USER_GUIDE.md](../USER_GUIDE.md)。

## 功能模块

- **钱包连接**：MetaMask 连接，Sepolia 网络检测
- **存取款**：WETH+USDC 双币存入，份额赎回
- **数据看板**：TVL、TWAP 价格、资金分布可视化
- **再平衡**：手动触发再平衡；再平衡产生正向收益时可领取 USDC 激励（激励池需由治理方预先充值，默认部署余额为 0）
- **治理中心**：查看治理参数,达到门槛可提案修改治理参数

## 本地运行

```bash
# 使用任意 HTTP 服务器
npx serve .
# 或
python -m http.server 8080
```
