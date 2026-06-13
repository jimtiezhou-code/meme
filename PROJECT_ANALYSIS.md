# Meme 发射平台 — 项目架构分析文档 (v2.0)

## 一、项目概述

这是一个基于 EVM 链的 Meme 发射平台，采用 **EIP-1167 最小代理（Minimal Proxy）** 模式，大幅降低 Meme 发行者的部署 Gas 成本。每个 Meme 都是一枚符合 ERC20 标准的代币，通过分批铸造（Fair Launch）方式实现公平发射。

**v2.0 新增特性：**
- 平台费率从 1% 调整为 **5%**，费用用于自动添加 Uniswap V2 流动性
- 每次 mint 自动将 5% ETH + 对应 Token 注入 Uniswap V2 LP（LP Token 永久锁定/销毁）
- 新增 `buyMeme()` 函数：当 Uniswap 市场价格优于 mint 价格时，用户可直接从池中购买

| 属性 | 说明 |
|------|------|
| 框架 | Foundry (Forge + Cast + Anvil) |
| Solidity 版本 | ^0.8.20 |
| 核心模式 | EIP-1167 Minimal Proxy / 工厂模式 |
| 外部依赖 | 仅 `forge-std`（测试），无 OpenZeppelin |
| Uniswap 集成 | Uniswap V2 Router / Factory / Pair（仅接口依赖） |

---

## 二、目录结构

```
meme/
├── foundry.toml                  # Foundry 构建配置
├── README.md                     # 项目说明
├── PROJECT_ANALYSIS.md           # ★ 本文档：完整架构分析
├── src/                          # ★ 合约源码
│   ├── ERC20.sol                 #    抽象基类：ERC20 标准实现
│   ├── MemeToken.sol             #    Meme 代币逻辑合约（被克隆）
│   ├── Clones.sol                #    EIP-1167 最小代理库
│   ├── MemeFactory.sol           #    工厂合约（用户入口，v2 核心）
│   └── interfaces/               #    Uniswap V2 接口
│       ├── IUniswapV2Router.sol  #        Router 接口
│       ├── IUniswapV2Factory.sol #        Factory 接口
│       └── IUniswapV2Pair.sol    #        Pair 接口
├── test/
│   ├── MemeFactory.t.sol         # 单元测试（33 个测试用例）
│   └── mocks/                    # 测试用 Mock 合约
│       ├── MockWETH.sol          #    WETH Mock
│       ├── MockUniswapV2Router.sol #  Router Mock
│       ├── MockUniswapV2Factory.sol # Factory Mock
│       └── MockUniswapV2Pair.sol #    Pair Mock
├── script/
│   ├── Deploy.s.sol              # 工厂部署脚本
│   └── MemeTest.s.sol            # 端到端演示脚本
├── out/                          # 编译产物
└── cache/                        # 编译缓存
```

---

## 三、合约依赖关系图

```
                    ┌─────────────────────────┐
                    │    Clones.sol            │  ← EIP-1167 最小代理库
                    │  (library, 纯工具)        │
                    └──────────┬──────────────┘
                               │ import
                    ┌──────────▼──────────────┐
                    │   MemeFactory.sol        │  ← 工厂合约（核心入口）
                    │  deployMeme()            │
                    │  mintMeme()    ← 5% LP   │
                    │  buyMeme()     ← NEW     │
                    │  setFeeCollector()       │
                    └──┬──────┬──────┬────────┘
          import      │      │      │  calls
    ┌─────────────────┘      │      └──────────────┐
    ▼                        ▼                      ▼
┌───────────────┐  ┌──────────────────┐  ┌──────────────────────┐
│   ERC20.sol   │  │  MemeToken.sol   │  │  Uniswap V2 Router   │
│  (abstract)   │◄─│  (is ERC20)      │  │  addLiquidityETH()   │
│  transfer     │  │  initialize()    │  │  swapExactETHFor...  │
│  approve      │  │  mint()          │  │  factory()           │
│  transferFrom │  │  mintForLiquidity│  │  WETH()              │
│  _mint        │  │  remaining()     │  └──────────────────────┘
└───────────────┘  └──────────────────┘
         │                  │
         │        ┌─────────▼──────────┐
         │        │   代理 #1 (DOGE)    │  ← EIP-1167 最小代理
         │        │   代理 #2 (SHIB)    │    (~55 字节)
         │        │   代理 #3 (RACC)    │    delegatecall → 逻辑
         │        │   ...              │    存储独立，代码共享
         │        └────────────────────┘
         │                  │
         │        ┌─────────▼──────────┐
         │        │  Uniswap V2 Pool   │  ← Token-ETH 流动性池
         │        │  (每次 mint 注入)    │    LP Token 永久锁定
         │        └────────────────────┘

    ERC20 标准接口（每个代理都是一枚独立的 ERC20 代币）
```

