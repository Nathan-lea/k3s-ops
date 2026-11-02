# 课程项目模板设计

> 目标产物：一个**独立 git 仓库** `course-template`，供克隆后生成新的独立课程项目。
>
> 本文是设计文档，不是操作手册。实施计划另出。

| 项 | 值 |
|---|---|
| 状态 | 待评审 |
| 日期 | 2026-11-02 |
| 母项目 | `k3s-ops`（第一课，已完成，**不回填**） |
| 产物仓库 | `course-template`（新建，独立） |
| 目标用户 | 作者本人（后续课程）+ 克隆者 |

---

## 1. 背景与意图

`k3s-ops` 是「DevOps 自学系列」的第一课，做完了 45 章教程、101 个提交、一套生产化方案，
并且在事故恢复后写了一份 1,250 行的复盘。复盘里最有价值的两样东西是：

1. **真正起作用的做法**（流程分级、约束编号、门禁、证据落盘、诚实边界）；
2. **明确列出的短板**（§12.3 四条，§12.4 七条改进）。

第二课起如果每次从零搭，这些做法会逐个丢失——不是因为不认同，而是因为**没人强制**。
所以需要一个模板，把"做法"变成"骨架"，把"规范"变成"脚本"，把"红线"变成"机制"。

### 1.1 一句话定位

> 把第一课里那些**靠自觉才成立**的东西，变成**不照做就报错**的东西。

### 1.2 为什么是新仓库而不是子目录

`k3s-ops` 里 `production/` 已经演过一次「复用 → 参数化 → 物理剥离」，结论是
**剥离比参数化便宜**（复盘 §4.7）。模板与课程是同样的关系：模板要服务 k8s 课、
Docker 课、CI/CD 课、Terraform 课，它们的默认值必然分叉。放进 `k3s-ops` 子目录
就会重演 `if profile == k8s` 的老路。

---

## 2. 目标 / 非目标 / 反目标

### 2.1 目标

| # | 目标 | 可验证判据 |
|---|---|---|
| G1 | 一条命令生成新课程仓库，含完整骨架 | `new-course.sh ../demo --profile generic` 成功，且生成物门禁全绿 |
| G2 | 生成即自带门禁（隐私 / 文档 / 前置条件） | 生成结束时三道检查都跑过且退出码 0 |
| G3 | 规范只写一份，所有课程强制一致 | 规范文件全部在 `core/`，`profiles/` **不含**任何规范 |
| G4 | 模板可演进，老课程能同步 `core/` 更新 | `sync-template.sh` 能把 core 更新合入，且不碰课程内容 |
| G5 | 复盘 §12.4 的七条改进全部落成机制 | §8 的对照表逐条有落点文件 |
| G6 | k8s 与非 k8s 课程同一套模板 | 两个 profile 生成出的门禁行为完全一致 |

### 2.2 非目标

- **不预置任何课程内容**。不把 k3s、Docker、Terraform 的任何一章塞进模板。
- **不回填第一课**。`k3s-ops` 保持现状，作为参考样本而非基线。
- **不做服务端 / Web UI / 包管理器**。模板是一个仓库 + 几个脚本。
- **不追求跨语言**。脚本用 bash + Python 3；配置解析用 **PyYAML**（与第一课一致，
  作为显式前置声明，见 §4.4，不做自制 YAML 解析器）。
- **不做插件市场**。profile 就是目录，没有注册中心。

### 2.3 反目标（技术上跑通也算失败）

| # | 反目标 | 为什么是失败 |
|---|---|---|
| A1 | `core/` 里出现 `if profile == k8s` 这类分支 | 一旦开始分叉，第二个 profile 就会把内核拖成补丁堆 |
| A2 | 生成出来的项目第一次跑门禁就要手工修 | 模板把成本转嫁给了用户，等于没解决问题 |
| A3 | 模板自己没有被测试覆盖 | 模板腐化时无人发现，错误会复制到每一门课 |
| A4 | 用户克隆后必须读三篇文档才能开始 | 上手成本高于收益，用户会绕过模板直接抄第一课 |
| A5 | 规范以"建议"形式存在（README 里写"请务必…"） | 靠自觉的规范等于没有规范——这正是第一课的教训 |

