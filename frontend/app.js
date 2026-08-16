// ============================================================
// Adaptive LP Vault Frontend v5 (Local Anvil + Sepolia support)
// ============================================================
const SEPOLIA_CHAIN_ID = 11155111;
const LOCAL_CHAIN_ID = 31337;

// Sepolia 地址
const SEPOLIA_ADDRESSES = {
    vault: '0xEf104626cef86709284bA1e166A902626BB63473',
    weth: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
    usdc: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
    oracle: '0x54fAb281E70914f10b61A46231940F01363B0613',
    strategy: '0xf94A724BD5Ba064ce8f09d264AC1efAE5F3c8723',
    governance: '0x5079602959f0DD9F07FF59eCB8961518292E12e7',
    incentives: '0x1ed10deB31551f90D711ca2050A529F14b9D2b7a',
    govToken: '0x89604c71b77f60e31D6dB9FBe4280A588A7456d8',
};

// Anvil 主网分叉部署地址（从 DeployFork.s.sol 输出）
const LOCAL_ADDRESSES = {
    vault: '0xDe8E63b8F12eb883cB997D66333241581cE8049C',
    weth: '0x0c82CB749B53cB3433319cd6Be18d746b3781B9B',
    usdc: '0xB7a90aB16DC735fEef37B6Cc8c730800a0303C7A',
    oracle: '0xa36A4fe5D0a8E2b67f8bA71879be4c32a831F82a',
    strategy: '0x600e629667376ed170F72649cc45FcB2b4A91f07',
    governance: '0x82A5dF42DF7c74eD0FeFd0e352f8932958D24da0',
    incentives: '0xa6b6Df450a921753d4706F93eE809d8596fC6727',
    govToken: '0xD2ec315B6f013f3AaaB32da7EdFdb6c3f28a040E',
};

// 默认使用Sepolia
let ADDRESSES = { ...SEPOLIA_ADDRESSES };
let currentChainId = SEPOLIA_CHAIN_ID;

// localStorage 地址在 connectWallet 中根据网络加载

const ERC20_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function approve(address spender, uint256 amount) returns (bool)',
    'function allowance(address owner, address spender) view returns (uint256)',
    'function decimals() view returns (uint8)',
];
const VAULT_ABI = [
    'function deposit(uint256 wethAmount, uint256 usdcAmount, uint256 minShares)',
    'function withdrawDual(uint256 shares, uint256 minWeth, uint256 minUsdc) returns (uint256, uint256)',
    'function totalAssets() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function totalSupply() view returns (uint256)',
    'function rebalance()',
    'function rebalanceCount() view returns (uint256)',
    'function cumulativeFeesUSDC() view returns (uint256)',
    'function getDistribution() view returns (uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
    'function TOKEN0_IS_WETH() view returns (bool)',
];
const ORACLE_ABI = [
    'function getTWAPPrice() view returns (uint160 sqrtPriceX96, int24 tick)',
];
const GOV_ABI = [
    'function getParams() view returns (tuple(uint32 twapWindow, uint256 rebalanceThreshold, uint256 incentiveBps, uint256 maxSlippageBps, uint256 v2WeightCap, uint256 v3LowFeeWeightCap, uint256 v3HighFeeWeightCap, uint256 tightRangeBps, uint256 mediumRangeBps, uint256 wideRangeBps))',
];
const INCENTIVES_ABI = [
    'function rewardsEarned(address) view returns (uint256)',
    'function claimReward()',
    'function incentiveBps() view returns (uint256)',
    'function canRebalance() view returns (bool)',
    'function lastRebalanceTime() view returns (uint256)',
    'function cooldownPeriod() view returns (uint256)',
];
const GOV_TOKEN_ABI = [
    'function balanceOf(address) view returns (uint256)',
];

let provider, signer, account;
let C = {}; // contracts
let twapPrice = 0;
let token0IsWeth = false; // token0是否为WETH，从合约读取
let refreshTimer = null;

// ============================================================
// 安全工具函数
// ============================================================
function $(id) { return document.getElementById(id); }
function setText(id, text) {
    var el = $(id);
    if (el) { el.textContent = text; }
}
function show(id) { var el = $(id); if (el) el.classList.remove('hidden'); }
function hide(id) { var el = $(id); if (el) el.classList.add('hidden'); }

