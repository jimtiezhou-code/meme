# Meme 发射平台 — 项目架构分析文档

## 一、项目概述

这是一个基于 EVM 链的 Meme 发射平台，采用 **EIP-1167 最小代理（Minimal Proxy）** 模式，大幅降低 Meme 发行者的部署 Gas 成本。每个 Meme 都是一枚符合 ERC20 标准的代币，通过分批铸造（Fair Launch）方式实现公平发射。

| 属性 | 说明 |
|------|------|
| 框架 | Foundry (Forge + Cast + Anvil) |
| Solidity 版本 | ^0.8.20 |
| 核心模式 | EIP-1167 Minimal Proxy / 工厂模式 |
| 外部依赖 | 仅 `forge-std`（测试），无 OpenZeppelin |

---

## 二、目录结构

```
meme/
├── foundry.toml              # Foundry 构建配置
├── README.md                 # 项目说明（模板）
├── lib/
│   └── forge-std/            # Foundry 标准库（测试依赖）
├── src/                      # ★ 合约源码
│   ├── ERC20.sol             #    抽象基类：ERC20 标准实现
│   ├── MemeToken.sol         #    Meme 代币实现（逻辑合约，被克隆）
│   ├── Clones.sol            #    EIP-1167 最小代理库
│   └── MemeFactory.sol       #    工厂合约（用户入口）
├── test/
│   └── MemeFactory.t.sol     # 单元测试（21 个测试用例）
├── script/
│   ├── Deploy.s.sol          # 工厂部署脚本
│   └── MemeTest.s.sol        # 端到端演示脚本
├── out/                      # 编译产物
└── cache/                    # 编译缓存
```

---

## 三、合约依赖关系图

```
                    ┌─────────────────────┐
                    │    Clones.sol        │  ← EIP-1167 最小代理库
                    │  (library, 纯工具)    │
                    └──────────┬──────────┘
                               │ import
                    ┌──────────▼──────────┐
                    │   MemeFactory.sol    │  ← 工厂合约（用户入口）
                    │  deployMeme()        │
                    │  mintMeme()          │
                    │  setFeeCollector()   │
                    └──────┬──────┬────────┘
               import       │      │ clone() + 调用 initialize/mint
        ┌──────────────────┘      │
        ▼                         │
┌───────────────┐          ┌──────▼──────────┐
│   ERC20.sol   │          │  MemeToken.sol   │  ← 代币逻辑合约
│  (abstract)   │◄────────│  (is ERC20)      │    (1 份实现 → N 个代理)
│  transfer     │ inherit │  initialize()     │
│  approve      │         │  mint()           │
│  transferFrom │         │  remaining()      │
│  _mint        │         │  onlyFactory      │
└───────────────┘         └──────────────────┘
         │                        │
         │              ┌─────────▼──────────┐
         │              │   代理 #1 (DOGE)    │  ← EIP-1167 最小代理
         │              │   代理 #2 (SHIB)    │    (~55 字节)
         │              │   代理 #3 (RACC)    │    delegatecall → 逻辑
         │              │   ...              │    存储独立，代码共享
         │              └────────────────────┘
         │
         └──── ERC20 标准接口（每个代理都是一枚独立的 ERC20 代币）
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
| `transfer(to, amount)` | `public virtual` | 标准转账，扣减 `msg.sender` 余额 |
| `approve(spender, amount)` | `public virtual` | 授权 `spender` 使用 `amount` |
| `transferFrom(from, to, amount)` | `public virtual` | 授权转账，支持 `type(uint256).max` 无限授权不扣减 |
| `_mint(to, amount)` | `internal` | 内部铸造（增发余额 + emit Transfer） |

> ⚠️ 未显式检查 `balanceOf[from] >= amount`，依赖 Solidity 0.8.x 内置溢出保护。

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
| `factory` | `address` | 🔒 记录创建该代理的 MemeFactory 地址（访问控制锚点） |
| `deployer` | `address` | Meme 发行者地址（收取 99% mint 费用） |
| `perMint` | `uint256` | 每次铸造的代币数量 |
| `price` | `uint256` | 每次铸造需支付的 wei 金额 |
| `minted` | `uint256` | 已铸造总量（累加器） |
| `_initialized` | `bool` | 防重复初始化标志（私有） |

**自定义错误：**

| 错误 | 触发条件 |
|------|---------|
| `AlreadyInitialized()` | 对已初始化合约再次调用 `initialize` |
| `ZeroAddress()` | `initialize` 时 `deployer_` 为零地址 |

**修饰符：**

| 修饰符 | 逻辑 |
|--------|------|
| `onlyFactory()` | `require(msg.sender == factory, "MemeToken: not factory")` |

**方法：**

| 方法 | 修饰符 | 功能 |
|------|--------|------|
| `constructor()` | — | 立即设置 `_initialized = true`，**锁定逻辑合约本身**，任何人无法初始化 |
| `initialize(symbol_, totalSupply_, perMint_, price_, deployer_)` | — | 仅代理调用一次：设置 name="Meme"、symbol、totalSupply、perMint、price、deployer、factory |
| `mint(to)` | `onlyFactory` 🔒 | 铸造 perMint 个代币给 `to`；若剩余量 < perMint，只铸造剩余量 |
| `remaining()` | `public view` | 返回 `totalSupply - minted`（剩余可铸造量） |

**安全设计原理：**

```
逻辑合约 MemeToken (implementation)
    ├─ constructor 执行 → _initialized = true → 永久锁定
    └─ 任何人调用 initialize → revert AlreadyInitialized