---

## 四、逐合约详解

### 4.1 `ERC20.sol` — ERC20 标准实现基类

| 属性 | 说明 |
|------|------|
| 文件路径 | `src/ERC20.sol` |
| 角色 | 抽象基类，被 MemeToken 继承 |
| 设计理念 | 极简实现，不依赖 OpenZeppelin，代码约 45 行 |

**状态变量：**

| 变量 | 类型 | 说明 |
|------|------|------|
| `name` | `string` | 代币名称（固定 "Meme"） |
| `symbol` | `string` | 代币代号（由发行者自定义） |
| `decimals` | `uint8` | 固定 18（硬编码常量） |
| `totalSupply` | `uint256` | 总发行量 |
| `balanceOf` | `mapping(address => uint256)` | 地址余额映射 |
| `allowance` | `mapping(address => mapping(address => uint256))` | 授权额度映射 |

**方法：**

| 方法 | 修饰符 | 功能 |
|------|--------|------|
| `transfer(to, amount)` | `public virtual` | 标准转账 |
| `approve(spender, amount)` | `public virtual` | 授权 spender 使用 amount |
| `transferFrom(from, to, amount)` | `public virtual` | 授权转账，支持 `type(uint256).max` 无限授权不扣减 |
| `_mint(to, amount)` | `internal` | 内部铸造（增发余额 + emit Transfer） |

---

### 4.2 `MemeToken.sol` — Meme 代币逻辑合约

| 属性 | 说明 |
|------|------|
| 文件路径 | `src/MemeToken.sol` |
| 角色 | 逻辑合约（Implementation），部署一次，之后通过 EIP-1167 最小代理克隆 |
| 继承 | `ERC20` |
| 关键机制 | 构造函数自锁 + `onlyFactory` 访问控制 |

**新增状态变量（存于代理存储中）：**

| 变量 | 类型 | 说明 |
|------|------|------|
| `factory` | `address` | 记录创建该代理的 MemeFactory 地址（访问控制锚点） |
| `deployer` | `address` | Meme 发行者地址（收取 95% mint 费用） |
| `perMint` | `uint256` | 每次铸造的代币数量 |
| `price` | `uint256` | 每次铸造需支付的 wei 金额 |
| `minted` | `uint256` | 已铸造总量（累加器，含用户 mint + LP mint） |
| `_initialized` | `bool` | 防重复初始化标志（私有） |

**方法：**

| 方法 | 修饰符 | 功能 |
|------|--------|------|
| `constructor()` | — | 立即设置 `_initialized = true`，**锁定逻辑合约本身** |
| `initialize(symbol_, totalSupply_, perMint_, price_, deployer_)` | — | 仅代理调用一次 |
| `mint(to)` | `onlyFactory` | 铸造 perMint 个代币给 `to`；若剩余量不足则只铸剩余量 |
| `mintForLiquidity(to, amount)` | `onlyFactory` | **NEW** 铸造指定数量代币用于流动性；若已耗尽则返回 0 不 revert |
| `remaining()` | `public view` | 返回 `totalSupply - minted` |

---

### 4.3 `Clones.sol` — EIP-1167 最小代理库

（无变化，与 v1.0 相同）

| 属性 | 说明 |
|------|------|
| 文件路径 | `src/Clones.sol` |
| 角色 | Library，提供 `clone()` 纯函数 |
| 原理 | 手写 EVM 汇编，部署一份 55 字节的 EIP-1167 最小代理合约 |

**方法：**

| 方法 | 返回 | 功能 |
|------|------|------|
| `clone(implementation)` | `address` | 部署一个指向 `implementation` 的最小代理并返回其地址 |

**55 字节代理合约结构：**