function showToast(msg, type) {
    type = type || 'info';
    var t = $('toast');
    t.textContent = msg;
    t.className = 'toast ' + type + ' show';
    clearTimeout(t._tm);
    t._tm = setTimeout(function(){ t.classList.remove('show'); }, 4000);
}

function showTxModal(title, msg) {
    $('txTitle').textContent = title;
    $('txMessage').textContent = msg;
    $('txModal').classList.remove('hidden');
}
function hideTxModal() { $('txModal').classList.add('hidden'); }

// ============================================================
// 初始化
// ============================================================
$('connectBtn').addEventListener('click', connectWallet);
document.querySelectorAll('.tab').forEach(function(tab) {
    tab.addEventListener('click', function() { switchTab(tab.dataset.tab); });
});
$('depositWeth').addEventListener('input', updateDepositEstimate);
$('depositUsdc').addEventListener('input', updateDepositEstimate);
$('withdrawShares').addEventListener('input', updateWithdrawEstimate);

async function connectWallet() {
    if (!window.ethereum) {
        showToast('未检测到钱包，请安装 MetaMask', 'error');
        return;
    }
    var btn = $('connectBtn');
    btn.textContent = '连接中...';
    btn.disabled = true;

    try {
        var accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
        account = accounts[0];
        provider = new ethers.providers.Web3Provider(window.ethereum);
        signer = provider.getSigner();

        // 检测网络
        var network = await provider.getNetwork();
        currentChainId = network.chainId;

        if (currentChainId === LOCAL_CHAIN_ID) {
            // 本地 Anvil 网络
            ADDRESSES = { ...LOCAL_ADDRESSES };
            $('networkBadge').textContent = 'Local Anvil';
            $('networkBadge').className = 'network-badge success';
        } else if (currentChainId === SEPOLIA_CHAIN_ID) {
            // Sepolia
            ADDRESSES = { ...SEPOLIA_ADDRESSES };
            $('networkBadge').textContent = 'Sepolia';
            $('networkBadge').className = 'network-badge success';
        } else {
            // 尝试切换到本地网络（优先用于测试）
            try {
                await window.ethereum.request({
                    method: 'wallet_switchEthereumChain',
                    params: [{ chainId: '0x7a69' }], // 31337
                });
                await new Promise(r => setTimeout(r, 1000));
                provider = new ethers.providers.Web3Provider(window.ethereum);
                signer = provider.getSigner();
                network = await provider.getNetwork();
                currentChainId = network.chainId;
                if (currentChainId === LOCAL_CHAIN_ID) {
                    ADDRESSES = { ...LOCAL_ADDRESSES };
                    $('networkBadge').textContent = 'Local Anvil';
                    $('networkBadge').className = 'network-badge success';
                } else {
                    throw new Error('switch failed');
                }
            } catch(e) {
                // 本地网络不存在，尝试Sepolia
                try {
                    await window.ethereum.request({
                        method: 'wallet_switchEthereumChain',
                        params: [{ chainId: '0xaa36a7' }],
                    });
                    await new Promise(r => setTimeout(r, 1000));
                    provider = new ethers.providers.Web3Provider(window.ethereum);
                    signer = provider.getSigner();
                    ADDRESSES = { ...SEPOLIA_ADDRESSES };
                    $('networkBadge').textContent = 'Sepolia';
                    $('networkBadge').className = 'network-badge success';
                } catch(e2) {
                    showToast('请切换到 Sepolia 或本地 Anvil 网络', 'error');
                    btn.textContent = '连接钱包';
                    btn.disabled = false;
                    return;
                }
            }
        }

        btn.textContent = account.slice(0,6) + '...' + account.slice(-4);
        btn.disabled = false;

        hide('connectPrompt');
        show('accountCard');
        show('mainTabs');
        switchTab('deposit');

        $('accountAddr').textContent = account;
        setText('vaultAddr', ADDRESSES.vault.slice(0,10) + '...' + ADDRESSES.vault.slice(-6));

        showToast('钱包连接成功 (' + $('networkBadge').textContent + ')', 'success');

        // 从localStorage读取deploy.html部署的新地址（如果有，覆盖当前网络地址）
        try {
            const saved = localStorage.getItem('deployed_addresses');
            if (saved) {
                const s = JSON.parse(saved);
                if (s.VAULT) ADDRESSES.vault = s.VAULT;
                if (s.ORACLE) ADDRESSES.oracle = s.ORACLE;
                if (s.STRAT) ADDRESSES.strategy = s.STRAT;
                if (s.GOV) ADDRESSES.governance = s.GOV;
                if (s.GOV_TOKEN) ADDRESSES.govToken = s.GOV_TOKEN;
                if (s.INCENTIVES) ADDRESSES.incentives = s.INCENTIVES;
                console.log('Loaded addresses from localStorage:', ADDRESSES);
            }
        } catch(e) { console.warn('Failed to load localStorage addresses:', e); }

        try {
            C = {
                vault: new ethers.Contract(ADDRESSES.vault, VAULT_ABI, signer),
                weth: new ethers.Contract(ADDRESSES.weth, ERC20_ABI, signer),
                usdc: new ethers.Contract(ADDRESSES.usdc, ERC20_ABI, signer),
                oracle: new ethers.Contract(ADDRESSES.oracle, ORACLE_ABI, signer),
                governance: new ethers.Contract(ADDRESSES.governance, GOV_ABI, signer),
                incentives: new ethers.Contract(ADDRESSES.incentives, INCENTIVES_ABI, signer),
                govToken: new ethers.Contract(ADDRESSES.govToken, GOV_TOKEN_ABI, signer),
            };
            // 读取token0/token1顺序（与合约逻辑一致）
            try {
                token0IsWeth = await C.vault.TOKEN0_IS_WETH();
                console.log('[Vault] TOKEN0_IS_WETH =', token0IsWeth);
            } catch(e) {
                console.warn('[Vault] Failed to read TOKEN0_IS_WETH, defaulting to false (token0=USDC):', e.message);
                token0IsWeth = false;
            }
        } catch(e) {
            console.error('Contract init error:', e);
            showToast('合约初始化失败: ' + e.message, 'error');
        }

        loadAllData();

        window.ethereum.on('accountsChanged', function() { window.location.reload(); });
        window.ethereum.on('chainChanged', function() { window.location.reload(); });

        if (refreshTimer) clearInterval(refreshTimer);
        refreshTimer = setInterval(function() { if (account) loadAllData(true); }, 15000);

    } catch(e) {
        console.error('Connect error:', e);
        showToast('连接失败: ' + (e.message || e), 'error');
        btn.textContent = '连接钱包';
        btn.disabled = false;
    }
}