代理 Proxy #1 (DOGE)
    ├─ delegatecall → MemeToken.initialize(...) → 存储写入代理自身
    └─ delegatecall → MemeToken.mint(...) ←─ 只有 factory 能调用 (onlyFactory)
```

---

### 4.3 `Clones.sol` — EIP-1167 最小代理库

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

每次调用代理的任何函数时，代理通过 `DELEGATECALL` 将调用转发给逻辑合约。逻辑合约的代码在代理的存储上下文中执行，因此每个代理的状态完全独立。

**Gas 对比：**

| 方式 | 部署成本 |
|------|---------|
| `new MemeToken()` (全量部署完整合约) | ~1M+ gas |
| `implementation.clone()` (EIP-1167 代理) | ~200K gas |

> 💰 每个 Meme 发行者节省约 80% 的部署 Gas。

---

### 4.4 `MemeFactory.sol` — 工厂合约（核心入口）

| 属性 | 说明 |
|------|------|
| 文件路径 | `src/MemeFactory.sol` |
| 角色 | 核心业务合约，Meme 发射平台的全部用户操作入口 |
| 依赖 | `Clones.sol`（library）、`MemeToken.sol`（逻辑合约） |

**常量：**

| 常量 | 值 | 说明 |
|------|-----|------|
| `PROJECT_FEE_BPS` | `100` | 项目方费率 = 1%（basis points） |
| `BPS_DENOMINATOR` | `10_000` | 费率计算分母 |

**状态变量：**

| 变量 | 类型 | 说明 |
|------|------|------|
| `implementation` | `address`（immutable） | MemeToken 逻辑合约地址，constructor 中创建后永久锁定 |
| `feeCollector` | `address` | 收取 1% 平台费用的地址 |

**事件：**

| 事件 | 参数 | 触发时机 |
|------|------|---------|
| `MemeDeployed` | `token, deployer, symbol, totalSupply, perMint, price` | 新 Meme 代理部署成功 |
| `Minted` | `token, buyer, amount, projectFee` | 每次 mint 完成 |

---

#### 方法一：`deployMeme(symbol, totalSupply, perMint, price) → address token`

Meme 发行者调用，创建新的 ERC20 代币代理。

**执行流程：**

```
deployMeme("DOGE", 1_000_000e18, 100_000e18, 1 ether)
  │
  ├─ 1. 参数校验
  │    ├─ require(bytes(symbol).length > 0)    ← symbol 不能为空
  │    ├─ require(totalSupply > 0)              ← 总供应量 > 0
  │    └─ require(perMint > 0)                  ← 每次铸造量 > 0
  │
  ├─ 2. 克隆代理
  │    └─ token = implementation.clone()        ← EIP-1167, ~200K gas
  │
  ├─ 3. 初始化代理存储
  │    └─ MemeToken(token).initialize(           ← delegatecall 写入代理
  │         symbol, totalSupply, perMint, price, msg.sender)
  │         ├─ name = "Meme"                     ← 固定名称
  │         ├─ deployer = msg.sender              ← 发行者（mint 收 99%）
  │         └─ factory = address(this)            ← 当前工厂地址（访问控制）
  │
  └─ 4. emit MemeDeployed(token, msg.sender, symbol, ...)
       return token