---

## 3. 约束（用户明确的）

| # | 约束 | 原文要点 |
|---|---|---|
| C1 | 独立 git 仓库，供克隆 | "作为一个独立的项目提交到 git 库" |
| C2 | 克隆后生成新的独立项目 | "供用户克隆下来后生成新的独立的项目" |
| C3 | 清晰的目录结构 | "有清晰基本的目录结构" |
| C4 | 预置隐私检查 | "有准备好的隐私检查" |
| C5 | 预置约束清单 | "有相关的约束" |
| C6 | 前置条件检查 + 缺失引导安装 | "要安装什么工具、技能，自动检查缺失提醒并引导安装" |
| C7 | 文档规范与格式要求 | "有明确的文档规范和格式要求" |
| C8 | 四条行为红线 | 不确认不删文件 / 不确认不写内容 / 隐私检查必须执行 / 必须按流程执行 |
| C9 | 通用，k8s 与非 k8s 都能用 | "两种都有可能，能不能做成通用的" |
| C10 | 保留模板来源，支持同步 | "留一条线" |
| C11 | 不回填第一课 | "不回填应该是最好的吧" |

C8 的四条红线是本模板的**存在理由**，§6 专门展开。

---

## 4. 架构：内核 + 剖面

### 4.1 分工

| | 装什么 | 变化频率 | 谁改 |
|---|---|---|---|
| **内核 `core/`** | 契约、门禁、规范、门禁自测、CI | 低（跨课程稳定） | 模板维护者 |
| **剖面 `profiles/`** | 目录骨架、工具清单、验证命令、stub、章节大纲 | 高（一门课一份） | 课程作者 |

**硬规则**：`profiles/` 只提供**数据**（YAML + 目录 + 文件），不提供**逻辑**（脚本）。
剖面里出现 `*.sh` 就是设计违规，模板自测会断言这一点。

### 4.2 模板仓库结构

```
course-template/
├── README.md                      # 三条命令上手
├── LICENSE                        # MIT
├── VERSION                        # 语义化版本
├── CHANGELOG.md
├── new-course.sh                  # 生成器
│
├── core/                          # 逐字拷贝进生成物
│   ├── AGENTS.md.tmpl             # 契约（流程分级 + 四条红线 + 单一事实源）
│   ├── .gitignore
│   ├── .githooks/pre-push         # → scripts/gate.sh --privacy
│   ├── .github/workflows/gate.yml
│   ├── .gitea/workflows/gate.yml
│   ├── scripts/
│   │   ├── gate.sh                # 统一门禁入口（privacy|docs|prereqs|all）
│   │   ├── privacy-check.sh       # 8 条规则
│   │   ├── check-docs.py          # 围栏/表格/锚点/跳级/编码/行尾
│   │   ├── check-prereqs.sh       # 读 course.yml，缺工具给安装命令
│   │   ├── gen-stats.py           # 规模数字自动化
│   │   └── sync-template.sh       # 同步 core 更新（G4）
│   ├── docs/
│   │   ├── conventions.md         # 章节八段式、术语表、提交规范、数字规则
│   │   ├── decisions.md           # 决策日志（决定/理由/猜错的代价）
│   │   ├── definition-of-done.md  # 完成定义
│   │   ├── architecture.md.tmpl   # 架构文档骨架
│   │   └── retrospective.md.tmpl  # 复盘骨架（14 章框架）
│   └── tests/
│       ├── run-all.sh
│       ├── lib/harness.sh         # stub 隔离 + 断言
│       ├── test-privacy-gate.sh   # 门禁正反例
│       └── test-docs-gate.sh      # 文档校验正反例
│
├── profiles/
│   ├── generic/                   # 最小剖面：git + python3
│   │   ├── course.yml
│   │   ├── chapters/              # 章节大纲（只有标题，无正文）
│   │   └── files/                 # 额外目录骨架
│   └── k8s-vagrant/               # 从第一课**抽结构**，不含教程正文
│       ├── course.yml
│       ├── stubs/{vagrant,ansible-playbook,kubectl}
│       ├── chapters/
│       └── files/{vagrant/,ansible/}
│
└── tests/
    ├── test-generate.sh           # 每个 profile 生成 → 门禁全绿 → 结构断言
    ├── test-idempotent.sh         # 不覆盖非空目录
    └── test-sync.sh               # 老版本 → 升级 → sync → 只动 core
```