function switchTab(tabId) {
    document.querySelectorAll('.tab').forEach(function(t) { t.classList.remove('active'); });
    document.querySelectorAll('.tab-content').forEach(function(c) { c.classList.remove('active'); });
    var tabBtn = document.querySelector('[data-tab="' + tabId + '"]');
    if (tabBtn) tabBtn.classList.add('active');
    var tabContent = $(tabId + 'Tab');
    if (tabContent) tabContent.classList.add('active');
}

// ============================================================
// 数据加载
// ============================================================
function loadAllData(silent) {
    if (!account) return;
    if (!silent) console.log('[Vault] Loading data...');
    safeCall(loadTokenBalances);
    safeCall(loadTWAPPrice);
    safeCall(loadVaultData);
    safeCall(loadGovernanceParams);
    safeCall(loadDistribution);
    safeCall(loadIncentivesData);
    safeCall(loadGovTokenBalance);
}

function safeCall(fn) {
    try {
        var r = fn();
        if (r && r.catch) r.catch(function(e) { console.error(fn.name, 'error:', e); });
    } catch(e) {
        console.error(fn.name, 'sync error:', e);
    }
}

async function loadTokenBalances() {
    try {
        var wethBal = await C.weth.balanceOf(account);
        var usdcBal = await C.usdc.balanceOf(account);
        var wethStr = parseFloat(ethers.utils.formatEther(wethBal)).toFixed(4);
        var usdcStr = parseFloat(ethers.utils.formatUnits(usdcBal,6)).toFixed(2);
        setText('wethBalance', wethStr + ' WETH');
        setText('usdcBalance', usdcStr + ' USDC');
        setText('wethMaxHint', '余额: ' + wethStr);
        setText('usdcMaxHint', '余额: ' + usdcStr);
    } catch(e) {
        console.error('Token balances:', e.message);
        setText('wethBalance', '加载失败');
        setText('usdcBalance', '加载失败');
    }
}

