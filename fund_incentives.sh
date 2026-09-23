#!/usr/bin/env bash
# 一次性脚本：查询部署钱包 USDC 余额，向激励合约充入（目标 5000 USDC，不足则全额转入）并验证
set -e
cd /mnt/d/vault/Adaptive-Self-Rebalance-Lp-Vault || exit 1

export PATH="$HOME/.foundry/bin:$PATH"
command -v cast >/dev/null 2>&1 || { echo "cast not found"; exit 1; }

PK=$(grep "^PRIVATE_KEY=" .env | head -1 | cut -d= -f2- | tr -d '\r\n"')
ADDR=$(cast wallet address --private-key "$PK")
echo "deployer: $ADDR"

BAL=$(cast call 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 "balanceOf(address)(uint256)" "$ADDR" --rpc-url sepolia | tr -d '\r' | sed 's/\[.*\]//' | tr -d ' ')
echo "USDC balance (raw): $BAL"

# 目标 5000 USDC = 5000000000；余额不足则转全部
if [ "$BAL" -ge 5000000000 ] 2>/dev/null; then
  AMT=5000000000
  echo "balance >= 5000 USDC, sending 5000 USDC"
else
  AMT="$BAL"
  echo "balance < 5000 USDC, sending all: $AMT"
fi

if [ "$AMT" = "0" ]; then
  echo "ERROR: deployer USDC balance is 0, need faucet first"
  exit 1
fi

echo "=== transferring to incentives ==="
cast send 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 "transfer(address,uint256)" 0xC2f7200cC9bd7c49DF58F2E93baB1C53261ABC4a "$AMT" --rpc-url sepolia --private-key "$PK"

echo "=== verify incentives balance ==="
cast call 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 "balanceOf(address)(uint256)" 0xC2f7200cC9bd7c49DF58F2E93baB1C53261ABC4a --rpc-url sepolia