### 4.3 生成物结构

```
<course-name>/
├── AGENTS.md                      # 由 core/AGENTS.md.tmpl 渲染
├── README.md
├── course.yml                     # 剖面 + 课程元数据合并结果（唯一配置源）
├── .course/
│   ├── template-version           # 来源与版本（C10）
│   └── core-manifest.txt          # core 文件哈希，供 sync 判断本地改动
├── .githooks/pre-push
├── .github/workflows/gate.yml
├── .gitea/workflows/gate.yml
├── scripts/                       # 与 core 一致
├── docs/
│   ├── conventions.md
│   ├── decisions.md
│   ├── definition-of-done.md
│   ├── architecture.md
│   └── <chapters-dir>/            # 剖面决定，如 docs/chapters/ 或 docs/k8s-tutorial/
├── tests/
├── <profile 提供的额外目录>        # 如 vagrant/ ansible/
└── logs/                          # gitignore
```

### 4.4 `course.yml` 契约

单一配置源（C3/C5/C6）。生成后仍然有效——它是**活配置**，不是一次性输入。

```yaml
course:
  name: ""                 # 生成时注入（kebab-case）
  title: ""                # 生成时注入
  series: "devops-self-study"
  language: "zh"
  audience: ""             # 写给谁看（影响措辞与深度）

profile: generic

# --- C6 前置条件 -------------------------------------------------
tools:
  - name: git
    min_version: "2.30"
    check: "git --version"
    install: "apt-get install -y git"
    required: true
  - name: python3
    min_version: "3.8"
    check: "python3 --version"
    install: "apt-get install -y python3"
    required: true
  - name: pyyaml           # 配置解析器：必须显式声明，不能假设系统已有
    min_version: "5.4"
    check: "python3 -c 'import yaml; print(yaml.__version__)'"
    install: "python3 -m pip install pyyaml"
    required: true

skills:                    # agent 技能：仅提示，永不改变退出码
  required: [brainstorming, writing-plans]
  optional: [systematic-debugging]

# --- 单一事实源 ---------------------------------------------------
facts:
  source: "vagrant/nodes.yml"      # 拓扑/配置的唯一权威文件
  note: "改拓扑只改这个文件；其他位置出现副本即为缺陷"
  validate: ""                     # 可选：校验命令

# --- 怎么算"跑通" -------------------------------------------------
verify:
  self: "./scripts/gate.sh all"    # 生成物自带，开箱可跑（模板保证）
  infra: ""                        # 需真实环境，作者填；为空则 DoD 不允许勾"已验证"
  expect_exit: 0
  evidence: "logs/verify.log"      # 证据落盘到仓库内，不用临时目录

# --- 测试用 stub ---------------------------------------------------
stubs: [vagrant, ansible-playbook, kubectl]

# --- 隐私白名单：派生 + 显式，每条都带理由 -------------------------
privacy:
  derive:                          # 从事实源提取，避免两处维护
    - from: "vagrant/nodes.yml"
      rule: "ip-like-scalars"      # core 内固定提取器（遍历 YAML 取 IP 形态标量）
      reason: "拓扑事实源，属于项目设计"
  allow:                           # 无法派生的，逐值列 + 写理由
    - literal: "192.0.2.10"
      reason: "文档示例使用 TEST-NET 网段，非真实地址"

# --- 章节 ----------------------------------------------------------
chapters:
  dir: "docs/k8s-tutorial"
  pattern: "{nn}-{title}.md"
  strict_sections: false           # 开始写正文后改 true，CI 才会校验小节非空
  groups:                          # 章节大纲：只有标题，无正文
    - 基础概念
    - 架构全景
    - 工作负载
```

**三条设计要点**：