async function loadTWAPPrice() {
    try {
        var result = await C.oracle.getTWAPPrice();
        if (result && result[0] && result[0].gt(0)) {
            twapPrice = calcPrice(result[0]);
            // 价格合理性检查：Sepolia测试网池子流动性差，价格可能异常
            if (twapPrice > 10 && twapPrice < 100000) {
                var p = '$' + twapPrice.toFixed(2);
                setText('twapPrice', p);
                setText('depositPrice', '1 ETH = ' + p);
            } else {
                // 价格异常，显示警告
                setText('twapPrice', '异常 ⚠️');
                setText('depositPrice', '价格异常 (测试网流动性不足)');
                console.warn('TWAP price abnormal:', twapPrice, 'tick:', result[1]);
            }
        } else {
            setText('twapPrice', '无数据');
            setText('depositPrice', '-');
        }
    } catch(e) {
        console.error('TWAP:', e.message);
        setText('twapPrice', '待就绪');
        setText('depositPrice', 'Oracle初始化中...');
    }
}

async function loadVaultData() {
    // 1. 先加载份额（最核心，单独处理，不依赖其他数据）
    let sharesF = 0;
    let tsF = 0;
    try {
        const shares = await C.vault.balanceOf(account);
        const totalSupply = await C.vault.totalSupply();
        sharesF = parseFloat(ethers.utils.formatUnits(shares, 6));
        tsF = parseFloat(ethers.utils.formatUnits(totalSupply, 6));
        setText('vaultShares', sharesF.toFixed(4) + ' ALP');
        setText('sharesMaxHint', '余额: ' + sharesF.toFixed(4));
    } catch(e) {
        console.error('Vault shares:', e.message);
        setText('vaultShares', '未部署');
        setText('sharesMaxHint', '');
    }

    // 2. 加载TVL和持仓价值（依赖oracle，可能失败）
    try {
        const tvl = await C.vault.totalAssets();
        const tvlF = parseFloat(ethers.utils.formatUnits(tvl,6));
        setText('tvl', '$' + tvlF.toFixed(2));

        let userValueStr = "0.00";
        if (sharesF > 1e-9 && tsF > 1e-9 && tvlF > 0) {
            const userVal = sharesF / tsF * tvlF;
            userValueStr = userVal.toFixed(2);
        }
        setText('totalAssets', '$' + userValueStr);
    } catch(e) {
        console.error('Vault TVL:', e.message);
        setText('tvl', '待数据');
        setText('totalAssets', '待数据');
    }

    // 3. 加载再平衡统计
    try {
        const reCount = await C.vault.rebalanceCount();
        const fees = await C.vault.cumulativeFeesUSDC();
        setText('rebalanceCount', reCount.toString());
        setText('cumulativeFees', '$' + parseFloat(ethers.utils.formatUnits(fees,6)).toFixed(4));
    } catch(e) {
        console.error('Vault stats:', e.message);
        setText('rebalanceCount', '-');
        setText('cumulativeFees', '-');
    }

    // 4. 更新预估（失败不影响主数据）
    try {
        updateDepositEstimate();
        updateWithdrawEstimate();
    } catch(e) {
        console.error('Vault estimate:', e.message);
    }
}

