// ============================================================
// Adaptive LP Vault Frontend v3
// ============================================================
const SEPOLIA_CHAIN_ID = 11155111;

const ADDRESSES = {
    vault: '0x8b7b69F71C9180ED361D87DfE474C74D27D42a3c',
    weth: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
    usdc: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
    oracle: '0x4659f77979bA3df083bD4BD91acB7275F78EF7ab',
    strategy: '0x35Cbad54F00E47cE43Cde2d6462cFd8967d2fDDD',
    governance: '0x0fFAc18bCCC96Cd6b0c8cB7d1D40a657d207eC6c',
    incentives: '0x4Bda8D9B39cDB0Ef17A9781C3Cc6646A2b735EFD',
    govToken: '0x6C7eB107B9969F455F0890fd36140aB21bC1747C',
};

// 从localStorage读取deploy.html部署的新地址（如果有）
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

const ERC20_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function approve(address spender, uint256 amount) returns (bool)',
    'function allowance(address owner, address spender) view returns (uint256)',
    'function decimals() view returns (uint8)',
];
const VAULT_ABI = [
    'function deposit(uint256 wethAmount, uint256 usdcAmount, uint256 minShares)',
    'function withdraw(uint256 shares, uint256 minWeth, uint256 minUsdc)',
    'function totalAssets() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function totalSupply() view returns (uint256)',
    'function rebalance()',
    'function rebalanceCount() view returns (uint256)',
    'function cumulativeFeesUSDC() view returns (uint256)',
    'function getDistribution() view returns (uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
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

        // 检查/切换网络
        var network = await provider.getNetwork();
        if (network.chainId !== SEPOLIA_CHAIN_ID) {
            try {
                await window.ethereum.request({
                    method: 'wallet_switchEthereumChain',
                    params: [{ chainId: '0xaa36a7' }],
                });
                // 切换后等一下让网络生效
                await new Promise(r => setTimeout(r, 1000));
                provider = new ethers.providers.Web3Provider(window.ethereum);
                signer = provider.getSigner();
            } catch(e) {
                showToast('请手动切换到 Sepolia 测试网', 'error');
                btn.textContent = '连接钱包';
                btn.disabled = false;
                return;
            }
        }

        // === 先更新UI（这部分不依赖合约，一定能成功）===
        $('networkBadge').textContent = 'Sepolia';
        $('networkBadge').className = 'network-badge success';
        btn.textContent = account.slice(0,6) + '...' + account.slice(-4);
        btn.disabled = false;

        hide('connectPrompt');
        show('accountCard');
        show('mainTabs');
        switchTab('deposit');

        $('accountAddr').textContent = account;
        setText('vaultAddr', ADDRESSES.vault.slice(0,10) + '...' + ADDRESSES.vault.slice(-6));

        showToast('钱包连接成功', 'success');

        // === 初始化合约（独立try-catch，失败不影响UI）===
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
        } catch(e) {
            console.error('Contract init error:', e);
            showToast('合约初始化失败: ' + e.message, 'error');
        }

        // === 加载数据（每个独立，互不影响）===
        loadAllData();

        // 监听变化
        window.ethereum.on('accountsChanged', function() { window.location.reload(); });
        window.ethereum.on('chainChanged', function() { window.location.reload(); });

        // 自动刷新
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
// 数据加载（每个函数完全独立，一个失败不影响其他）
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
        var usdcStr = (usdcBal / 1e6).toFixed(2);
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
            var p = '$' + twapPrice.toFixed(2);
            setText('twapPrice', p);
            setText('depositPrice', '1 ETH = ' + p);
        } else {
            setText('twapPrice', '无数据');
            setText('depositPrice', '-');
        }
    } catch(e) {
        console.error('TWAP:', e.message);
        setText('twapPrice', '未部署');
        setText('depositPrice', 'Oracle未就绪');
    }
}