1. **`verify` 拆成 `self` 与 `infra`**。`self` 是生成物自带、不依赖真实环境的自检
   （`gate.sh all`），保证"开箱即绿"（A2）；`infra` 是需要真实机器的那条，
   作者填，为空时 `gate.sh` 只警告不失败，但 DoD 不允许勾"已验证"。
   ——这就是复盘里"诚实边界"的机制化：**未验证就是未验证，不是失败，但也不能算完成**。
2. **`privacy` 白名单从事实源派生**。`derive` 只声明"从哪个文件、用哪个提取器"，
   提取器本身在 `core/` 里固定（`ip-like-scalars` 之类），所以
   **剖面仍然只有数据、没有逻辑**（§4.1 硬规则）。
3. **`reason` 是结构化字段，不是 YAML 注释**。注释会被 `yaml.safe_load` 丢弃，
   也会被复制粘贴丢失；只有字段能进检查和报表。

---

## 5. 门禁设计

### 5.1 四道门禁

| 门禁 | 脚本 | 触发时机 | 失败后果 |
|---|---|---|---|
| 隐私 | `privacy-check.sh` | pre-push（强制）+ CI | 阻断推送 |
| 文档 | `check-docs.py` | `gate.sh` + CI | 阻断 |
| 前置条件 | `check-prereqs.sh` | 生成时 + 每次 `gate.sh all` | 缺必装项则阻断 |
| 红线自检 | `gate.sh redlines` | 开工前手工跑 | 提示（见 §6） |

统一入口 `scripts/gate.sh`：

```
gate.sh privacy    # 只跑隐私（pre-push 用，约 2 秒）
gate.sh docs       # 只跑文档
gate.sh prereqs    # 只跑前置条件
gate.sh all        # 全跑（CI 用）
```

**为什么隐私单独一个入口**：pre-push 要快。门禁的位置应匹配"错误的代价"——
隐私一旦推送就来不及，所以卡在 push；语法错误本地就能改，不必卡。

### 5.2 隐私检查

沿用第一课已验证的 8 条规则（绝对路径 / 私钥 / kubeconfig 内嵌密钥 /
云平台密钥 / 明文密码 / 内网 IP / 邮箱手机号 / 敏感文件名），加四条改进：

| 改进 | 原因 |
|---|---|
| 白名单**由 `course.yml` 的 `privacy.derive` + `privacy.allow` 生成**，不在脚本里手写数组 | 与事实源同源，避免两处维护 |
| 每条豁免**必须带 `reason` 字段**，缺失即报错 | 没有理由的豁免就是埋雷 |
| 支持 `--root <dir>`，可指向任意目录树 | 反例夹具必须在**仓库外**构造（见下） |
| 自带**正反例自测** | 门禁最大的风险是"静默放行"——第一课真栽过（中文文件名漏检） |

**反例夹具放哪**：不放仓库里。一个"故意含私钥和假内网 IP 的测试文件"如果被 git 跟踪，
生成物第一次跑隐私门禁就会红（A2 失效），模板仓库自己推送也会红。

做法：`tests/lib/harness.sh` 提供 `make_fixture_dir`，在**临时目录**里生成违规样本，
用 `privacy-check.sh --root "$tmp"` 检查，结束后删除。
仓库里只有**生成夹具的代码**，没有违规内容。

> 这条是对第一课的修正：第一课的做法是"把刻意构造的非法 IP 加进白名单"，
> 等于用**削弱规则**来测试规则。临时目录方案不需要任何豁免。

### 5.3 文档校验

`check-docs.py` 固定七项，阈值可配但**不建议改**：

| 检查 | 判据 |
|---|---|
| 代码围栏配对 | 围栏**行**数为偶数 |
| 表格列数 | 每张表所有行竖线数一致 |
| 内部锚点 | 所有以井号开头的内部链接都能对上标题 slug |
| 标题层级 | 不跳级（需先剔除代码块） |
| 编码 | `U+FFFD` 计数为 0 |
| 行尾空格 | 0 |
| 首末行 | 是完整句子 |

输出格式：`文件:行号: 问题`，可直接被编辑器和 CI 解析。

**适用范围与严格度**（这是评审提出的一个真问题）：