```

**参数说明：**

| 参数 | 类型 | 说明 |
|------|------|------|
| `symbol` | `string` | 代币代号（如 "DOGE"，ERC20 名称固定为 "Meme"） |
| `totalSupply` | `uint256` | 总发行量（1,000,000 × 10¹⁸ 表示 100 万枚） |
| `perMint` | `uint256` | 每次铸造数量（实现公平分批发射） |
| `price` | `uint256` | 每次铸造费用（wei 计价） |
| 返回值 | `address` | 新创建的 Meme 代币代理地址 |

---

#### 方法二：`mintMeme(tokenAddr) payable`

用户支付 ETH 铸造 Meme 代币，费用自动分配。

**执行流程：**

```
mintMeme(tokenAddr) { value: 1 ether }
  │
  ├─ 1. 校验支付金额
  │    └─ require(msg.value == token.price())    ← 必须精确匹配
  │
  ├─ 2. 铸造代币
  │    └─ token.mint(msg.sender)                  ← onlyFactory 校验通过
  │         ├─ 若 remaining ≥ perMint → 铸 perMint 个
  │         └─ 若 remaining < perMint → 只铸 remaining 个（最后一笔）
  │
  ├─ 3. 费用分配
  │    ├─ projectFee = msg.value * 100 / 10000   = 1%
  │    ├─ deployerShare = msg.value - projectFee = 99%
  │    │
  │    ├─ payable(feeCollector).call{value: projectFee}      ← 1% → 项目方
  │    └─ payable(token.deployer()).call{value: deployerShare} ← 99% → 发行者
  │
  └─ 4. emit Minted(tokenAddr, msg.sender, mintedAmt, projectFee)
```

**费用流向示意：**

```
买方支付 price (例如 1 ETH)
         │
         ├── 1% (0.01 ETH) → feeCollector（项目方/平台）
         │
         └── 99% (0.99 ETH) → deployer（Meme 发行者）