async function loadVaultData() {
    try {
        var shares = await C.vault.balanceOf(account);
        var tvl = await C.vault.totalAssets();
        var totalSupply = await C.vault.totalSupply();
        var reCount = await C.vault.rebalanceCount();
        var fees = await C.vault.cumulativeFeesUSDC();

        var sharesF = parseFloat(ethers.utils.formatEther(shares));
        var tvlF = tvl / 1e6;
        var tsF = parseFloat(ethers.utils.formatEther(totalSupply));

        setText('vaultShares', sharesF.toFixed(4) + ' ALP');
        setText('totalAssets', '$' + (sharesF > 0 && tsF > 0 ? (sharesF / tsF * tvlF).toFixed(2) : '0.00'));
        setText('tvl', '$' + tvlF.toFixed(2));
        setText('rebalanceCount', reCount.toString());
        setText('cumulativeFees', '$' + (fees / 1e6).toFixed(4));
        setText('sharesMaxHint', '余额: ' + sharesF.toFixed(4));

        updateDepositEstimate();
        updateWithdrawEstimate();
    } catch(e) {
        console.error('Vault data:', e.message);
        setText('vaultShares', '未部署');
        setText('tvl', '未部署');
        setText('rebalanceCount', '-');
        setText('cumulativeFees', '-');
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
                '<div class="dist-row"><span class="dot idle"></span>闲置: <b>$'+(idle/1e6).toFixed(2)+'</b> ('+pI.toFixed(1)+'%)</div>' +
                '<div class="dist-row"><span class="dot v2"></span>V2: <b>$'+(v2/1e6).toFixed(2)+'</b> ('+pV2.toFixed(1)+'%)</div>' +
                '<div class="dist-row"><span class="dot v3low"></span>V3 0.05%: <b>$'+(v3l/1e6).toFixed(2)+'</b> ('+pL.toFixed(1)+'%)</div>' +
                '<div class="dist-row"><span class="dot v3high"></span>V3 0.30%: <b>$'+(v3h/1e6).toFixed(2)+'</b> ('+pH.toFixed(1)+'%)</div>';
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

        setText('rbRewards', '$' + (rewards/1e6).toFixed(4));
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
// 预估计算
// ============================================================
async function updateDepositEstimate() {
    var wethAmt = parseFloat($('depositWeth').value) || 0;
    var usdcAmt = parseFloat($('depositUsdc').value) || 0;
    if (wethAmt === 0 && usdcAmt === 0) {
        setText('estimatedShares', '0 ALP'); setText('sharePct', '0%'); return;
    }
    try {
        var tvl = await C.vault.totalAssets();
        var totalSupply = await C.vault.totalSupply();
        var tvlF = tvl.toNumber() / 1e6;
        var tsF = parseFloat(ethers.utils.formatEther(totalSupply));
        var depVal = usdcAmt + (twapPrice > 0 ? wethAmt * twapPrice : 0);
        var newShares = (tsF === 0 || tvlF === 0) ? depVal : (depVal / tvlF) * tsF;
        var pct = tsF > 0 ? (newShares / (tsF + newShares) * 100) : 100;
        setText('estimatedShares', newShares.toFixed(4) + ' ALP');
        setText('sharePct', pct.toFixed(2) + '%');
    } catch(e) {
        setText('estimatedShares', '需先部署金库');
    }
}

async function updateWithdrawEstimate() {
    var sharesAmt = parseFloat($('withdrawShares').value) || 0;
    if (sharesAmt === 0) {
        setText('estimatedWeth', '-'); setText('estimatedUsdc', '-'); setText('withdrawPct', '0%'); return;
    }
    try {
        var totalSupply = await C.vault.totalSupply();
        var d = await C.vault.getDistribution();
        var tsF = parseFloat(ethers.utils.formatEther(totalSupply));
        var ratio = tsF > 0 ? sharesAmt / tsF : 0;
        var totalWeth = d[0].add(d[2]).add(d[4]).add(d[6]);
        var totalUsdc = d[1].add(d[3]).add(d[5]).add(d[7]);
        setText('estimatedWeth', (parseFloat(ethers.utils.formatEther(totalWeth)) * ratio).toFixed(6) + ' WETH');
        setText('estimatedUsdc', (totalUsdc.toNumber()/1e6 * ratio).toFixed(2) + ' USDC');
        setText('withdrawPct', (ratio*100).toFixed(2) + '%');
    } catch(e) {
        setText('estimatedWeth', '-'); setText('estimatedUsdc', '-');
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
        $('depositUsdc').value = (bal / 1e6).toString();
        updateDepositEstimate();
    } catch(e) { showToast('获取余额失败', 'error'); }
}
async function setMaxShares() {
    try {
        var bal = await C.vault.balanceOf(account);
        $('withdrawShares').value = ethers.utils.formatEther(bal);
        updateWithdrawEstimate();
    } catch(e) { showToast('获取份额失败', 'error'); }
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
        var sharesWei = ethers.utils.parseEther(shares);
        var bal = await C.vault.balanceOf(account);
        if (sharesWei.gt(bal)) { showToast('份额不足', 'error'); return; }
        showTxModal('赎回中', '请确认交易...');
        var tx = await C.vault.withdraw(sharesWei, 0, 0);
        await tx.wait();
        hideTxModal();
        showToast('✅ 赎回成功', 'success');
        $('withdrawShares').value = '';
        loadAllData();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '未知错误';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
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
function calcPrice(sqrtPriceX96) {
    // Sepolia/主网: token0=USDC(6位), token1=WETH(18位)
    // price = amount1/amount0 = WETH_raw/USDC_raw = sqrtPriceX96^2 / 2^192
    // 1 ETH = X USDC: 10^18/(X*10^6) = sqrtPriceX96^2/2^192
    // X = 10^12 * 2^192 / sqrtPriceX96^2
    var Q192 = ethers.BigNumber.from(2).pow(192);
    var numerator = Q192.mul(100000000000000); // 10^12 * 100 保留2位小数
    var denominator = sqrtPriceX96.mul(sqrtPriceX96);
    var priceScaled = numerator.div(denominator);
    return priceScaled.toNumber() / 100;
}