| 模式 | 作用范围 | 行为 |
|---|---|---|
| `gate.sh docs`（默认） | **全部** `*.md` | 只做上表七项格式检查 |
| `gate.sh docs --sections` | 仅 `chapters.dir` 下匹配 `chapters.pattern` 的文件 | 额外要求八个小节标题齐全 |
| `gate.sh docs --strict` | 同上 | 还要求小节正文非空 |

- **章节检查绝不作用于 `00-README`、`decisions.md`、`conventions.md`、附录**，
  否则合法文档会被章节规则判死。
- `strict_sections` 在 `course.yml` 里默认 `false`：生成出来的空壳章节不算错。
  作者开始写正文时改 `true`，CI 才会真正卡"这章还没写完"。
- 生成器跑的是默认模式，所以**生成即绿**（A2）；严格度是作者主动加码，不是默认陷阱。

### 5.4 前置条件检查

`check-prereqs.sh` 读 `course.yml`：

1. 逐条跑 `tools[].check`，解析版本，与 `min_version` 比较；
2. 缺失或不达标 → 打印 `name`、`要求`、`当前`、`install` 命令，退出码 1；
3. `required: false` 的只警告，不影响退出码；
4. `verify.infra` 为空 → **警告并提示"真机验证未完成"**，不影响退出码
   （那是 DoD 的事，不是环境的事）。

**可用性要求**：报错信息必须是"复制粘贴就能装"，不是"请安装 kubectl"。

**技能检查（评审第 7 点，已收窄）**：技能不是文件系统里能可靠探测的东西，
所以 `skills` 块**只打印清单，永不改变退出码**：

```
[notice] 本课程建议在 agent 中加载以下技能：
         required: brainstorming, writing-plans
         optional: systematic-debugging
         无法自动确认是否已安装，请自行检查。
```

宁可"提醒但不确定"，也不要"检测不到就报错"，更不要"检测不到就静默放过"。

### 5.5 门禁自测

`tests/test-privacy-gate.sh` 与 `tests/test-docs-gate.sh` 必须**双向**断言：

- 干净输入 → 退出码 0；
- 构造违规输入 → 退出码 1，且**报出的位置正确**。

只测"通过"的门禁等于没测。

---

## 6. 四条红线如何变成机制

这是模板的核心价值。每条红线都要有一个**不依赖自觉**的落点。

| 红线（C8） | 机制 | 验证方式 | 强度 |
|---|---|---|---|
| **不确认就删文件** | ① `AGENTS.md` 硬门禁条目；② 生成器拒绝写入非空目录；③ 约定删除走回收站而非 `rm`；④ `docs/decisions.md` 记录每次删除的理由 | `test-idempotent.sh` 断言非空目录被拒 | 中 |
| **不确认就开始写** | ① `AGENTS.md` 顶部「动手前必须先出方案并等待确认」；② `definition-of-done.md` 第一条是"方案已确认"；③ 会话台账 `.sdd/` 要求记录确认来源 | 人工审阅 `AGENTS.md`（无法自动） | 弱→中 |
| **隐私检查执行不到位** | ① pre-push 钩子（生成时自动 `core.hooksPath`）；② CI 双跑；③ 正反例自测；④ `AGENTS.md` 禁止 `--no-verify` | `test-privacy-gate.sh` + CI 状态 | 强 |
| **不按流程执行** | ① `AGENTS.md` 流程分级（轻量默认 + 5 条触发条件）；② `.sdd/` 台账模板（计划/裁决/门禁日志）；③ 重流程章节的 brief 模板 | 台账存在性（软检查） | 中 |

### 6.1 诚实说明

前两条本质是**行为约束**，只能靠契约文字 + 评审，不可能靠脚本拦住。
把它们写成"强机制"是自欺。模板能做的是：

1. 把契约放在 `AGENTS.md` **最前面**（不是附录）；
2. 让违反者**留下痕迹**（决策日志、台账）；
3. 在复盘模板里固定一问："本次有没有未经确认的动作？"

---

## 7. 模板演进与同步（C10）

### 7.1 生成时写入

`.course/template-version`：