async function loadDistribution() {
    try {
        var d = await C.vault.getDistribution();
        var idleWeth=d[0], idleUsdc=d[1], v2Weth=d[2], v2Usdc=d[3], v3lWeth=d[4], v3lUsdc=d[5], v3hWeth=d[6], v3hUsdc=d[7];

        function w2u(bn) {
            if (!twapPrice || twapPrice <= 0) return ethers.BigNumber.from(0);
            return bn.mul(Math.floor(twapPrice * 10000)).div(10000).mul(1e6).div(1e18);
        }

        var idle = idleUsdc.add(w2u(idleWeth));
        var v2 = v2Usdc.add(w2u(v2Weth));
        var v3l = v3lUsdc.add(w2u(v3lWeth));
        var v3h = v3hUsdc.add(w2u(v3hWeth));
        var total = idle.add(v2).add(v3l).add(v3h);

        if (total.gt(0)) {
            function pct(bn) { return bn.mul(10000).div(total).toNumber() / 100; }
            var pI=pct(idle), pV2=pct(v2), pL=pct(v3l), pH=pct(v3h);
            $('segIdle').style.width = pI + '%';
            $('segV2').style.width = pV2 + '%';
            $('segV3Low').style.width = pL + '%';
            $('segV3High').style.width = pH + '%';
            setText('pctIdle', pI.toFixed(1) + '%');
            setText('pctV2', pV2.toFixed(1) + '%');
            setText('pctV3Low', pL.toFixed(1) + '%');
            setText('pctV3High', pH.toFixed(1) + '%');
            $('distDetails').innerHTML =
                '<div class="dist-row"><span class="dot idle"></span>闲置: <b>$'+(parseFloat(ethers.utils.formatUnits(idle,6))).toFixed(2)+'</b> ('+pI.toFixed(1)+'%)</div>' +
                '<div class="dist-row"><span class="dot v2"></span>V2: <b>$'+(parseFloat(ethers.utils.formatUnits(v2,6))).toFixed(2)+'</b> ('+pV2.toFixed(1)+'%)</div>' +
                '<div class="dist-row"><span class="dot v3low"></span>V3 0.05%: <b>$'+(parseFloat(ethers.utils.formatUnits(v3l,6))).toFixed(2)+'</b> ('+pL.toFixed(1)+'%)</div>' +
                '<div class="dist-row"><span class="dot v3high"></span>V3 0.30%: <b>$'+(parseFloat(ethers.utils.formatUnits(v3h,6))).toFixed(2)+'</b> ('+pH.toFixed(1)+'%)</div>';
        } else {
            $('distDetails').innerHTML = '<p class="hint">金库暂无资金</p>';
        }
    } catch(e) {
        console.error('Distribution:', e.message);
        $('distDetails').innerHTML = '<p class="hint">金库未部署</p>';
    }
}

async function loadGovernanceParams() {
    try {
        var p = await C.governance.getParams();
        function pct(v) { return (v/100).toFixed(1) + '%'; }
        setText('paramThreshold', pct(p.rebalanceThreshold));
        setText('paramIncentive', pct(p.incentiveBps));
        setText('paramSlippage', pct(p.maxSlippageBps));
        setText('paramTwap', p.twapWindow + 's');
        setText('paramTight', pct(p.tightRangeBps));
        setText('paramWide', pct(p.wideRangeBps));
        $('govParamsTable').innerHTML =
            '<div class="param-row"><span>TWAP窗口</span><b>'+p.twapWindow+'s ('+(p.twapWindow/60).toFixed(0)+'min)</b></div>' +
            '<div class="param-row"><span>再平衡阈值</span><b>'+pct(p.rebalanceThreshold)+'</b></div>' +
            '<div class="param-row"><span>激励比例</span><b>'+pct(p.incentiveBps)+'</b></div>' +
            '<div class="param-row"><span>最大滑点</span><b>'+pct(p.maxSlippageBps)+'</b></div>' +
            '<div class="param-row"><span>V2权重上限</span><b>'+(p.v2WeightCap/100).toFixed(0)+'%</b></div>' +
            '<div class="param-row"><span>V3低费率上限</span><b>'+(p.v3LowFeeWeightCap/100).toFixed(0)+'%</b></div>' +
            '<div class="param-row"><span>V3高费率上限</span><b>'+(p.v3HighFeeWeightCap/100).toFixed(0)+'%</b></div>' +
            '<div class="param-row"><span>窄区间</span><b>±'+(p.tightRangeBps/100).toFixed(0)+'%</b></div>' +
            '<div class="param-row"><span>中区间</span><b>±'+(p.mediumRangeBps/100).toFixed(0)+'%</b></div>' +
            '<div class="param-row"><span>宽区间</span><b>±'+(p.wideRangeBps/100).toFixed(0)+'%</b></div>';
    } catch(e) {
        console.error('Gov params:', e.message);
        ['paramThreshold','paramIncentive','paramSlippage','paramTwap','paramTight','paramWide'].forEach(function(id){ setText(id,'-'); });
    }
}