```
┌──────────────────────────────────────────────────────┐
│  创建时代码 (10 bytes)                               │
│  → 将运行时代码复制到内存，然后返回                    │
├──────────────────────────────────────────────────────┤
│  运行时代码 (45 bytes)                               │
│  1. PUSH20 <implementation_address>  (21 bytes)     │
│  2. DELEGATECALL 字节码             (其余 bytes)     │
│  3. RETURNDATASIZE / RETURNDATACOPY (转发返回值)     │
└──────────────────────────────────────────────────────┘
```

**Gas 对比：**

| 方式 | 部署成本 |
|------|---------|
| `new MemeToken()` (全量部署) | ~1M+ gas |
| `implementation.clone()` (EIP-1167) | ~200K gas |

> 💰 每个 Meme 发行者节省约 80% 的部署 Gas。

---

### 4.4 `MemeFactory.sol` — 工厂合约（核心入口，v2 重大更新）

| 属性 | 说明 |
|------|------|
| 文件路径 | `src/MemeFactory.sol` |
| 角色 | 核心业务合约，Meme 发射平台的全部用户操作入口 |
| 依赖 | `Clones.sol`、`MemeToken.sol`、`IUniswapV2Router`、`IUniswapV2Factory`、`IUniswapV2Pair` |

**常量：**

| 常量 | 值 | 说明 |
|------|-----|------|
| `PROJECT_FEE_BPS` | `500` | 平台费率 **5%**（v2 由 100 改为 500） |
| `BPS_DENOMINATOR` | `10_000` | 费率计算分母 |

**状态变量：**

| 变量 | 类型 | 说明 |
|------|------|------|
| `implementation` | `address`（immutable） | MemeToken 逻辑合约地址 |
| `feeCollector` | `address` | 平台费用接收地址（v2 mint 中不再使用，保留用于管理） |
| `uniswapRouter` | `IUniswapV2Router`（immutable） | Uniswap V2 Router 地址 |
| `uniswapFactory` | `IUniswapV2Factory`（immutable） | Uniswap V2 Factory（从 Router 派生） |
| `WETH` | `address`（immutable） | 包装原生代币地址（从 Router 派生） |

**事件：**

| 事件 | 参数 | 触发时机 |
|------|------|---------|
| `MemeDeployed` | `token, deployer, symbol, totalSupply, perMint, price` | 新 Meme 代理部署 |
| `Minted` | `token, buyer, amount, projectFee` | 每次 mint 完成 |
| `LiquidityAdded` | `token, pair, ethAmount, tokenAmount, liquidity` | **NEW** 每次添加 Uniswap V2 流动性 |
| `Bought` | `token, buyer, ethSpent, tokensReceived` | **NEW** 通过 buyMeme() 从 Uniswap 购买 |

---

#### 方法一：`deployMeme(symbol, totalSupply, perMint, price) → address token`

（与 v1.0 相同，无变化）

Meme 发行者调用，创建新的 ERC20 代币代理。

```
deployMeme("DOGE", 1_000_000e18, 100_000e18, 1 ether)
  │
  ├─ 1. 参数校验（symbol 非空、totalSupply > 0、perMint > 0）
  │
  ├─ 2. 克隆代理 → token = implementation.clone()
  │
  ├─ 3. 初始化代理存储 → MemeToken(token).initialize(...)
  │     ├─ name = "Meme"、symbol = 自定义
  │     ├─ deployer = msg.sender
  │     └─ factory = address(this)
  │
  └─ 4. emit MemeDeployed(...) → return token
```

---

#### 方法二：`mintMeme(tokenAddr) payable` — v2 重大更新

用户支付 ETH 铸造 Meme 代币。**v2 中费用结构从「1% 平台 + 99% 发行者」改为「5% Uniswap LP + 95% 发行者」。**