```yaml
template: course-template
version: 0.1.0
profile: generic
sha: <生成时模板仓库的短哈希>
generated_at: 2026-11-02
```

`.course/core-manifest.txt`：`core/` 下每个文件的 `sha256` 一行。

### 7.2 文件分三类（评审第 5 点）

`core/` 里的文件**不是同一种东西**，同步策略必须分开，否则 `decisions.md`
写完第一条决策就永久冲突（G4 直接失效）。

| 类别 | 文件 | 同步行为 |
|---|---|---|
| `managed` | `scripts/**`、`tests/**`、`.githooks/**`、`.github/**`、`.gitea/**` | 模板新版**直接覆盖**；本地改过则报冲突（作者不该改这些） |
| `managed-region` | `AGENTS.md` | 只替换 `<!-- TEMPLATE:BEGIN -->` 与 `<!-- TEMPLATE:END -->` 之间的契约正文；区域外作者可自由增删 |
| `seed-only` | `docs/conventions.md`、`docs/decisions.md`、`docs/definition-of-done.md`、`docs/architecture.md`、`docs/retrospective.md` | 生成时写入一次，**此后永不触碰** |

`AGENTS.md` 之所以要 `managed-region`：**契约正文是模板最值钱的部分**，
不留通道的话，契约改进永远到不了老课程。区域外的"本课程补充约定"归作者。

### 7.3 同步语义

`scripts/sync-template.sh /path/to/course-template`：

```
① 读 .course/template-version，确认模板版本
② 按 classes 分类处理：
     managed          → 比对哈希：未改则覆盖，改过则记冲突
     managed-region   → 只比对区域内容：未改则替换，改过则记冲突
     seed-only        → 跳过，不比对
③ 无冲突 → 覆盖，更新 manifest 与 version
④ 有冲突 → 输出清单 + 建议（保留本地 / 采用模板 / 手工合并），退出码 2
⑤ 任何情况下都不触碰 chapters/、facts.source、profile 目录、区域外内容
```

**关键决策**：**不做三路合并**。自动合并脚本类文件会把"模板的修复"和
"课程的本地改动"搅在一起，出问题时无法判断谁错了。冲突就停下，让人决定。

### 7.4 版本策略

- `MAJOR`：`course.yml` schema 或目录结构破坏性变更（需要迁移脚本）；
- `MINOR`：新增门禁、新增校验项、新增 profile；
- `PATCH`：规则修正、误报修复、文案。

---

## 8. 复盘 §12.4 七条改进的落点

| # | 改进 | 落在模板哪里 | 怎么算落地 |
|---|---|---|---|
| 1 | 真机验证前置 | `course.yml` 的 `verify.infra` + `definition-of-done.md` 第 2 条 | `verify.infra` 为空时 `gate.sh` 警告；DoD 不允许勾"已验证"；不伪装成通过 |
| 2 | CI 化门禁 | `.github/workflows/gate.yml` + `.gitea/workflows/gate.yml` | 生成物开箱即有两个 workflow |
| 3 | 测试入库 | 生成即入库（`.gitignore` 只排产物） | `test-generate.sh` 断言 `tests/` 被跟踪 |
| 4 | 失败路径章节 | `conventions.md` 的**八段式**（七段 + 常见报错） | `gate.sh docs --sections` 只作用于 `chapters.dir`，每章必须含该节 |
| 5 | 单点演练 | `definition-of-done.md` 含"逃生路径已演练并记录耗时" | DoD 手工勾选 |
| 6 | 文档自检脚本入库 | `core/scripts/check-docs.py` | 生成物自带 |
| 7 | 数字自动化 | `core/scripts/gen-stats.py`，规范里禁止手写规模数字 | `check-docs.py` 检测到"共 N 章"式硬编码时警告 |

**第八段式**（第一课是七段，这里加一段）：

```
概念 → 清单 → 命令 → 实测输出 → 常见报错 → 坑 → 练习 → 答案
                                  ^^^^^^^^^^ 新增
```

---

## 9. Profile 规格

### 9.1 `generic`（最小可用）