async function loadIncentivesData() {
    try {
        var rewards = await C.incentives.rewardsEarned(account);
        var bps = await C.incentives.incentiveBps();
        var canReb = await C.incentives.canRebalance();
        var lastTime = await C.incentives.lastRebalanceTime();
        var cooldown = await C.incentives.cooldownPeriod();

        setText('rbRewards', '$' + parseFloat(ethers.utils.formatUnits(rewards,6)).toFixed(4));
        setText('rbIncentiveBps', (bps/100).toFixed(1) + '%');

        if (lastTime.eq(0)) {
            setText('cooldownStatus', '✅ 可触发（首次）');
        } else if (canReb) {
            setText('cooldownStatus', '✅ 可触发');
        } else {
            var elapsed = Math.floor(Date.now()/1000) - lastTime.toNumber();
            var remain = cooldown.toNumber() - elapsed;
            setText('cooldownStatus', remain > 0 ? '⏳ 冷却中 '+remain+'s' : '✅ 可触发');
        }
    } catch(e) {
        console.error('Incentives:', e.message);
        setText('rbRewards', '-');
        setText('rbIncentiveBps', '-');
        setText('cooldownStatus', '-');
    }
}

async function loadGovTokenBalance() {
    try {
        var bal = await C.govToken.balanceOf(account);
        setText('govBalance', ethers.utils.formatEther(bal) + ' ALP-GOV');
    } catch(e) {
        setText('govBalance', '0 ALP-GOV');
    }
}

// ============================================================
// 预估计算（全部BigNumber，规避JS Number溢出）
// ============================================================
async function updateDepositEstimate() {
    const wethAmtText = $('depositWeth').value || "0";
    const usdcAmtText = $('depositUsdc').value || "0";

    const wethWei = ethers.utils.parseEther(wethAmtText);
    const usdcWei = ethers.utils.parseUnits(usdcAmtText,6);

    if(wethWei.isZero() && usdcWei.isZero()){
        setText('estimatedShares', '0 ALP');
        setText('sharePct', '0%');
        return;
    }
    try {
        const totalAssetsBN = await C.vault.totalAssets();
        const totalSupplyBN = await C.vault.totalSupply();

        let depositValueUSD = usdcWei;
        if(twapPrice > 0){
            const priceScaled = ethers.BigNumber.from(Math.round(twapPrice * 100));
            const wethValue = wethWei.mul(priceScaled).div(ethers.BigNumber.from("100").mul(ethers.BigNumber.from(10).pow(12)));
            depositValueUSD = depositValueUSD.add(wethValue);
        }

        let newSharesBN;
        if(totalSupplyBN.isZero() || totalAssetsBN.isZero()){
            newSharesBN = depositValueUSD;
        }else{
            newSharesBN = depositValueUSD.mul(totalSupplyBN).div(totalAssetsBN);
        }

        const newSharesStr = ethers.utils.formatUnits(newSharesBN,6);
        setText('estimatedShares', parseFloat(newSharesStr).toFixed(4) + ' ALP');

        const totalAfter = totalSupplyBN.add(newSharesBN);
        let pct = ethers.BigNumber.from(0);
        if(!totalAfter.isZero()){
            pct = newSharesBN.mul(ethers.BigNumber.from(10000)).div(totalAfter);
        }
        const pctNum = pct.toNumber() / 100;
        setText('sharePct', pctNum.toFixed(2)+'%');

    } catch(e) {
        console.error("updateDepositEstimate error",e);
        setText('estimatedShares', '计算失败');
    }
}