```
mintMeme(tokenAddr) { value: 1 ether }
  │
  ├─ 1. 校验支付金额 → require(msg.value == token.price())
  │
  ├─ 2. 铸造代币 → token.mint(msg.sender)
  │     └─ 铸 perMint 个给买方（或剩余量若不足）
  │
  ├─ 3. 费用分配
  │     ├─ liquidityFee   = msg.value × 500 / 10000 = 5% (0.05 ETH)
  │     └─ deployerShare  = msg.value - liquidityFee = 95% (0.95 ETH)
  │
  ├─ 4. 添加 Uniswap V2 流动性 ★ NEW
  │     └─ _addLiquidity(tokenAddr, liquidityFee)
  │          │
  │          ├─ 计算 Token 数量
  │          │   ├─ 第一次添加：tokenAmount = ethAmount × perMint / price
  │          │   │   （按 mint 价格作为初始流动性价格）
  │          │   └─ 后续添加：按 Uniswap Pool 当前比例
  │          │       tokenAmount = ethAmount × reserveToken / reserveWETH
  │          │
  │          ├─ 铸造流动性 Token → token.mintForLiquidity(factory, tokenAmount)
  │          │   └─ 若供应耗尽返回 0 → ETH 退回 deployer，跳过 LP
  │          │
  │          ├─ 授权 Router → token.approve(router, tokenAmount)
  │          │
  │          ├─ 调用 Router → router.addLiquidityETH{value: ethAmount}(...)
  │          │   └─ LP Token 发送至 address(0) → 永久锁定/销毁
  │          │
  │          └─ emit LiquidityAdded(...)
  │
  ├─ 5. 转账给发行者 → deployer.call{value: deployerShare}
  │
  └─ 6. emit Minted(...)
```

**费用流向示意：**

```
买方支付 price (例如 1 ETH)
         │
         ├── 5% (0.05 ETH) + 对应 Token → Uniswap V2 LP（永久锁定）
         │     └─ 第一次添加：按 mint 价格比例
         │     └─ 后续添加：按池子当前价格比例
         │
         └── 95% (0.95 ETH) → deployer（Meme 发行者）
```

---

#### 方法三：`buyMeme(tokenAddr, minAmountOut) payable` — ★ 全新功能

当 Uniswap V2 市场价格**优于**（低于）mint 价格时，用户可直接从池中购买 Meme Token。

```
buyMeme(tokenAddr, minAmountOut) { value: 0.5 ETH }
  │
  ├─ 1. 校验 → require(msg.value > 0)
  │
  ├─ 2. 获取 Pool 地址
  │     └─ pair = uniswapFactory.getPair(tokenAddr, WETH)
  │     └─ require(pair != address(0))  // 必须有流动性池
  │
  ├─ 3. 价格比较 ★ 核心逻辑
  │     ├─ startPrice = token.price() × 1e18 / token.perMint()
  │     │   （mint 价格：每个 Token 多少 wei）
  │     ├─ poolPrice  = _getUniswapPrice(tokenAddr, pair)
  │     │   （Uniswap 现货价格：从 reserves 计算）
  │     └─ require(poolPrice < startPrice)
  │         // 仅在池子价格更低时允许购买
  │
  ├─ 4. 滑点保护
  │     └─ 若 minAmountOut == 0 → 默认按 mint 价格计算最低可接受数量
  │         minOut = msg.value × perMint / price
  │
  ├─ 5. 通过 Uniswap 兑换
  │     └─ router.swapExactETHForTokens{value: msg.value}(
  │           minOut, [WETH, tokenAddr], msg.sender, deadline)
  │
  └─ 6. emit Bought(...)
```

**价格判断逻辑：**

```
mint 价格 (startPrice):  price / perMint  (ETH per Token)
Pool 价格 (poolPrice):   reserveWETH / reserveToken

若 poolPrice < startPrice → 池子更便宜 → buyMeme() 可通过
若 poolPrice ≥ startPrice → 池子不便宜 → buyMeme() 被拒绝
                                    → 用户应使用 mintMeme()
```

---

#### 方法四：`setFeeCollector(newCollector)`

（与 v1.0 相同，权限模型不变）

---

### 4.5 Uniswap V2 接口

| 文件 | 说明 |
|------|------|
| `src/interfaces/IUniswapV2Router.sol` | Router 接口：`addLiquidityETH()`、`swapExactETHForTokens()`、`factory()`、`WETH()` |
| `src/interfaces/IUniswapV2Factory.sol` | Factory 接口：`getPair()` |
| `src/interfaces/IUniswapV2Pair.sol` | Pair 接口：`getReserves()`、`token0()`、`token1()` |

---

## 五、核心机制详解

### 5.1 流动性添加机制

