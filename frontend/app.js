// ============================================================
// Adaptive LP Vault Frontend v5 (Local Anvil + Sepolia support)
// ============================================================
const SEPOLIA_CHAIN_ID = 11155111;
const LOCAL_CHAIN_ID = 31337;

// Sepolia 地址
const SEPOLIA_ADDRESSES = {
    vault: '0x8748D341274df6915bcbbA61f2fDaC337acf7A6F',
    weth: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
    usdc: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
    oracle: '0x84Fe1e0F45ADD448501326d4851A1F49BE2ab481',
    strategy: '0x15B07834C30e785d1B7eB6Fe042851895D15d910',
    governance: '0xd0b9F7eD49f01790Abe071E838e1eF3550d45EF6',
    incentives: '0xC2f7200cC9bd7c49DF58F2E93baB1C53261ABC4a',
    govToken: '0x91f7Fea94f59d898aAd8e6f4728eC35A2Caf3530',
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
    'function lastRebalanceTimestamp() view returns (uint256)',
];
const ORACLE_ABI = [
    'function getTWAPPrice() view returns (uint160 sqrtPriceX96, int24 tick)',
];
const GOV_ABI = [
    'function getParams() view returns (tuple(uint32 twapWindow, uint256 rebalanceThreshold, uint256 incentiveBps, uint256 maxSlippageBps, uint256 v2WeightCap, uint256 v3LowFeeWeightCap, uint256 v3HighFeeWeightCap, uint256 tightRangeBps, uint256 mediumRangeBps, uint256 wideRangeBps))',
    'function propose(uint8 pType, uint256 newValue, uint256 newValue2, uint256 newValue3, string description) returns (uint256)',
    'function castVote(uint256 proposalId, bool support)',
    'function getProposalState(uint256 proposalId) view returns (uint8)',
    'function executeProposal(uint256 proposalId)',
    'function executeTimelock(uint256 proposalId)',
    'function cancelProposal(uint256 proposalId)',
    'function proposalCount() view returns (uint256)',
    'function proposals(uint256) view returns (uint256 id, address proposer, uint8 pType, uint256 newValue, uint256 newValue2, uint256 newValue3, uint256 snapshot, uint256 startBlock, uint256 endBlock, uint256 forVotes, uint256 againstVotes, bool executed, bool canceled)',
    'function votingDelay() view returns (uint256)',
    'function votingPeriod() view returns (uint256)',
    'function proposalThreshold() view returns (uint256)',
    'function quorumVotes() view returns (uint256)',
    'function timelockDelay() view returns (uint256)',
    'function timelockActions(uint256) view returns (uint256 readyTime, uint8 pType, uint256 v1, uint256 v2, uint256 v3)',
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
    'function delegate(address delegatee)',
    'function delegates(address account) view returns (address)',
    'function getVotes(address account) view returns (uint256)',
    'function getPastVotes(address account, uint256 blockNumber) view returns (uint256)',
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

    // 3. 加载再平衡统计（分开try-catch，一个失败不影响另一个）
    // 3a. 再平衡次数
    try {
        const reCount = await C.vault.rebalanceCount();
        setText('rebalanceCount', reCount.toString());
    } catch(e) {
        console.error('rebalanceCount error:', e);
        setText('rebalanceCount', '-');
    }

    // 3b. 累计手续费
    try {
        const fees = await C.vault.cumulativeFeesUSDC();
        const feesStr = '$' + parseFloat(ethers.utils.formatUnits(fees,6)).toFixed(4);
        setText('cumulativeFees', feesStr); // 数据看板标签页
        setText('rbFees', feesStr);         // 再平衡标签页
    } catch(e) {
        console.error('cumulativeFeesUSDC error:', e);
        setText('cumulativeFees', '-');
        setText('rbFees', '-');
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
            return bn.mul(Math.floor(twapPrice * 10000)).div(10000).mul('1000000').div('1000000000000000000');
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

        setText('rbRewards', '$' + parseFloat(ethers.utils.formatUnits(rewards,6)).toFixed(4));
        setText('rbIncentiveBps', (bps/100).toFixed(1) + '%');

        // 冷却状态从金库读取（金库的REBALANCE_COOLDOWN=600秒才是真正控制rebalance的）
        var vaultLastRebalance = await C.vault.lastRebalanceTimestamp();
        var vaultCooldown = 600; // REBALANCE_COOLDOWN = 600秒

        if (vaultLastRebalance.eq(0)) {
            setText('cooldownStatus', '✅ 可触发（首次）');
        } else {
            var elapsed = Math.floor(Date.now()/1000) - vaultLastRebalance.toNumber();
            var remain = vaultCooldown - elapsed;
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
    loadDelegateStatus();
    loadProposals();
}

// ============================================================
// 治理功能
// ============================================================

// 提案类型名称映射
const PROPOSAL_TYPE_NAMES = [
    'TWAP 窗口',
    '再平衡阈值',
    '激励比例',
    '最大滑点',
    '权重上限',
    '区间范围'
];

// 提案状态名称映射
const PROPOSAL_STATE_NAMES = [
    '⏳ 等待投票',
    '🗳️ 投票中',
    '✅ 已通过',
    '✔️ 已执行',
    '❌ 未通过',
    '🚫 已取消'
];

// 提案类型改变时，显示/隐藏三值输入框
function onProposalTypeChange() {
    var type = parseInt($('proposalType').value);
    var singleGroup = $('singleValueGroup');
    var tripleGroup = $('tripleValueGroup');
    if (type === 4 || type === 5) {
        // 权重上限(4)和区间范围(5)需要三个值
        singleGroup.style.display = 'none';
        tripleGroup.style.display = 'block';
        if (type === 4) {
            $('label1').textContent = 'V2 权重上限 (bps)';
            $('label2').textContent = 'V3 低费率上限 (bps)';
            $('label3').textContent = 'V3 高费率上限 (bps)';
        } else {
            $('label1').textContent = '窄区间 (bps)';
            $('label2').textContent = '中区间 (bps)';
            $('label3').textContent = '宽区间 (bps)';
        }
    } else {
        // 其他类型只需要一个值
        singleGroup.style.display = 'block';
        tripleGroup.style.display = 'none';
    }
}

// 加载委托状态
async function loadDelegateStatus() {
    try {
        var delegatee = await C.govToken.delegates(account);
        if (delegatee === ethers.constants.AddressZero) {
            setText('delegateStatus', '❌ 未委托');
        } else if (delegatee.toLowerCase() === account.toLowerCase()) {
            setText('delegateStatus', '✅ 已委托给自己');
        } else {
            setText('delegateStatus', '✅ 已委托: ' + delegatee.substring(0,8) + '...');
        }
    } catch(e) {
        setText('delegateStatus', '-');
    }
}

// 委托投票权给自己
async function delegateVotes() {
    try {
        showTxModal('委托中', '请确认交易...');
        var tx = await C.govToken.delegate(account);
        await tx.wait();
        hideTxModal();
        showToast('委托成功！', 'success');
        loadDelegateStatus();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else showToast('委托失败: ' + msg.substring(0,80), 'error');
    }
}

// 创建提案
async function createProposal() {
    try {
        var type = parseInt($('proposalType').value);
        var desc = $('proposalDesc').value || '';
        var v1, v2, v3;

        if (type === 4 || type === 5) {
            v1 = ethers.BigNumber.from($('proposalValue1').value || '0');
            v2 = ethers.BigNumber.from($('proposalValue2').value || '0');
            v3 = ethers.BigNumber.from($('proposalValue3').value || '0');
        } else {
            v1 = ethers.BigNumber.from($('proposalValue1').value || '0');
            v2 = ethers.BigNumber.from(0);
            v3 = ethers.BigNumber.from(0);
        }

        showTxModal('创建提案中', '请确认交易...');
        var tx = await C.governance.propose(type, v1, v2, v3, desc);
        var receipt = await tx.wait();
        hideTxModal();

        // 从事件中获取提案ID
        var proposalId = 0;
        for (var i = 0; i < receipt.logs.length; i++) {
            try {
                var parsed = C.governance.interface.parseLog(receipt.logs[i]);
                if (parsed.name === 'ProposalCreated') {
                    proposalId = parsed.args.id.toString();
                    break;
                }
            } catch(e) {}
        }

        showToast('提案创建成功！ID: ' + proposalId, 'success');
        loadProposals();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else if (msg.indexOf('below proposal threshold') >= 0) showToast('治理代币不足，需要至少1000枚', 'error');
        else showToast('创建失败: ' + msg.substring(0,80), 'error');
    }
}

// 加载提案列表
async function loadProposals() {
    try {
        var count = await C.governance.proposalCount();
        var countNum = count.toNumber();

        if (countNum === 0) {
            $('proposalList').innerHTML = '<p class="hint">暂无提案</p>';
            return;
        }

        var html = '';
        for (var i = countNum; i >= 1; i--) {
            try {
                var p = await C.governance.proposals(i);
                var state = await C.governance.getProposalState(i);
                html += renderProposal(i, p, state);
            } catch(e) {
                console.error('Load proposal ' + i + ' error:', e);
            }
        }
        $('proposalList').innerHTML = html;
    } catch(e) {
        $('proposalList').innerHTML = '<p class="hint">加载失败: ' + e.message + '</p>';
    }
}

// 渲染单个提案
function renderProposal(id, p, state) {
    var typeName = PROPOSAL_TYPE_NAMES[p.pType] || ('类型' + p.pType);
    var stateName = PROPOSAL_STATE_NAMES[state] || ('状态' + state);
    var stateClass = state === 2 ? 'state-success' : (state === 3 ? 'state-executed' : (state === 4 ? 'state-fail' : 'state-pending'));

    // 提案值显示
    var valuesStr = '';
    if (p.pType === 4 || p.pType === 5) {
        valuesStr = '[' + p.newValue.toString() + ', ' + p.newValue2.toString() + ', ' + p.newValue3.toString() + ']';
    } else {
        valuesStr = p.newValue.toString();
    }

    var forVotes = ethers.utils.formatEther(p.forVotes);
    var againstVotes = ethers.utils.formatEther(p.againstVotes);

    // 操作按钮
    var actions = '';
    if (state === 1) {
        // 投票中
        actions = '<button class="btn btn-small btn-success" onclick="voteProposal(' + id + ', true)">👍 赞成</button>' +
                  '<button class="btn btn-small btn-danger" onclick="voteProposal(' + id + ', false)">👎 反对</button>';
    } else if (state === 2) {
        // 已通过，可执行
        actions = '<button class="btn btn-small btn-primary" onclick="executeProposal(' + id + ')">⚡ 执行提案</button>';
    } else if (state === 3) {
        // 已执行，检查时间锁
        actions = '<button class="btn btn-small btn-primary" onclick="executeTimelock(' + id + ')">⏰ 执行时间锁</button>';
    }

    return '<div class="proposal-card">' +
        '<div class="proposal-header">' +
            '<span class="proposal-id">#' + id + '</span>' +
            '<span class="proposal-type">' + typeName + '</span>' +
            '<span class="proposal-state ' + stateClass + '">' + stateName + '</span>' +
        '</div>' +
        '<div class="proposal-body">' +
            '<p><b>提议者:</b> ' + p.proposer.substring(0,10) + '...' + p.proposer.substring(p.proposer.length-6) + '</p>' +
            '<p><b>新值:</b> ' + valuesStr + '</p>' +
            '<p><b>赞成:</b> ' + parseFloat(forVotes).toFixed(2) + ' ALP-GOV | <b>反对:</b> ' + parseFloat(againstVotes).toFixed(2) + ' ALP-GOV</p>' +
            '<p><b>投票区块:</b> ' + p.startBlock.toString() + ' ~ ' + p.endBlock.toString() + '</p>' +
        '</div>' +
        '<div class="proposal-actions">' + actions + '</div>' +
    '</div>';
}

// 投票
async function voteProposal(id, support) {
    try {
        showTxModal('投票中', '请确认交易...');
        var tx = await C.governance.castVote(id, support);
        await tx.wait();
        hideTxModal();
        showToast(support ? '赞成投票成功！' : '反对投票成功！', 'success');
        loadProposals();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else if (msg.indexOf('no voting power') >= 0) showToast('没有投票权，请先委托投票权', 'error');
        else if (msg.indexOf('already voted') >= 0) showToast('您已经投过票了', 'error');
        else if (msg.indexOf('not active') >= 0) showToast('提案不在投票期', 'error');
        else showToast('投票失败: ' + msg.substring(0,80), 'error');
    }
}

// 执行提案
async function executeProposal(id) {
    try {
        showTxModal('执行提案中', '请确认交易...');
        var tx = await C.governance.executeProposal(id);
        await tx.wait();
        hideTxModal();
        showToast('提案执行成功！已加入48小时时间锁', 'success');
        loadProposals();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else if (msg.indexOf('not succeeded') >= 0) showToast('提案未通过，无法执行', 'error');
        else showToast('执行失败: ' + msg.substring(0,80), 'error');
    }
}

// 执行时间锁
async function executeTimelock(id) {
    try {
        showTxModal('执行时间锁中', '请确认交易...');
        var tx = await C.governance.executeTimelock(id);
        await tx.wait();
        hideTxModal();
        showToast('时间锁执行成功！参数已更新', 'success');
        loadProposals();
        loadGovernanceParams();
    } catch(e) {
        hideTxModal();
        var msg = (e.error && e.error.message) || e.message || '';
        if (msg.indexOf('user rejected') >= 0) showToast('交易已取消', 'warn');
        else if (msg.indexOf('timelock not ready') >= 0) showToast('时间锁未到期，请等待48小时', 'error');
        else showToast('执行失败: ' + msg.substring(0,80), 'error');
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
    var PRICE_SCALE = ethers.BigNumber.from('1000000000000000000'); // 1e18
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