async function updateWithdrawEstimate() {
    const sharesText = $('withdrawShares').value || "0";
    const sharesWei = ethers.utils.parseUnits(sharesText,6);

    if (sharesWei.isZero()) {
        setText('estimatedWeth', '-');
        setText('estimatedUsdc', '-');
        setText('withdrawPct', '0%');
        return;
    }
    try {
        const totalSupplyBN = await C.vault.totalSupply();
        const d = await C.vault.getDistribution();

        const totalWeth = d[0].add(d[2]).add(d[4]).add(d[6]);
        const totalUsdc = d[1].add(d[3]).add(d[5]).add(d[7]);

        if(totalSupplyBN.isZero()){
            setText('estimatedWeth','0 WETH');
            setText('estimatedUsdc','0 USDC');
            setText('withdrawPct','0%');
            return;
        }

        const ratioScale = ethers.BigNumber.from(10).pow(18);
        const ratioScaled = sharesWei.mul(ratioScale).div(totalSupplyBN);

        const outWeth = totalWeth.mul(ratioScaled).div(ratioScale);
        const outUsdc = totalUsdc.mul(ratioScaled).div(ratioScale);

        const wethDisplay = parseFloat(ethers.utils.formatEther(outWeth)).toFixed(6);
        const usdcDisplay = parseFloat(ethers.utils.formatUnits(outUsdc,6)).toFixed(2);
        const pct = sharesWei.mul(ethers.BigNumber.from(10000)).div(totalSupplyBN).toNumber()/100;

        setText('estimatedWeth', wethDisplay + ' WETH');
        setText('estimatedUsdc', usdcDisplay + ' USDC');
        setText('withdrawPct', pct.toFixed(2)+'%');
    } catch(e) {
        console.error("updateWithdrawEstimate",e);
        setText('estimatedWeth', '-');
        setText('estimatedUsdc', '-');
    }
}

// ============================================================
// 交易
// ============================================================
async function setMaxWeth() {
    try {
        var bal = await C.weth.balanceOf(account);
        $('depositWeth').value = ethers.utils.formatEther(bal);
        updateDepositEstimate();
    } catch(e) { showToast('获取余额失败', 'error'); }
}
async function setMaxUsdc() {
    try {
        var bal = await C.usdc.balanceOf(account);
        $('depositUsdc').value = ethers.utils.formatUnits(bal, 6);
        updateDepositEstimate();
    } catch(e) { showToast('获取余额失败', 'error'); }
}
async function setMaxShares() {
    try {
        var bal = await C.vault.balanceOf(account);
        $('withdrawShares').value = ethers.utils.formatUnits(bal, 6);
        updateWithdrawEstimate();
    } catch(e) { showToast('获取余额失败', 'error'); }
}

async function deposit() {
    var wethAmt = $('depositWeth').value;
    var usdcAmt = $('depositUsdc').value;
    if (!wethAmt && !usdcAmt) { showToast('请输入数量', 'error'); return; }
    try {
        var wethWei = ethers.utils.parseEther(wethAmt || '0');
        var usdcWei = ethers.utils.parseUnits(usdcAmt || '0', 6);
        if (wethWei.eq(0) && usdcWei.eq(0)) { showToast('请输入有效数量', 'error'); return; }

        var wethBal = await C.weth.balanceOf(account);
        var usdcBal = await C.usdc.balanceOf(account);
        if (wethWei.gt(wethBal)) { showToast('WETH余额不足', 'error'); return; }
        if (usdcWei.gt(usdcBal)) { showToast('USDC余额不足', 'error'); return; }

        if (wethWei.gt(0)) {
            showTxModal('授权 WETH', '请在钱包中确认...');
            var al1 = await C.weth.allowance(account, ADDRESSES.vault);
            if (al1.lt(wethWei)) { var t1 = await C.weth.approve(ADDRESSES.vault, ethers.constants.MaxUint256); await t1.wait(); }
        }
        if (usdcWei.gt(0)) {
            showTxModal('授权 USDC', '请在钱包中确认...');
            var al2 = await C.usdc.allowance(account, ADDRESSES.vault);
            if (al2.lt(usdcWei)) { var t2 = await C.usdc.approve(ADDRESSES.vault, ethers.constants.MaxUint256); await t2.wait(); }
        }

        showTxModal('存入中', '请确认存款交易...');
        var tx = await C.vault.deposit(wethWei, usdcWei, 0);
        showTxModal('等待确认', '交易已提交...');
        await tx.wait();
        hideTxModal();
        showToast('✅ 存款成功', 'success');
        $('depositWeth').value = ''; $('depositUsdc').value = '';
        loadAllData();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '未知错误';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else showToast('存款失败: ' + msg.substring(0,80), 'error');
    }
}