| 项 | 值 |
|---|---|
| 工具 | `git`、`python3`（都 required） |
| 事实源 | `docs/architecture.md` 的拓扑表（无独立配置文件） |
| 验证 | `./scripts/gate.sh all` |
| stub | 无 |
| 章节目录 | `docs/chapters/` |
| 额外目录 | 无 |

用途：Docker、CI/CD、Shell 编程、监控这类"不需要固定拓扑"的课。

### 9.2 `k8s-vagrant`（参考剖面）

| 项 | 值 |
|---|---|
| 工具 | 上表 + `vagrant`、`ansible`、`kubectl`、`helm` |
| 事实源 | `vagrant/nodes.yml` |
| 验证 | `verify.self: ./scripts/gate.sh all`；`verify.infra` 由作者填（如 `./k3s-ops.sh status`） |
| 白名单 | `privacy.derive.from: vagrant/nodes.yml`（`ip-like-scalars`） |
| stub | `vagrant`、`ansible-playbook`、`kubectl` |
| 章节目录 | `docs/k8s-tutorial/` |
| 额外目录 | `vagrant/`、`ansible/`（空角色骨架） |

**从第一课抽什么、不抽什么**：

| 抽（结构/经验） | 不抽（内容） |
|---|---|
| `nodes.yml` 的字段设计 | 45 章教程正文 |
| 4 个 Ansible 角色的**目录形态** | 角色里的具体任务 |
| `resolve_host` 单一事实源模式 | 具体实现 |
| stub 的写法 | 具体断言 |
| 端口/拓扑表的呈现格式 | 具体的端口值 |

---

## 10. 模板自身的测试（A3）

| 测试 | 覆盖 | 断言要点 |
|---|---|---|
| `test-generate.sh` | 每个 profile | 目录存在、无 `{{` 残留、三道门禁全绿、`git ls-files` 含 `tests/` |
| `test-idempotent.sh` | 生成器 | 非空目标目录 → 拒绝且**不写入任何文件** |
| `test-sync.sh` | 同步 | 老版本生成 → 模板升 MINOR → sync → `managed` 更新、`seed-only` 不变、`managed-region` 只换区域；本地改过 `managed` 则退出码 2 |
| `test-privacy-gate.sh` | 隐私门禁 | 正例 0 / 反例 1 + 位置正确；**反例夹具建在临时目录**，且断言仓库内无违规文件 |
| `test-docs-gate.sh` | 文档门禁 | 围栏奇数、表格错列、锚点失效各一个反例；`--sections` 不误伤 README |
| `test-prereqs.sh` | 前置条件 | 伪造一个缺失工具 → 退出码 1 且输出含安装命令 |
| `test-profile-purity.sh` | 剖面 | `profiles/**` 下**不允许出现 `*.sh`** |

模板自己的 CI 跑这六个。**模板的测试挂了，说明下一门课会带着 bug 出生。**

---

## 11. 分阶段实施

| 阶段 | 产出 | 完成判据 |
|---|---|---|
| P0 | 仓库骨架、`course.yml` schema、`new-course.sh --dry-run` | 能打印"将要生成什么"，不落盘 |
| P1 | `core/` 四道门禁 + 门禁自测 | `test-privacy-gate.sh` / `test-docs-gate.sh` 全绿 |
| P2 | `generic` profile + 端到端生成 | `test-generate.sh generic` 全绿 |
| P3 | `k8s-vagrant` profile | `test-generate.sh k8s-vagrant` 全绿 |
| P4 | `sync-template.sh` + 版本策略 | `test-sync.sh` 全绿 |
| P5 | CI（Gitea + GitHub）+ 模板自测进 CI | 推送后 CI 绿 |

**P2 是第一个真正的里程碑**：从这一阶段起，"生成一个能跑门禁的项目"这件事才成立。

---

## 12. 留给实施者的判断（我的建议，可推翻）