```
              ┌─────────────────────────────────────────────┐
              │          流动性添加决策树                      │
              └─────────────────────────────────────────────┘

                  用户调用 mintMeme() 支付 price ETH
                                │
                  提取 5% 作为 liquidityFee
                                │
                  查询 pair = factory.getPair(token, WETH)
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
              pair == address(0)        pair != address(0)
              （首次添加）               （非首次添加）
                    │                       │
                    ▼                       ▼
         tokenAmount =              读取 pair.getReserves()
         ethAmount × perMint        tokenAmount =
         / price                    ethAmount × reserveToken
         （按 mint 价格）            / reserveWETH
                                    （按池子当前比例）
                    │                       │
                    └───────────┬───────────┘
                                ▼
                    token.mintForLiquidity(factory, tokenAmount)
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
              minted > 0              minted == 0
              （正常流程）             （供应耗尽）
                    │                       │
                    ▼                       ▼
         token.approve(router)       ETH 退回 deployer
         router.addLiquidityETH()    （跳过 LP，发行者收到 100%）
         LP Token → address(0)
         （永久锁定）
```

### 5.2 价格比较机制

```
mintMeme() 价格：
  startPrice = price / perMint
  例：1 ETH / 100,000 Token = 0.00001 ETH/Token

Uniswap V2 现货价格：
  poolPrice = reserveWETH / reserveToken
  例：(1 ETH) / (200,000 Token) = 0.000005 ETH/Token

比较：
  poolPrice (0.000005) < startPrice (0.00001) → 池子更优惠
  → buyMeme() 允许执行，用户以市场价购入

  poolPrice (0.00002) ≥ startPrice (0.00001) → 池子更贵
  → buyMeme() 拒绝，用户应使用 mintMeme()
```

### 5.3 供应耗尽处理

当 Token 供应接近耗尽，`mintForLiquidity()` 返回 0（不 revert），此时：
- 用户的 perMint 铸造照常进行（被 capped 到剩余量）
- 流动性添加被跳过
- 原本用于 LP 的 ETH 退还给 deployer
- 发行者在该笔交易中实际收到 100% 的支付

---

## 六、测试覆盖

文件路径：`test/MemeFactory.t.sol`

**33 个测试用例，10 大类别：**

| 分类 | 测试数 | 覆盖内容 |
|------|--------|---------|
| **deployMeme** | 5 | 正常部署、事件发出、空 symbol 回退、totalSupply=0 回退、perMint=0 回退 |
| **mintMeme** | 8 | 成功铸造+5% LP 费用分配、LP Token 铸造验证、多次铸造累计、最后一笔部分铸造（含 LP 耗尽场景）、金额错误回退、全部铸完回退、零地址回退 |
| **实现锁定** | 1 | 逻辑合约无法被 initialize |
| **访问控制** | 2 | 普通用户/发行者直接 mint 被拒 |
| **ERC20 标准** | 3 | transfer、approve + transferFrom、无限授权不扣减 |
| **buyMeme** ★ | 5 | 池子价格更低时成功购买、指定 minAmountOut、池子价格不更优时回退、无池子时回退、零 ETH 回退 |
| **流动性添加** ★ | 3 | 事件发出、首次添加按 mint 价格、后续添加按池子比例 |
| **Uniswap 常量** ★ | 1 | PROJECT_FEE_BPS=500、Router/Factory/WETH 地址正确 |
| **Admin** | 3 | 正常更新 feeCollector、非授权方回退、零地址回退 |
| **多代币独立性** | 1 | 两个 Meme 代理参数完全独立 |
| **构造函数校验** ★ | 2 | feeCollector 零地址回退、router 零地址回退 |

---

## 七、设计模式与安全总结