async function withdraw() {
    var shares = $('withdrawShares').value;
    if (!shares || parseFloat(shares) <= 0) { showToast('请输入份额', 'error'); return; }
    try {
        var sharesWei = ethers.utils.parseUnits(shares, 6);
        var bal = await C.vault.balanceOf(account);
        if (sharesWei.gt(bal)) { showToast('份额不足', 'error'); return; }

        // 计算预计输出，设置1%滑点保护
        var totalSupplyBN = await C.vault.totalSupply();
        var d = await C.vault.getDistribution();
        var totalWeth = d[0].add(d[2]).add(d[4]).add(d[6]);
        var totalUsdc = d[1].add(d[3]).add(d[5]).add(d[7]);
        var ratioScale = ethers.BigNumber.from(10).pow(18);
        var ratioScaled = sharesWei.mul(ratioScale).div(totalSupplyBN);
        var outWeth = totalWeth.mul(ratioScaled).div(ratioScale);
        var outUsdc = totalUsdc.mul(ratioScaled).div(ratioScale);
        // 允许1%滑点
        var minWeth = outWeth.mul(99).div(100);
        var minUsdc = outUsdc.mul(99).div(100);

        showTxModal('赎回中', '请确认交易...');
        var tx = await C.vault.withdrawDual(sharesWei, minWeth, minUsdc);
        await tx.wait();
        hideTxModal();
        showToast('✅ 赎回成功', 'success');
        $('withdrawShares').value = '';
        loadAllData();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '未知错误';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else if (msg.indexOf('SlippageExceeded') >= 0) showToast('滑点超限，请调整滑点容忍度或稍后重试', 'error');
        else showToast('赎回失败: ' + msg.substring(0,80), 'error');
    }
}

async function triggerRebalance() {
    try {
        showTxModal('再平衡', '请确认交易...');
        var tx = await C.vault.rebalance();
        await tx.wait();
        hideTxModal();
        showToast('✅ 再平衡成功', 'success');
        loadAllData();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else if (msg.indexOf('ooldown') >= 0) showToast('冷却期未结束', 'warn');
        else showToast('再平衡失败: ' + msg.substring(0,80), 'error');
    }
}

async function claimRewards() {
    try {
        showTxModal('领取奖励', '请确认...');
        var tx = await C.incentives.claimReward();
        await tx.wait();
        hideTxModal();
        showToast('✅ 领取成功', 'success');
        loadAllData();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else showToast('领取失败: ' + msg.substring(0,80), 'error');
    }
}

function copyVaultAddr() {
    navigator.clipboard.writeText(ADDRESSES.vault).then(function() {
        showToast('金库地址已复制', 'success');
    });
}

// ============================================================
// 价格计算
// ============================================================
// Uniswap V3: sqrtPriceX96 = sqrt(price) * 2^96
// price = token1_raw / token0_raw
// 当token0=USDC(6位), token1=WETH(18位)时：
//   1 WETH = 2^192 * 1e12 / sqrtPriceX96^2 USDC
// 当token0=WETH(18位), token1=USDC(6位)时：
//   1 WETH = sqrtPriceX96^2 * 1e12 / 2^192 USDC
function calcPrice(sqrtPriceX96) {
    var Q192 = ethers.BigNumber.from(2).pow(192);
    var PRICE_SCALE = ethers.BigNumber.from('1000000000000'); // 1e12 = 1e18 / 1e6
    var priceSquared = sqrtPriceX96.mul(sqrtPriceX96);

    var usdcRawPerWeth;
    if (token0IsWeth) {
        // token0=WETH, token1=USDC: USDC_raw = WETH_raw * price = WETH_raw * priceSquared / Q192
        usdcRawPerWeth = priceSquared.mul(PRICE_SCALE).div(Q192);
    } else {
        // token0=USDC, token1=WETH: USDC_raw = WETH_raw / price = WETH_raw * Q192 / priceSquared
        usdcRawPerWeth = Q192.mul(PRICE_SCALE).div(priceSquared);
    }

    // usdcRawPerWeth是USDC最小单位(6位小数)，除以1e6得到人类可读价格
    // 用字符串方式避免JS Number溢出
    var priceStr = usdcRawPerWeth.toString();
    if (priceStr.length <= 6) {
        return parseFloat('0.' + priceStr.padStart(6, '0'));
    }
    var intPart = priceStr.slice(0, -6);
    var decPart = priceStr.slice(-6);
    return parseFloat(intPart + '.' + decPart);
}