```

---

#### 方法三：`setFeeCollector(newCollector)`

| 调用权限 | `msg.sender == feeCollector` |
|---------|----------------------------|
| 约束 | `newCollector != address(0)` |
| 功能 | 更新平台费用接收地址 |

> 权限模型为"feeCollector 自治"——当前收款人自行转移控制权，无额外的 owner/admin 角色。

---

## 五、测试覆盖

文件路径：`test/MemeFactory.t.sol`

**21 个测试用例，6 大类别，全部通过：**

| 分类 | 测试数 | 覆盖内容 |
|------|--------|---------|
| **deployMeme** | 5 | 正常部署验证所有字段、事件发出、空 symbol 回退、totalSupply=0 回退、perMint=0 回退 |
| **mintMeme** | 6 | 成功铸造+费用分配、多次铸造累计、最后一笔部分铸造、金额错误回退、全部铸完回退、零地址回退 |
| **实现锁定** | 1 | 逻辑合约无法被 initialize |
| **访问控制** 🔒 | 2 | 普通用户直接 mint 被拒、发行者直接 mint 也被拒 |
| **ERC20 标准** | 3 | transfer、approve + transferFrom、无限授权不扣减 |
| **Admin** | 3 | 正常更新 feeCollector、非授权方回退、零地址回退 |
| **多代币独立性** | 1 | 两个 Meme 代理参数完全独立 |

---

## 六、设计模式与安全总结

```
┌────────────────────────────────────────────────────────────┐
│                      设计模式                              │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  EIP-1167 最小代理 (Minimal Proxy / Clone Pattern)         │
│  ├─ MemeToken = 逻辑合约（1 份，永不初始化）                 │
│  ├─ 每个 Meme = 55 字节代理（~200K gas vs ~1M+）           │
│  └─ delegatecall 转发调用，存储完全隔离                     │
│                                                            │
│  工厂模式 (Factory Pattern)                                 │
│  ├─ MemeFactory = 唯一对外入口                              │
│  └─ 统一管理：创建代币 + 铸造代币 + 费用分配                │
│                                                            │
│  构造函数自锁 (Constructor Lock)                            │
│  └─ 逻辑合约 constructor 设 _initialized=true               │
│     防止任何人直接初始化逻辑合约                             │
│                                                            │
│  onlyFactory 访问控制                                       │
│  └─ mint 只能经工厂合约调用                                  │
│     任何直接调用 MemeToken.mint() 均被拒绝                   │
│                                                            │
│  公平发射 (Fair Launch)                                     │
│  └─ perMint 分批铸造，非一次性全部 mint                     │
│     最后一笔自动只铸造剩余量                                 │
│                                                            │
│  费用分层                                                    │
│  └─ BPS 精确计算 (100 / 10000 = 1%)                         │
│     1% 平台 / 99% 发行者                                    │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

**安全措施清单：**

| 措施 | 说明 |
|------|------|
| ✅ 防重复初始化 | `_initialized` 标志 + constructor 锁定 |
| ✅ 访问控制 | `onlyFactory` 确保 mint 必经工厂 |
| ✅ 精确支付 | `require(msg.value == price)` |
| ✅ 充分铸造检查 | `remaining() == 0` 时 revert |
| ✅ 零地址检查 | deployer、feeCollector 不允许零地址 |
| ✅ 溢出保护 | Solidity 0.8.x 内置 |
| ✅ ETH 转账安全 | 使用 `.call{value:}("")` 而非 `.transfer()` |
| ✅ 空参检查 | symbol、totalSupply、perMint 均有校验 |

**已知局限 / 改进方向：**

| 局限 | 说明 |
|------|------|
| 最后一笔仍按全价 | 即使只铸造了少量 token，费用不变（设计上的取舍，发行者可自行设定 perMint 来缓解） |
| ERC20 approve 竞态 | 无 `increaseAllowance`/`decreaseAllowance`（标准限制） |
| 无暂停机制 | 没有紧急暂停 mint 的功能（非必须） |
| feeCollector 权限 | 当前仅 feeCollector 自身可转移权限，若私钥丢失则无法恢复 |

---

## 七、部署与测试命令

### 7.1 编译

```bash
cd /Users/jim123/Desktop/hello_foundry/meme
forge build
```

### 7.2 运行测试

```bash
# 简要输出
forge test

# 详细输出
forge test -vvv
```

### 7.3 本地链端到端测试

```bash
# 终端 1：启动本地节点
anvil

# 终端 2：设置测试私钥（anvil 默认第一个账户）
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 试运行（不广播交易）
forge script script/MemeTest.s.sol --rpc-url http://localhost:8545 -vvv

# 正式上链
forge script script/MemeTest.s.sol --rpc-url http://localhost:8545 --broadcast -vvv
```

### 7.4 生产部署

```bash
# 设置费用接收地址
export FEE_COLLECTOR=0x_YOUR_FEE_COLLECTOR_ADDRESS

# 使用 keystore（推荐）
forge script script/Deploy.s.sol --keystores default --rpc-url <RPC_URL> --broadcast

# 或使用私钥（开发测试）
forge script script/Deploy.s.sol --private-key 0x... --rpc-url <RPC_URL> --broadcast
```