```
┌────────────────────────────────────────────────────────────┐
│                      设计模式                               │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  EIP-1167 最小代理 (Minimal Proxy / Clone Pattern)         │
│  ├─ MemeToken = 逻辑合约（1 份，永不初始化）                 │
│  ├─ 每个 Meme = 55 字节代理（~200K gas vs ~1M+）           │
│  └─ delegatecall 转发调用，存储完全隔离                     │
│                                                            │
│  工厂模式 (Factory Pattern)                                 │
│  ├─ MemeFactory = 唯一对外入口                              │
│  └─ 统一管理：创建 + 铸造 + 流动性 + 费用分配                │
│                                                            │
│  构造函数自锁 (Constructor Lock)                            │
│  └─ 逻辑合约 constructor 设 _initialized=true               │
│                                                            │
│  onlyFactory 访问控制                                       │
│  └─ mint / mintForLiquidity 只能经工厂合约调用               │
│                                                            │
│  公平发射 (Fair Launch)                                     │
│  └─ perMint 分批铸造 + 自动流动性引导                       │
│                                                            │
│  自动流动性 (Auto Liquidity) ★ NEW                          │
│  ├─ 每次 mint 提取 5% 注入 Uniswap V2                      │
│  ├─ 首次按 mint 价格定价                                    │
│  ├─ 后续按市场价避免套利                                    │
│  └─ LP Token 永久锁定（发送至 address(0)）                  │
│                                                            │
│  市场套利保护 ★ NEW                                         │
│  └─ buyMeme() 仅在池子价格更优时开放                         │
│     避免用户以高于 mint 价格从池子购买                        │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

**安全措施清单：**

| 措施 | 说明 |
|------|------|
| ✅ 防重复初始化 | `_initialized` 标志 + constructor 锁定 |
| ✅ 访问控制 | `onlyFactory` 确保 mint 必经工厂 |
| ✅ 精确支付 | `require(msg.value == price)` |
| ✅ 充分铸造检查 | `remaining() == 0` 时 revert（mint 用户部分） |
| ✅ 流动性供应耗尽处理 | `mintForLiquidity()` 返回 0 不 revert，ETH 退回 |
| ✅ 零地址检查 | deployer、feeCollector、router 不允许零地址 |
| ✅ 溢出保护 | Solidity 0.8.x 内置 |
| ✅ ETH 转账安全 | 使用 `.call{value:}("")` 而非 `.transfer()` |
| ✅ ERC20 返回值检查 | transfer/transferFrom 均检查返回值 |
| ✅ 空参检查 | symbol、totalSupply、perMint 均有校验 |
| ✅ 滑点保护 | buyMeme() 支持 minAmountOut 参数 |
| ✅ 期限保护 | Uniswap 调用使用 `block.timestamp + 15 minutes` |
| ✅ LP 永久锁定 | LP Token 发送至 address(0)，无法撤回 |
| ✅ 价格比较 | buyMeme() 强制 poolPrice < startPrice |

---

## 八、部署与测试命令

### 8.1 编译

```bash
cd /Users/jim123/Desktop/hello_foundry/meme
forge build
```

### 8.2 运行测试

```bash
# 简要输出
forge test

# 详细输出
forge test -vvv
```

### 8.3 生产部署

```bash
# 设置环境变量
export FEE_COLLECTOR=0x_YOUR_FEE_COLLECTOR_ADDRESS
export UNISWAP_ROUTER=0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D  # 主网默认

# 使用 keystore（推荐）
forge script script/Deploy.s.sol --keystores default --rpc-url <RPC_URL> --broadcast

# 或使用私钥
forge script script/Deploy.s.sol --private-key 0x... --rpc-url <RPC_URL> --broadcast
```

### 8.4 Uniswap V2 Router 地址参考

| 链 | Router 地址 |
|------|------|
| Ethereum Mainnet | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| Sepolia Testnet | `0x425141165d3DE9FEC831896C016617a52363b687` |
| Goerli Testnet (deprecated) | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |

---

## 九、v1.0 → v2.0 变更摘要

| 项目 | v1.0 | v2.0 |
|------|------|------|
| 平台费率 | 1% (100 BPS) | 5% (500 BPS) |
| 费用用途 | 1% → feeCollector（平台） | 5% → Uniswap V2 LP（永久锁定） |
| 发行者收入 | 99% | 95% |
| Uniswap 集成 | 无 | Router / Factory / Pair 完整集成 |
| 流动性添加 | 无 | 每次 mint 自动添加 |
| 首次 LP 定价 | 无 | 按 mint 价格 |
| buyMeme() | 无 | 池子价格更优时可购买 |
| 测试数量 | 21 个 | 33 个 |
| Mock 合约 | 无 | WETH / Router / Factory / Pair 完整 Mock |
| 接口文件 | 无 | 3 个 Uniswap V2 接口文件 |