| 项 | 建议 | 理由 |
|---|---|---|
| 语言 | bash + Python 3 标准库 | 与第一课一致，零第三方依赖 |
| 模板渲染 | `sed` / `awk` 变量替换 | 不为 3 个变量引入 jinja2 |
| 文档语言 | 中文 | 与目标读者一致 |
| 许可证 | MIT | 与第一课一致 |
| 元数据目录 | `.course/` | 不与 `.git/` `.github/` 抢名字空间 |
| 章节骨架 | 只生成八段标题的空壳 | 生成正文等于替作者写，而且必然写歪 |
| CI 双份 | Gitea + GitHub 各一份 | 各 20 行，避免"换平台就失效" |
| `series` 名 | `devops-self-study` | 与第一课定位一致，改起来只是字符串 |
| `--no-git` | 支持 | 在已有仓库里生成是真实需求，成本 5 行 |
| 示例章节 | **不附带** | 模板里出现课程正文就违反 §2.2；八段式靠 `conventions.md` 说明 |

---

## 13. 不解决的事（明确排除）

| 项 | 为什么不解决 |
|---|---|
| 课程内容质量 | 模板能保证格式，保证不了"讲得对不对" |
| 学员环境差异 | 只检查"有没有装"，不检查"装得对不对" |
| 多人协作冲突 | 单人课程项目，不引入分支模型 |
| 模板的迁移脚本 | `MAJOR` 变更时手工迁移，不写自动化——第一次 MAJOR 之前不知道要迁什么 |
| 章节顺序正确性 | 大纲由作者负责，模板只检查文件存在 |

---

## 14. 一个需要你回答的问题

**P5 的"CI 绿"是哪种绿？**

- **A. 文件级**：workflow 文件存在 + 本地静态校验（`actionlint` 或等价）。
  不需要远程、不需要 runner，`k3s-ops` 现在的状态就能做。P5 保持不变。
- **B. 真跑一次**：需要一个可达的远程（Gitea/GitHub）+ 一个已注册的 runner，
  P5 要新增一个前置任务（建远程、注册 runner、配 secret），里程碑往后挪。

这个答案改变的是**里程碑边界**，不是措辞：选 B 的话 P5 从"写 20 行 YAML"
变成"搭一条 CI 链路"，工作量差一个数量级。

我的倾向是 **A + 明确标注"CI 尚未真跑过"**——与第一课"未真机验证"的处理一致：
先承认边界，不假装。

---

## 15. 独立评审的 8 个问题与处置

评审以"要照这份文档做计划的人"视角读了一遍，提出 8 个会逼出昂贵猜测的缺口。
处置如下（前 7 条已写进上文，第 8 条是待你回答的问题）。

| # | 问题 | 处置 | 落在哪 |
|---|---|---|---|
| 1 | 只用 stdlib 怎么解析 YAML？ | 不自己造。**PyYAML 作为 `required: true` 工具显式声明**，与第一课一致；`reason` 因此必须是字段而非注释 | §2.2、§4.4 |
| 2 | `verify` 指向课程还不存在的脚本？ | 拆成 `verify.self`（开箱可跑）与 `verify.infra`（需真机，作者填）。生成即绿，但"未验证"不被伪装成"已验证" | §4.4、§8 |
| 3 | 剖面预置的 IP 怎么过隐私门禁？ | 白名单**从 `facts.source` 派生**（`privacy.derive`），提取器固定在 core，剖面仍只有数据 | §4.4、§5.2、§9.2 |
| 4 | 反例夹具会触发自己的门禁？ | 夹具**运行时建在临时目录**，`privacy-check.sh --root` 指向它。仓库里零违规内容，也不需要任何豁免 | §5.2 |
| 5 | `decisions.md` 一写就永久冲突？ | 文件分三类：`managed` / `managed-region` / `seed-only`。`decisions.md` 是 seed-only | §7.2 |
| 6 | "CI 绿"到底要不要真跑？ | **待你回答**（§14） | §14 |
| 7 | 技能怎么"检测已安装"？ | 收窄为**只提示、永不改退出码** | §5.4 |
| 8 | `--require-sections` 会误伤 README？ | 章节检查只作用于 `chapters.dir`；严格度由 `strict_sections` 显式开启 | §5.3、§8 |

评审没有提、我也认为不值得展开的：`sed` vs jinja、`.course/` 命名、许可证、
文档语言、章节空壳粒度。这些实施时随手定，改起来便宜。
