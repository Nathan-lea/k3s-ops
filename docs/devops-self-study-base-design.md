# 课程项目模板设计

> 目标产物：一个**独立 git 仓库** `devops-self-study-base`，供克隆后生成新的独立课程项目。
>
> 本文是设计文档，不是操作手册。实施计划另出。

| 项 | 值 |
|---|---|
| 状态 | 待批准实施（8 问处置见 §17；§15 跨平台、§16 镜像方案均为新增，未独立评审） |
| 日期 | 2026-11-03（初版 11-02，新增 §15 跨平台、§16 镜像与多系统） |
| 母项目 | `k3s-ops`（第一课，已完成，**不回填**） |
| 产物仓库 | `devops-self-study-base`（新建，独立） |
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
| G1 | 一条命令生成新课程仓库，含完整骨架 | `new-course.sh ../demo --profile minimal` 成功，且生成物门禁全绿 |
| G2 | 生成即自带门禁（隐私 / 文档 / 前置条件 / 镜像） | 生成结束时四道检查都跑过且退出码 0 |
| G3 | 规范只写一份，所有课程强制一致 | 规范文件全部在 `core/`，`profiles/` **不含**任何规范 |
| G4 | 模板可演进，老课程能同步 `core/` 更新 | `sync-template.sh` 能把 core 更新合入，且不碰课程内容 |
| G5 | 复盘 §12.4 的七条改进全部落成机制 | §8 的对照表逐条有落点文件 |
| G6 | k8s 与非 k8s 课程同一套模板 | 两个 profile 生成出的门禁行为完全一致 |
| G7 | **Linux 桌面与 Windows 桌面学员都能完成全部实验**，虚拟机平台统一 VirtualBox | 两个 profile 各生成一次，`platform/` 齐备；Windows 侧只需 2 步；Linux 侧零额外步骤（§15） |
| G8 | 默认 Ubuntu 够用，需要时**按节点换镜像**演示不同发行版 | `gate.sh boxes` 通过；一台 Debian 系与一台 RHEL 系 VM 能同课程并存（§16） |

### 2.2 非目标

- **不预置任何课程内容**。不把 k3s、Docker、Terraform 的任何一章塞进模板。
- **不回填第一课**。`k3s-ops` 保持现状，作为参考样本而非基线。
- **不做服务端 / Web UI / 包管理器**。模板是一个仓库 + 几个脚本。
- **不追求跨语言**。脚本用 bash + Python 3；配置解析用 **PyYAML**（与第一课一致，
  作为显式前置声明，见 §4.4，不做自制 YAML 解析器）。
- **不做插件市场**。profile 就是目录，没有注册中心。
- **不走 WSL2 / Docker Desktop 路线**。与 VirtualBox 互斥，见 §15.1（H3）。
- **不给 Windows 写第二套命令**。只提供入口脚本与控制机，课程命令仍是一套（§15.3）。
- **不做自己的虚拟机镜像**。不自制 box、不走 ISO 手工最小安装、不覆盖非 bento 镜像（§16.6）。

### 2.3 反目标（技术上跑通也算失败）

| # | 反目标 | 为什么是失败 |
|---|---|---|
| A1 | `core/` 里出现 `if profile == "multi-vm"` 这类分支 | 一旦开始分叉，第二个 profile 就会把内核拖成补丁堆 |
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
| C12 | 学员机器是 **Linux 桌面 + Windows 桌面** | "学员使用的机器以 linux 桌面和 Windows 桌面为主" |
| C13 | 虚拟机平台**统一 VirtualBox** | "统一使用 virtualBox 做为虚拟机平台" |
| C14 | 两种桌面都要能**正常完成实验** | "要保证两种桌面的用户都能正常操作——就像当前项目一样" |
| C15 | 镜像**只用 bento 系现成 box**，默认 Ubuntu，需要时按节点换 | "只用 bento 系现成 box 就够"；服务器 OS 类课程可混两个系演示差异 |

C12–C14 的详细设计见 **§15 跨平台设计**。这是全篇最容易做浅的一块：
只写"支持 Windows"等于没写，必须把换行、编码、权限、嵌套虚拟化这些
真正会拦住学员的东西逐条落到文件上。

C15 的详细设计见 **§16 虚拟机镜像与多系统**：默认值、允许清单、跨系差异、
干净起点断言、版本策略。

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

剖面名按**形状**取（`minimal` / `multi-vm`），不按主题取——否则第三门课就会为了
"像 k8s 那样"再长一个剖面出来（§9 开头）。

### 4.2 模板仓库结构

```
devops-self-study-base/
├── README.md                      # 三条命令上手
├── LICENSE                        # MIT
├── VERSION                        # 语义化版本
├── CHANGELOG.md
├── new-course.sh                  # 生成器
│
├── core/                          # 逐字拷贝进生成物
│   ├── AGENTS.md.tmpl             # 契约（流程分级 + 四条红线 + 单一事实源）
│   ├── .gitignore
│   ├── .gitattributes             # 换行规则（跨平台生死线，见 §15.9）
│   ├── .githooks/pre-push         # → scripts/gate.sh --privacy
│   ├── .github/workflows/gate.yml
│   ├── .gitea/workflows/gate.yml
│   ├── platform/                  # 平台适配层（与主题无关，见 §15）
│   │   ├── README.md              # 平台矩阵 + 支持边界
│   │   ├── vm/                    # 镜像与干净起点（与桌面平台无关，见 §16）
│   │   │   ├── boxes.yml          # bento 允许清单（只存稳定属性，不存版本）
│   │   │   ├── probe.sh           # 记录实际镜像版本（宿主执行）
│   │   │   └── baseline.sh        # VM 内断言 assert_absent
│   │   ├── linux/check.sh         # VirtualBox / vboxdrv / vboxusers / 网段 / 内存
│   │   └── windows/               # 按 platforms.windows.mode 裁剪（见 §15.6）
│   │       ├── check.ps1          # 管理员 / PS 版本 / Hyper-V / 网段 / 内存
│   │       ├── up.ps1             # 前置检查 → vagrant up → 引导控制机
│   │       ├── down.ps1
│   │       ├── destroy.ps1
│   │       ├── provision-control.sh   # 控制机引导（7 步，幂等）
│   │       ├── emit.ps1           # UTF-8 无 BOM 写入工具函数
│   │       └── guest/bin/<tool>   # 宿主专属命令的 shim
│   ├── scripts/
│   │   ├── gate.sh                # 统一门禁入口（privacy|docs|prereqs|boxes|all）
│   │   ├── privacy-check.sh       # 8 条规则
│   │   ├── check-boxes.sh         # 镜像允许清单 + 家族统计（§16.2）
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
│   ├── minimal/                   # 形状：单机；工具只要 git + python3
│   │   ├── course.yml
│   │   ├── chapters/              # 章节大纲（只有标题，无正文）
│   │   └── files/                 # 额外目录骨架
│   └── multi-vm/                  # 形状：多台 VM + 配置管理（结构抽自第一课）
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
├── .gitattributes
├── .githooks/pre-push
├── .github/workflows/gate.yml
├── .gitea/workflows/gate.yml
├── scripts/                       # 与 core 一致
├── docs/
│   ├── conventions.md
│   ├── decisions.md
│   ├── definition-of-done.md
│   ├── architecture.md
│   └── <chapters-dir>/            # 课程决定，默认 docs/chapters/
├── tests/
├── <profile 提供的额外目录>        # 如 vagrant/ ansible/
└── logs/                          # gitignore
```

### 4.4 `course.yml` 契约

单一配置源（C3/C5/C6）。生成后仍然有效——它是**活配置**，不是一次性输入。

下面是契约的**逐字段示例**，不是某个 profile 的完整输出：取值只用于说明字段怎么填。
门禁只读结构、不读内容——**每个值都可以按课程改**，包括章节目录名与工具清单。

```yaml
course:
  name: ""                 # 生成时注入（kebab-case）
  title: ""                # 生成时注入
  series: "devops-self-study"
  language: "zh"
  audience: ""             # 写给谁看（影响措辞与深度）

profile: multi-vm

# --- C6 前置条件 -------------------------------------------------
tools:
  - name: git
    min_version: "2.30"
    check: "git --version"
    install: "apt-get install -y git"
    required: true
    where: host              # host | control | both（默认 both，见 §15.5）
  - name: python3
    min_version: "3.8"
    check: "python3 --version"
    install: "apt-get install -y python3"
    required: true
    where: both
  - name: pyyaml           # 配置解析器：必须显式声明，不能假设系统已有
    min_version: "5.4"
    check: "python3 -c 'import yaml; print(yaml.__version__)'"
    install: "python3 -m pip install pyyaml"
    required: true
    where: both

skills:                    # agent 技能：仅提示，永不改变退出码
  required: [brainstorming, writing-plans]
  optional: [systematic-debugging]

# --- C12/C13/C14/C15 平台（完整字段见 §15.5、§16.2） -------------------
platforms:
  vm:
    provider: virtualbox       # C13：固定值，不允许改成别的
    default_box: "bento/ubuntu-24.04"   # C15：只允许 bento 系（§16）
    arch: amd64
    assert_absent: [docker, nginx]      # 干净起点断言，VM 内执行（§16.5）
  windows:
    mode: control-node     # ssh-only | control-node
    min_ps: "5.1"
    control_node:
      name: ops
      memory: 1024
  linux:
    require_vboxusers: true

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
  dir: "docs/chapters"             # 课程自定，例如 docs/k8s-tutorial
  pattern: "{nn}-{title}.md"
  strict_sections: false           # 开始写正文后改 true，CI 才会校验小节非空
  groups:                          # 章节大纲：只有标题，无正文（种子值，按主题改）
    - 准备环境
    - 核心操作
    - 故障排查
```

**四条设计要点**：

1. **`verify` 拆成 `self` 与 `infra`**。`self` 是生成物自带、不依赖真实环境的自检
   （`gate.sh all`），保证"开箱即绿"（A2）；`infra` 是需要真实机器的那条，
   作者填，为空时 `gate.sh` 只警告不失败，但 DoD 不允许勾"已验证"。
   ——这就是复盘里"诚实边界"的机制化：**未验证就是未验证，不是失败，但也不能算完成**。
2. **`privacy` 白名单从事实源派生**。`derive` 只声明"从哪个文件、用哪个提取器"，
   提取器本身在 `core/` 里固定（`ip-like-scalars` 之类），所以
   **剖面仍然只有数据、没有逻辑**（§4.1 硬规则）。
3. **`reason` 是结构化字段，不是 YAML 注释**。注释会被 `yaml.safe_load` 丢弃，
   也会被复制粘贴丢失；只有字段能进检查和报表。
4. **`platforms` 是唯一允许描述"宿主"的块**。它只说"用什么虚拟机、Windows 要不要
   控制机、控制机叫什么"，不说"Windows 上该跑什么命令"——命令永远只有一套（§15.3）。
   `vm` 是**对象**而不是字符串（`vm: virtualbox`），因为镜像相关字段不止一个
   （`provider` / `default_box` / `arch`），字符串没法往下加（§16.2）。

---

## 5. 门禁设计

### 5.1 五道门禁

| 门禁 | 脚本 | 触发时机 | 失败后果 |
|---|---|---|---|
| 隐私 | `privacy-check.sh` | pre-push（强制）+ CI | 阻断推送 |
| 文档 | `check-docs.py` | `gate.sh` + CI | 阻断 |
| 前置条件 | `check-prereqs.sh` | 生成时 + 每次 `gate.sh all` | 缺必装项则阻断 |
| 镜像 | `check-boxes.sh` | `gate.sh all` + CI | 未知 box 名阻断；跨系提示不阻断（§16.2） |
| 红线自检 | `gate.sh redlines` | 开工前手工跑 | 提示（见 §6） |

统一入口 `scripts/gate.sh`：

```
gate.sh privacy    # 只跑隐私（pre-push 用，约 2 秒）
gate.sh docs       # 只跑文档
gate.sh prereqs    # 只跑前置条件
gate.sh boxes      # 只跑镜像（静态，不需要 VirtualBox）
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
template: devops-self-study-base
version: 0.1.0
profile: multi-vm
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

`scripts/sync-template.sh /path/to/devops-self-study-base`：

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

**命名按形状，不按主题**。剖面名只描述"生成出来的项目骨架有多重"，不描述课程讲什么：

| 剖面 | 主轴 | 典型课程 |
|---|---|---|
| `minimal` | 单台 VM、无配置管理 | Docker、CI/CD、Shell、监控 |
| `multi-vm` | 多台 VM + 配置管理 + 控制机 | k8s、Terraform + Ansible、Swarm |

主题**只出现在值里**（`chapters.dir`、`tools`、stub 清单），不出现在名字里。
否则第一门 Docker 课会想"照 k8s 那个再来一份"，剖面就会按主题繁殖（A1）。

**没有默认剖面**：`new-course.sh` 的 `--profile` 必填，不写就报错并列出可选值。
`course.yml` 里的 `profile:` 只是**生成来源的记录**（供同步时比对），不驱动任何分支——
`core/` 与 `platform/` 都不读它（A1）。

### 9.1 `minimal`（最小可用）

| 项 | 值 |
|---|---|
| 工具 | `git`、`python3`、`pyyaml`（都 required，`where: both`） |
| 平台 | `platforms.windows.mode: ssh-only`（Windows 只需 2 步，`vagrant ssh` 进 VM 敲命令） |
| 镜像 | `default_box: bento/ubuntu-24.04`，单节点、无节点级覆盖；`assert_absent: []`（默认空，课程按需声明） |
| 事实源 | `docs/architecture.md` 的拓扑表（无独立配置文件） |
| 验证 | `./scripts/gate.sh all` |
| stub | 无 |
| 章节目录 | `docs/chapters/` |
| 额外目录 | `platform/`（只含 `windows/{check,up,down,destroy}.ps1` + `emit.ps1`） |

用途：Docker、CI/CD、Shell 编程、监控这类"不需要固定拓扑"的课。

### 9.2 `multi-vm`（多台 VM + 配置管理，参考剖面）

| 项 | 值 |
|---|---|
| 工具 | 上表 + `vagrant`、`ansible`、`kubectl`、`helm`（后四者 `where: host` 或 `control`，见 §15.5） |
| 平台 | `platforms.windows.mode: control-node`（Windows 侧 3 台 VM：2 节点 + `ops` 控制机） |
| 镜像 | `default_box: bento/ubuntu-24.04`；节点可覆盖 `box:`（如 `box: bento/rockylinux-9`） |
| 事实源 | `vagrant/nodes.yml` |
| 验证 | `verify.self: ./scripts/gate.sh all`；`verify.infra` **默认空**，由作者填成课程的真机检查（例如 `./k3s-ops.sh status`） |
| 白名单 | `privacy.derive.from: vagrant/nodes.yml`（`ip-like-scalars`） |
| stub | `vagrant`、`ansible-playbook`、`kubectl` |
| 章节目录 | `docs/chapters/`（种子大纲偏 k8s，按主题改） |
| 额外目录 | `vagrant/`、`ansible/`（空角色骨架）、`platform/`（含 `provision-control.sh` 与 shim） |

**名字不是承诺**：`multi-vm` 只说"有多台 VM 和配置管理"，不保证工具清单里的
`kubectl` / `helm` / 章节大纲适合你的主题。它们都是**种子值**：生成时写一次，
作者按课程删改——剖面是起点，不是约束（§4.4 的"活配置"）。

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
| `test-generate.sh` | 每个 profile × 每个 `windows.mode` | 目录存在、无 `{{` 残留、四道门禁全绿、`git ls-files` 含 `tests/`；`ssh-only` 下**不存在** `provision-control.sh` 与 shim |
| `test-idempotent.sh` | 生成器 | 非空目标目录 → 拒绝且**不写入任何文件** |
| `test-sync.sh` | 同步 | 老版本生成 → 模板升 MINOR → sync → `managed` 更新、`seed-only` 不变、`managed-region` 只换区域；本地改过 `managed` 则退出码 2 |
| `test-privacy-gate.sh` | 隐私门禁 | 正例 0 / 反例 1 + 位置正确；**反例夹具建在临时目录**，且断言仓库内无违规文件 |
| `test-docs-gate.sh` | 文档门禁 | 围栏奇数、表格错列、锚点失效各一个反例；`--sections` 不误伤 README |
| `test-prereqs.sh` | 前置条件 | 伪造一个缺失工具 → 退出码 1 且输出含安装命令；`where: control` 的项在宿主上**不**报错 |
| `test-profile-purity.sh` | 剖面 | `profiles/**` 下**不允许出现 `*.sh`**；目录名必须在白名单内（`minimal` / `multi-vm`），新增剖面要走设计决策，不能顺手按主题加 |
| `test-platform.sh` | 跨平台（§15.14） | `.gitattributes` 覆盖所有扩展名；全仓库无 BOM；`git ls-files --eol` 索引换行正确；`nodes.windows.yml` 重新生成后 diff 为空；PS 静态合规（无 `??`/`?.`/`-Parallel`/`Set-Content`）；Linux 侧 check 脚本可在 CI 跑 |
| `test-boxes.sh` | 镜像与干净起点（§16） | 未知 box 名 → 退出码 1 且给最近候选；省略节点 `box` 时继承 `default_box`；两台不同家族 → 输出跨系提示但不改退出码；夹具声明 `assert_absent: [nginx]` 且命中已装命令 → 退出码 1（用临时目录里的假可执行文件构造，不建 VM）；`assert_absent` 为空时不做缺席断言 |

模板自己的 CI 跑这九个。**模板的测试挂了，说明下一门课会带着 bug 出生。**

---

## 11. 分阶段实施

| 阶段 | 产出 | 完成判据 |
|---|---|---|
| P0 | 仓库骨架、`course.yml` schema、`new-course.sh --dry-run` | 能打印"将要生成什么"，不落盘 |
| P1 | `core/` 门禁（隐私 / 文档 / 前置条件）+ `.gitattributes` + BOM/换行校验 + 门禁自测 | `test-privacy-gate.sh` / `test-docs-gate.sh` / `test-platform.sh`（换行部分）全绿 |
| P2 | `minimal` profile + `platform/linux` + `platform/windows` 的 `ssh-only` 档 + 镜像清单与 `assert_absent` + 端到端生成 | `test-generate.sh minimal --mode ssh-only` 全绿；`test-boxes.sh` 全绿；Linux 桌面手工走一遍 |
| P3 | `multi-vm` profile + `control-node` 档（`provision-control.sh`、shim、`gen-nodes.py`）+ 节点级 `box:` 覆盖 | `test-generate.sh multi-vm --mode control-node` 全绿；PS 静态合规；两家族并存的拓扑能过 `gate.sh boxes` |
| P4 | `sync-template.sh` + 版本策略 | `test-sync.sh` 全绿 |
| P5 | CI（Gitea + GitHub）+ 模板自测进 CI | workflow 文件存在、两处 `gate.sh all` 等价、本地静态校验通过；**不要求真跑过**（§14） |

**P2 是第一个真正的里程碑**：从这一阶段起，"生成一个能跑门禁的项目"这件事才成立。

**平台工作不在独立阶段**，而是并进 P2（`ssh-only`）与 P3（`control-node`）——否则会得到"做完 P3 才发现平台层要返工"的顺序错误。

**镜像工作同理**：并进 P2（默认单镜像 + `assert_absent`）与 P3（节点级 `box:` 覆盖）。
`boxes.yml` 只是数据、`check-boxes.sh` 只是门禁，没有独立阶段可切。

Windows 实机的四项验证（自提权、host-only 网卡、shim 的 TTY、编码）**不属于任何阶段的完成判据**，它们只能标注"未验证"（§15.14）。把不可执行的事写进判据，等于给验收注水。

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
| 默认镜像 | `bento/ubuntu-24.04` | 24.04 LTS 标准支持到 2029-04，覆盖整个系列；代价是第一课的实测结论在 22.04 上取得，`multi-vm` 首次真机跑要在 24.04 上复核（§16.1） |
| `boxes.yml` 存什么 | 只存家族 / 包管理 / 防火墙 / SELinux，**不存版本** | 版本随构建滚动，存了就要长期跟着改；实测版本记在 README，允许过时（§16.6） |

---

## 13. 不解决的事（明确排除）

| 项 | 为什么不解决 |
|---|---|
| 课程内容质量 | 模板能保证格式，保证不了"讲得对不对" |
| 学员环境差异 | 只检查"有没有装"，不检查"装得对不对" |
| 多人协作冲突 | 单人课程项目，不引入分支模型 |
| CI 的真实执行 | 需要远程 + runner，属于环境而非模板（§14 已明确标注为未验证） |
| 模板的迁移脚本 | `MAJOR` 变更时手工迁移，不写自动化——第一次 MAJOR 之前不知道要迁什么 |
| 章节顺序正确性 | 大纲由作者负责，模板只检查文件存在 |
| Windows 实机行为 | 模板作者没有 Windows 机器；只做静态合规 + 明确标注"未验证"（§15.14） |
| 学员机器性能差异 | 只比较内存总量，不测实际 CPU/IO；拓扑可调，但调多少不管 |
| VirtualBox 版本碎片 | 只要求 ≥ 7.0，不覆盖各发行版打包差异 |
| 非 bento 镜像 | 适配成本按镜像计（默认用户、Guest Additions、网络各不相同）；C15 已把来源钉在 bento 系（§16.6） |
| ISO 手工最小安装 / 自制 box | "最小"由 bento + `assert_absent` 覆盖；做 ISO 只会把失败点提前到分区与引导 |
| arm64 与 Windows guest | 各需一套独立验收矩阵，且 Windows 控制机方案本身是 amd64 假设 |
| box 版本锁定 | 与 bento 按需重发的节奏冲突；回退是操作而不是配置（§16.6） |
| 跨发行版的通用装包/防火墙封装 | 那正是服务器 OS 类课程要教的内容；模板预置等于按 profile 分叉（§16.4，A1） |

---

## 14. CI 的验收口径（已定）

**决定：A —— 文件级**。

| 项 | 结论 |
|---|---|
| P5 验收 | workflow 文件存在 + 本地静态校验通过 |
| 不包含 | 建远程、注册 runner、配 secret、跑出真实的绿 |
| 仓库里必须写明 | "CI 尚未真跑过"（写入生成的 README 与 `definition-of-done.md`） |

理由：与第一课"未真机验证"同一处理方式——**先承认边界，不假装**。
把 B 塞进 P5，会让"模板能不能用"这个核心问题被"CI 环境搭不搭得起来"掩盖。

**后续触发条件**（写进 CHANGELOG 的 Unreleased 区）：当第二门课真实推送后，
如果 CI 从未真正执行过，就把"CI 真跑一次"升级为独立任务。

---

## 15. 跨平台设计（Linux 桌面 + Windows 桌面，VirtualBox）

### 15.1 问题与四条硬约束

第一课的结论不是"Windows 也能跑"，而是"**Windows 需要多一台机器**"。这一节把那条路泛化。

四条硬约束都来自实测，不是推测：

| # | 约束 | 后果 | 不能怎么做 |
|---|---|---|---|
| H1 | 课程命令是 bash + GNU 工具（`sed`/`awk`/`grep -P`/`install`/`chmod`） | Windows 原生跑不了 | 不写一套 PowerShell 等价实现：两份真相互相腐化 |
| H2 | Ansible 控制节点官方只支持 POSIX；Vagrant 的 ansible provisioner 必须在**执行 vagrant 的那台机器**上找到 `ansible-playbook` | Windows 宿主当不了控制机 | 不把 Ansible 塞进 Windows |
| H3 | VirtualBox 与 Hyper-V / WSL2 互斥 | 不能走 WSL2 曲线救国 | 不把 WSL2 写进前置条件 |
| H4 | VirtualBox 不支持嵌套 VT-x | VM 里不能再跑 Vagrant | 不在 VM 里套 VM |

H3 要单独说一句：WSL2 看着最省事（Windows 里自带 bash），但它要开 Hyper-V，而 Hyper-V 一开 VirtualBox 就退化成极慢的兼容模式，多数情况直接起不来。所以"支持 Windows"**不等于**"装个 WSL2"。

结论与第一课一致：**Vagrant 留在宿主，课程命令留在 Linux。**

### 15.2 三种平台形态

模板不假设所有课程都需要 Ansible。按"课程命令在哪里执行"分三档：

| 形态 | Linux 桌面 | Windows 桌面 | VM 数 | 典型课程 |
|---|---|---|---|---|
| A 原生 | 宿主即控制机，零额外步骤 | — | = 拓扑节点数 | 全部（Linux 侧永远走这条） |
| B 直连 | 同 A | 宿主只 `vagrant up` + `vagrant ssh`，命令在课程 VM 里敲 | = 拓扑节点数 | Docker、Linux 基础、监控 |
| C 控制机 | 同 A | 宿主造机器，另加一台 `role: ops` 控制机跑 Ansible | 节点数 + 1 | multi-vm、Terraform + Ansible |

形态是**嵌套**的：C 包含 B 的全部，B 包含 A 的全部。**Linux 侧永远是 A**，不可配置——这是固定行为，写进配置只为显式。

可配置的只有 Windows 侧的一个字段：`platforms.windows.mode ∈ {ssh-only, control-node}`（分别对应 B 和 C）。

判断标准一句话：**课程命令要在集群外执行吗？**

- 不需要（`vagrant ssh` 进去敲就够）→ `ssh-only`，Windows 不必开第三台机器；
- 需要（Ansible / kubectl / helm 在"外面"操作集群）→ `control-node`。

`minimal` 默认 `ssh-only`，`multi-vm` 默认 `control-node`。

### 15.3 五条核心原则

1. **平台差异只允许出现在两个地方**：`core/platform/` 与 `.gitattributes`。`scripts/`、`docs/`、章节正文里出现 `if windows` 判分支，等同于违反 A1。
2. **宿主只管机器，控制机只管命令**。Windows 宿主的职责只有三件：装 box、`vagrant up`、`vagrant ssh`。课程命令一律在 Linux 里执行，这样文档只需要一套命令。
3. **差异收敛到副本**。控制机不在 `/vagrant` 共享目录里工作：vboxsf 挂载点是 0777，Ansible 会拒绝加载 `ansible.cfg`，私钥也没法 `chmod 600`。所以第一步就 `rsync -rlt` 到 `$HOME/<course>`，之后一切在副本里。
4. **共享目录只做传输，不做工作目录**。`/vagrant` 只有两个用途：把仓库送进 VM、把宿主的私钥取出来。向它写入一律视为 bug。
5. **事实源不复制两份**。Windows 需要多一台 `ops`、内存也要下调，但这些差异必须**生成**（§15.11），不能手抄一份 `nodes.windows.yml` 天天漂移——第一课在这里留了隐患。

### 15.4 `core/platform/` 结构

```
core/platform/
├── README.md                  # 平台矩阵 + 支持边界（写清"什么没验证"）
├── vm/                        # 镜像与干净起点（与桌面平台正交，见 §16）
│   ├── boxes.yml              # bento 允许清单（家族/包管理/防火墙/SELinux，不存版本）
│   ├── probe.sh               # 记录实际镜像版本（宿主执行，写 logs/vm-probe.txt）
│   └── baseline.sh            # VM 内断言 assert_absent + 记录 os-release / 内核
├── linux/
│   └── check.sh               # VirtualBox / vboxdrv / vboxusers / 网段 / 内存
└── windows/
    ├── check.ps1              # 管理员 / PS 版本 / Hyper-V / ssh / 路径 / 网段 / 内存
    ├── up.ps1                 # 前置检查 → 自提权 → vagrant up → 引导控制机
    ├── down.ps1
    ├── destroy.ps1
    ├── emit.ps1               # UTF-8 无 BOM 写入工具函数（被上面四个 dot-source）
    ├── gen-nodes.py           # 事实源 + control_node → nodes.windows.yml
    ├── provision-control.sh   # 控制机引导 7 步（仅 control-node）
    └── guest/bin/<tool>       # 宿主专属命令的 shim（仅 control-node）
```

原则：**平台层不含任何课程知识**。它只认 `course.yml` 里的字段（`facts.source`、`tools[].where`、`platforms.*`），不知道 k3s 是什么。

### 15.5 `course.yml` 的 `platforms` 块

```yaml
platforms:
  vm:
    provider: virtualbox         # C13：固定值，不允许改成别的
    default_box: "bento/ubuntu-24.04"   # C15：只允许 bento 系（§16）
    arch: amd64
    assert_absent: []            # 默认空；课程按需声明，如 [docker, nginx]（§16.5）
  windows:
    mode: control-node           # ssh-only | control-node
    min_ps: "5.1"                # 学员机器默认只有 5.1
    control_node:
      name: ops
      cpus: 1
      memory: 1024
      path:                      # 写进 ~/.bashrc 与 /etc/profile.d/ 两份
        - "$HOME/.local/bin"
        - "$HOME/.venv/<course>/bin"
      env:
        - "ANSIBLE_CONFIG=$HOME/<course>/ansible/ansible.cfg"
        - "KUBECONFIG=$HOME/<course>/kubeconfig"
  linux:
    require_vboxusers: true
    kernel_module: vboxdrv
    admin_needed: false          # 与 Windows 相反，文档要写明
```

`tools` 增加一个 `where` 字段，让"缺什么装什么"在两个平台都成立：

```yaml
tools:
  - name: python3
    where: both                  # 宿主与控制机都查
  - name: vagrant
    where: host                  # 只有宿主需要
  - name: ansible
    where: control               # 只装在控制机
```

`check-prereqs.sh` 按 `where` 与当前平台过滤：Linux 桌面查 `host` + `both`，控制机里查 `control` + `both`。默认值 `both`（不写不漏）。

`vm` 块里的镜像字段（`default_box` / `arch` / `assert_absent`）与桌面平台**正交**：
Linux 桌面和 Windows 桌面跑的是同一批 box，差异只在"谁去启动它们"（§16.2）。

### 15.6 生成器按字段裁剪

| 产物 | `ssh-only` | `control-node` |
|---|---|---|
| `platform/vm/{boxes.yml,probe.sh,baseline.sh}` | ✓ | ✓ |
| `platform/windows/check.ps1`、`up/down/destroy.ps1`、`emit.ps1` | ✓ | ✓ |
| `platform/windows/provision-control.sh` | ✗ | ✓ |
| `platform/windows/guest/bin/*`（shim） | ✗ | ✓ |
| `platform/windows/gen-nodes.py` + `nodes.windows.yml` | 仅在拓扑需覆盖时 | ✓ |
| README 的 Windows 段 | "2 步" | "2 步，其中第 2 步等控制机" |
| `AGENTS.md` 契约的平台段 | 一句 | 完整段 |

生成物里**没有**什么比有什么更能说明问题：`ssh-only` 里出现 `provision-control.sh` 就是生成器 bug，`test-generate.sh --mode` 会断言这一点。

### 15.7 Linux 桌面：检查项与真实失败模式

`platform/linux/check.sh` 只提示，`--strict` 才改退出码：

| 检查 | 命令 | 失败时给什么 |
|---|---|---|
| VirtualBox ≥ 7.0 | `VBoxManage --version` | Oracle 官方仓库的安装命令（发行版自带的太旧） |
| `vboxdrv` 已加载 | `lsmod` 里出现 `vboxdrv` | `sudo modprobe vboxdrv`；Secure Boot 需注册 MOK；内核升级后 `sudo /sbin/vboxconfig` |
| 用户在 `vboxusers` | `id -nG` 含 `vboxusers` | `sudo usermod -aG vboxusers "$USER"`，然后**重新登录** |
| Vagrant ≥ 2.4 | `vagrant --version` | HashiCorp 仓库地址（发行版包通常是 2.2） |
| 网段未被占用 | `ip -4 addr` 匹配 subnet | 提示改事实源里的 subnet |
| 内存 ≥ 拓扑总和 + 2GB | `free -g` | 提示下调节点内存 |

Linux 侧**不需要管理员权限**（进 `vboxusers` 组即可），与 Windows 正好相反。文档要写明，否则学员会习惯性 `sudo` 一切，把文件所有者搞乱。

### 15.8 Windows 桌面：真正会拦住人的七件事

这一节才是"支持 Windows"的实质内容，每一条都在第一课踩过。

| # | 问题 | 机制 |
|---|---|---|
| 1 | PowerShell 版本 | 只用 **5.1** 有的语法：不用 `??`、`?.`、`-Parallel`、`ConvertFrom-Json -AsHashtable`。`check.ps1` 读 `$PSVersionTable.PSVersion`，过低直接报错 |
| 2 | 管理员权限 | host-only 网卡必须管理员。`up.ps1` 先 `Test-Admin`，不是就 `Start-Process -Verb RunAs` 自提权，父进程 `exit 0`（否则会执行两遍） |
| 3 | Hyper-V / WSL2 | `HypervisorPresent` 为真时**阻断**，给 `bcdedit /set hypervisorlaunchtype off` + 重启的指引。不是警告——放行只会得到"`vagrant up` 卡在 0%" |
| 4 | 默认编码 | PS 5.1 的 `Set-Content` / `Out-File` 默认 UTF-16LE 且带 BOM，写出的 YAML 与 kubeconfig 立刻报废。统一走 `emit.ps1`：`[IO.File]::WriteAllText($p, $s, (New-Object Text.UTF8Encoding $false))` |
| 5 | 中文乱码 | 启动时 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`；脚本输出不带 emoji（GBK 控制台会炸） |
| 6 | 没有 `ssh` | `vagrant ssh` 依赖系统 OpenSSH 客户端。`check.ps1` 查 `Get-Command ssh`，缺失时给"设置 → 应用 → 可选功能"的路径 |
| 7 | 路径含空格或中文 | Vagrantfile 与 Ansible 的引号会出问题。`check.ps1` 检测仓库根路径，含空格则建议换到 `C:\work\<course>` |

第 4 条单列的原因：第一课排查最久的就是它。生成的 kubeconfig 前面多两个字节，`kubectl` 报 `error loading config file: yaml: invalid trailing UTF-8 octet`，看起来像网络问题，实际是编码问题。

### 15.9 换行与编码：`.gitattributes` 是生死线

没有 `.gitattributes` 时，Windows 上 `git clone` 会把 `core.autocrlf=true`（Git for Windows 默认）套到所有文本文件，`*.sh` 变成 CRLF。表现出来是：

```
bash: ./scripts/gate.sh: /usr/bin/env: bad interpreter: No such file or directory
```

或者 `bash: '\r': command not found`。这类错误学员极难自查，所以必须在仓库里钉死：

```gitattributes
* text=auto eol=lf

*.sh        text eol=lf
*.py        text eol=lf
*.yml       text eol=lf
*.yaml      text eol=lf
*.j2        text eol=lf
Vagrantfile text eol=lf
*.md        text eol=lf

*.ps1       text eol=crlf
*.psm1      text eol=crlf
*.bat       text eol=crlf
*.cmd       text eol=crlf

*.png binary
*.jpg binary
```

两道校验进 `gate.sh`（都属于"文件卫生"，放在 docs 门禁里跑）：

| 检查 | 断言 | 为什么必需 |
|---|---|---|
| BOM | 任何被跟踪的文本文件首三字节不是 `EF BB BF` | BOM 让 shebang 失效，让 YAML 首键名带上 `\ufeff` |
| 索引换行 | `git ls-files --eol`：`*.sh/*.py/*.yml` 的 index 为 `lf`，`*.ps1` 为 `crlf` | 有人在 Windows 上改完直接提交时，`.gitattributes` 不一定救得回来 |

`git ls-files --eol` 报的是**索引**状态，所以本地与 CI 都成立；这也是唯一能自动发现"某文件被 CRLF 污染"的办法。

### 15.10 控制机引导：7 步，幂等

`platform/windows/provision-control.sh`（仅 `control-node`）。由 `up.ps1` 通过 `vagrant ssh` 调用，也可手动重跑。

| 步 | 做什么 | 幂等判据 |
|---|---|---|
| 1 | 基线包（`python3-venv`、`rsync`、`curl`、`openssh-client`） | `dpkg -s` |
| 2 | 仓库副本 `rsync -rlt` 到 `$HOME/<course>` | 每次重跑（用 `-rlt` 而非 `-a`：vboxsf 不支持改属主） |
| 3 | 注入平台拓扑（`gen-nodes.py` 的产物覆盖副本里的事实源） | 每次重跑 |
| 4 | 私钥 `.vagrant/machines/<host>/virtualbox/private_key` → `~/.ssh/<course>/<host>`，`chmod 600` | 存在则跳过 |
| 5 | 派生事实（inventory、shim 映射），由 `facts.derived` 声明 | 内容比对 |
| 6 | `tools` 里 `where: control` 的安装（Ansible、kubectl、helm…） | 每项自带 `check` 命令 |
| 7 | 控制机环境变量（`~/.bashrc` **与** `/etc/profile.d/` 各一份）+ shim 安装 | 内容比对 |

第 7 步写两份不是冗余：`vagrant ssh -c` 与 `ssh host cmd` 都是**非交互 shell**，不读 `~/.bashrc`。第一课只写了 `.bashrc`，结果 `up.ps1 -Install` 的第二条命令找不到 `ansible-playbook`。

**Ansible 版本必须钉**：控制机默认是 Ubuntu 24.04（Python 3.12）。`ansible-core` 从 2.22
起要求 Python ≥3.13，3.12 上装不上；所以写 `ansible-core>=2.18,<2.22`，
不要裸写 `ansible-core`。第一课的控制机是 22.04（Python 3.10），当时必须 `<2.18`——
这条上限是跟着控制机 Python 版本走的，不是固定值。

### 15.11 拓扑不复制两份

第一课的 `win/nodes.windows.yml` 是手抄的（多了 `ops` 节点、agent 内存 4096→2048），与 `vagrant/nodes.yml` 靠注释"保持一致"。**这是缺陷，不能带进模板。**

模板做法是单向往生成：

```
facts.source（course.yml 指定）
      │  gen-nodes.py（事实源 + platforms.windows.control_node）
      ▼
platform/windows/nodes.windows.yml    （生成物，入库，只读，头注释写 generated / do not edit）
```

- 生成时写一次；
- `gate.sh parity` 用同样输入重新生成，**diff 非空即失败**，提示跑 `scripts/gen-platform.sh`；
- 作者与学员都不手改这个文件。

这样"加一个 agent 节点"只改事实源一处，Windows 侧不会漏——顺带把第一课"两份拓扑各自演进"的隐患消掉。

### 15.12 `vagrant` shim 的边界

控制机里没有 Vagrant（也不该有，H4），但课程脚本会调 `vagrant ssh` / `vagrant up`，所以控制机要装一个 `vagrant` shim。

泛化后的契约——shim **只实现查询与连接，一律拒绝造机器与销毁**：

| 调用 | shim 行为 |
|---|---|
| `vagrant ssh <node> [-- cmd]` | `exec ssh`：TTY、stdin 管道、退出码原样透传 |
| `vagrant ssh -c <cmd>` | 同上 |
| `vagrant ssh-config <node>` | 打印等价 SSH 配置 |
| `vagrant up` / `halt` / `suspend` / `destroy` / `status` | 打印"回 Windows 执行"的指引，**退出码 2** |
| 其他 | 退出码 2 |

两个实现细节是踩出来的：

- **`-t` 只在交互时加**。`vagrant ssh node -- "sudo bash -s" < file` 是管道，加了 `-t` 会让 `sudo` 等 TTY 而挂死。
- **用 `os.execvp` 而不是 `subprocess`**。否则 stdin 管道与信号转发不可靠，`status` 里的 `sudo bash -s` 会读到空输入。

shim 只读 `~/.<course>-shim.json`（第 5 步生成），不解析 Vagrantfile——那是宿主的事。

### 15.13 文档怎么写：一套命令，两种桌面

这是"两种桌面都能正常操作"落到文字上的部分。规则四条：

1. **命令只有一套**，全是 Linux 命令。不写"Windows 用 `dir`、Linux 用 `ls`"这种对照表。
2. **平台差异只出现在"入口"**，放在每章统一位置（`docs/conventions.md` 规定格式）。
3. **对外访问地址只写"宿主可达"的那一个**（端口转发端口，从拓扑的 `port_forwards` 派生），不写"Linux 用 30443、Windows 用 8443"。
4. **正文不出现 Windows 路径**（`C:\...`）。`check-docs.py` 命中即提示——正文出现反斜杠路径，说明作者开始写平台分支了。

"入口"块的标准形态：

```markdown
> **入口（只做一次）**
> - Linux 桌面：`./platform/linux/check.sh && ./scripts/gate.sh all`
> - Windows 桌面：`powershell -ExecutionPolicy Bypass -File .\platform\windows\up.ps1 -Install`
>
> 之后的命令两种桌面**完全相同**，都在 Linux 里执行。
```

### 15.14 验证矩阵：哪些能验，哪些只能承认

延续 §14 的口径，把"能验"与"只能承认"分开摆：

| 项 | Linux 上可验证 | 只能 Windows 实机 | 状态 |
|---|---|---|---|
| `.gitattributes` 覆盖 + BOM + 索引换行 | ✓（`git ls-files --eol`） | — | P1 进 `gate.sh` |
| 生成器三档裁剪 | ✓（`test-generate.sh --mode`） | — | P2 / P3 |
| `platform/linux/check.sh` | ✓ | — | P2 |
| PS 静态合规（无 `??`、无 `Set-Content`、无 BOM） | ✓（`test-platform-parity.sh`） | — | P3 |
| `up.ps1` 全流程（自提权、host-only 网卡、`vagrant up`） | ✗ | ✓ | **未验证** |
| shim 的 TTY / stdin / 退出码透传 | 部分（在 Linux 里直接跑 shim） | ✓（真实 `vagrant ssh -c`） | 部分 |
| Windows 宿主访问 NodePort | ✗ | ✓ | **未验证** |
| PS 5.1 的真实编码行为 | ✗（Linux 只有 pwsh 7） | ✓ | **未验证** |

Linux runner 上若装了 `pwsh`，额外做 `[ScriptBlock]::Create()` 语法解析；没装就**标注 skipped —— skipped 不等于 passed**。

"未验证"三格必须写进生成物 `CHANGELOG.md` 的 Unreleased 区，格式固定：

```
- [未验证] Windows 桌面全流程：设计见模板仓库 docs/design.md §15，待 Windows 实机确认
```

这是第一课"诚实边界"的复用：**没跑过就说没跑过，不能因为"逻辑上应该行"就勾掉。**

### 15.15 反目标

| # | 反目标 | 为什么是失败 |
|---|---|---|
| P1 | 给 Windows 写一套 PowerShell 版课程命令 | 两份真相互相腐化，最终只有一份是新的 |
| P2 | 走 WSL2 省掉第三台机器 | 与 VirtualBox 互斥（H3），学员卡在"虚拟机打不开" |
| P3 | 在 VM 里跑 Vagrant | 无嵌套 VT-x（H4），报错信息还看不懂 |
| P4 | 平台差异散布在 `scripts/` 里 | 等价于 A1，第三个平台进来时无处下刀 |
| P5 | 控制机直接工作于 `/vagrant` | 0777 挂载 → Ansible 拒绝加载配置、私钥无法 600，症状叫"权限错误"而不是"共享目录" |
| P6 | 只支持 Linux，文档加一句"Windows 请自行解决" | 等于没做 C12–C14 |

---

## 16. 虚拟机镜像与多系统

### 16.1 决定：默认 Ubuntu，多系统只换镜像

先分清两件事：

- **教学默认**：Docker、CI/CD、Terraform、k8s、监控——这些课在 Ubuntu 上跑完全够，
  换发行版只是在给学员增加无关变量。
- **教学内容**：只有"服务器 OS 运维"这类课，包管理、防火墙、SELinux 的**差异本身**
  才是要讲的，这时才需要同屏两个系（如 Debian + Rocky）。

所以模板给的是"一个默认镜像 + 允许按节点覆盖"，不是"支持任意发行版"：

| 决定 | 值 | 理由 |
|---|---|---|
| 默认镜像 | `bento/ubuntu-24.04` | LTS，标准支持到 2029-04，覆盖整个系列；Python 3.12 也让 Ansible 的版本上限能放宽一档（§15.10） |
| 覆盖粒度 | 按**节点**覆盖，不按课程 | 多系统课是"两台机器不同"，不是"整门课换系统" |
| 镜像来源 | 只用 bento 系现成 box | 都带 VirtualBox + amd64、都是 minimal 基线、都预装 Guest Additions |
| 架构 | `amd64` 固定 | Apple Silicon 的 arm64 要另一套验收，不在支持面（§16.6） |
| 版本 | **不钉** | 理由见 §16.6，配套做法是记录实测版本而不是约束版本 |

**换默认值的代价，要写在明面上**：第一课的实测结论（Ansible 版本、包名、
systemd 行为）是在 **22.04** 上得到的。模板默认改为 24.04 之后：

- `22.04` 仍留在允许清单里，需要精确对齐第一课的老课程可以按节点写 `box: bento/ubuntu-22.04`；
- `multi-vm` 剖面第一次真机跑必须在 **24.04** 上复核，不能把第一课的结论直接搬过来；
- 复核前，它和 §15.14 的 Windows 项一样属于"未验证"——**没跑过就说没跑过**。

**为什么不"支持所有 box"**：每多支持一类镜像，就多一组"默认用户 / Guest Additions 版本 /
网络配置方式 / 是否 systemd"的差异要验。bento 恰好把这些抹平了，边界最省。

### 16.2 两个字段：`default_box` 与节点 `box`

课程级默认写在 `course.yml`：

```yaml
platforms:
  vm:
    provider: virtualbox            # C13：固定值
    default_box: "bento/ubuntu-24.04"
    arch: amd64
    assert_absent: []               # 默认空，模板不主张镜像里装了什么（§16.5）
```

节点级覆盖写在事实源（如 `vagrant/nodes.yml`）。`role` 只是课程自己用的标签，
没有预置取值：

```yaml
nodes:
  - name: app-1
    role: app                      # 标签由课程定义，这里仅作示例
    ip: 192.168.56.10
    box: bento/ubuntu-24.04        # 与默认值相同，可省略
  - name: db-1
    role: db
    ip: 192.168.56.11
    box: bento/rockylinux-9        # 覆盖默认值：跨系演示
```

三条规则：

1. **省略即继承**。节点不写 `box` 就用 `default_box`。Vagrantfile 里是
   `box = node.get('box') or vm_cfg['default_box']`——这也顺手修掉第一课
   `config.vm.box = network_cfg['box']` 的"整机共用一个 box"限制。
2. **`box` 只影响镜像**。命令、目录、门禁、章节格式与镜像无关；
   换了镜像而课程命令一个字没变，说明这台机器只是换了底座。
3. **`gate.sh boxes` 校验名字**。允许清单在 `core/platform/vm/boxes.yml`，
   命中不了就报错并给最近候选。这是最容易记错的一类名字：`bento/rocky-9` 不存在
   （现役是 `bento/rockylinux-9`），`bento/oracle-9` 2024-01 起停更
   （现役是 `bento/oraclelinux-9`）——本次设计查证时就先写错了前一个。

**家族不靠猜**：`boxes.yml` 给每个 box 标 `family`（`debian` / `rhel` / `suse` / `other`），
`check-boxes.sh` 读这张表统计。不解析 `/etc/os-release`——那是运行期的事，
而门禁要在没有 VM 的时候也能跑（CI 上没有 VirtualBox）。

### 16.3 bento 现役清单

下表是 2026-11-03 用 Vagrant Cloud API 逐个确认过 `virtualbox` provider 与 `amd64`
架构存在的现役 box。**清单只存稳定属性，不存版本号**（版本会变，见 §16.6）：

| 家族 | 现役 box | 包管理 | 防火墙 | SELinux | 用途 |
|---|---|---|---|---|---|
| Debian 系 | `bento/ubuntu-22.04`、`-24.04`、`-26.04` | apt | ufw | 无 | **默认取 24.04**；22.04 用于对齐第一课，26.04 尚未实测 |
| Debian 系 | `bento/debian-11`、`-12`、`-13` | apt | ufw | 无 | 与 Ubuntu 对比 apt 版本与默认包差异 |
| RHEL 系 | `bento/rockylinux-8`、`-9`、`-10` | dnf | firewalld | enforcing | 多系统课的 RHEL 代表（**首选**） |
| RHEL 系 | `bento/almalinux-8`、`-9`、`-10` | dnf | firewalld | enforcing | 同族的替代品牌 |
| RHEL 系 | `bento/oraclelinux-9`、`-10` | dnf | firewalld | enforcing | 只在课程真讲 Oracle 时用 |
| RHEL 系 | `bento/centos-stream-9` | dnf | firewalld | enforcing | 只在讲 Stream 定位时用 |
| RHEL 系 | `bento/fedora-latest` | dnf | firewalld | enforcing | 跟最新内核与工具链，不做稳定基线 |
| SUSE 系 | `bento/opensuse-leap-15` | zypper | firewalld | 可选（以 AppArmor 为主） | 只在一门课真讲到 SUSE 时启用 |
| 独立 | `bento/amazonlinux-2023` | dnf | firewalld | enforcing | 需要与云上环境对齐时用 |
| 不支持 | `bento/freebsd-13`、`-14` | pkg | pf | 无 | 无 systemd，Ansible 与 k3s 的假设全不成立 |

`centos-stream-9` 之后没有 `-10`：bento 只发到 Stream 9（`bento/centos-stream-8` 还在，
但已不是现役）。Ubuntu 不列 `25.04`：它是过渡版本，支持期只有 9 个月，不适合做课程基线。

### 16.4 真正会绊倒人的只有三处

多系统课容易写成"每条命令都写两遍"，实际 90% 内容是一样的。真正不同的只有三块：

| # | 差异 | Debian 系 | RHEL 系 | 不处理的后果 |
|---|---|---|---|---|
| 1 | 装包 | `apt-get install -y` | `dnf install -y`（部分包要先 `dnf install -y epel-release`） | 第一章第一条命令就失败 |
| 2 | 防火墙 | `ufw`（bento 上默认 inactive） | `firewalld`（**默认 active**） | k3s 的 6443 / 10250 / 8472 / 2379-2380 被挡，表现为"节点一直 NotReady"或 join 超时 |
| 3 | SELinux | 无 | `enforcing` | k3s 挂载与容器卷失败，报错指向权限，实际是 LSM |

模板对这三块的态度：

- **不替课程解决**。写 `firewalld` 放行规则是**课程内容**（它正是这门课要教的），
  模板不预置"通用防火墙角色"——那就是 §2.3 的 A1。
- **模板只保证"起得来、连得上、装得上同一套工具"**：两个家族的 VM 用同一份
  `platform/vm/baseline.sh` 断言干净，用同一套 `platform/linux/check.sh` 检查宿主。
- **跨系课程的命令块必须标注执行节点**（写进 `conventions.md`）：单系课程不要求，
  跨系课程强制，否则读者不知道这条命令该在哪台机器上敲。`gate.sh boxes` 在检测到
  ≥ 2 个家族时提示这一点——提示，不改退出码。

### 16.5 干净起点：`assert_absent` 与镜像探测

"最小安装"在模板里的定义只有一个：**bento 的 minimal 基线 + 课程声明的缺席断言**。
不做 ISO 手工安装，也不自制 box（§16.6）。

`core/platform/vm/baseline.sh` 在 **VM 内**执行（由课程第一条 provision 或
`verify.infra` 调用）：

| 检查 | 命令 | 失败含义 |
|---|---|---|
| 缺席断言 | `command -v <name>` 必须非 0 | box 不是最小安装，或上次实验没清理干净 |
| 发行版 | `cat /etc/os-release` 的 `PRETTY_NAME` | 记录家族，供文档核对 |
| 内核 | `uname -r` | 与记录在案的 box 版本对得上 |

默认**失败**（退出码 1），加 `--warn` 才降级为警告。理由很直接：预装了 `nginx`
的镜像会让"从零安装 nginx"那一章从第一条命令起就是错的，而这种错误看起来像
"配置没问题但行为不对"，最难查。

`assert_absent` 的**默认值是 `[]`**：模板不知道你的课要教什么，也就不替你主张
镜像里该没有什么。由课程作者在 `course.yml` 里声明——Docker 课写 `[docker]`，
nginx 章节课写 `[nginx]`。列表为空时 `baseline.sh` 只记录发行版与内核，不做缺席断言。

镜像**实际版本**的落盘分两处：

| 位置 | 内容 | 谁写 |
|---|---|---|
| `logs/vm-probe.txt` | `vagrant box list` 的对应行 + 每个 VM 的 `os-release` 首行 | `core/platform/vm/probe.sh`（宿主执行，走 `vagrant ssh`） |
| `docs/architecture.md` 的"运行环境"表 | **一次真实样例** + 日期 + "版本会变"标注 | 作者手工抄一次 |

第一处是运行时证据（`logs/` 在 `.gitignore` 里，不占仓库）；第二处是给人看的，
允许过时——这正是"不钉版本"的配套（§16.6）。

### 16.6 不钉版本，以及明确不支持的东西

**不钉 box 版本**（这是对早前"钉版本"主张的收回）：

- bento 按需重发，版本号就是构建日期（如 `202512.01.0`）。钉死意味着新学员要额外
  下载几个 GB 的旧镜像，而且旧版本的下载不一定还在列表前面；
- 钉版本解决的是"半年后行为漂移"，但模板的寿命以**门禁与规范**计，不以**镜像字节**计；
- 配套做法是**记录实测版本**（§16.5 的第二处落盘），不是**约束版本**。

出问题时回退，不需要新字段：

```bash
vagrant box add bento/ubuntu-24.04 --box-version 202510.26.0
```

本地只留这一个版本，Vagrant 就会用它——**回退是操作，不是配置**。

明确不支持：

| 项 | 为什么不支持 |
|---|---|
| 非 bento 镜像（官方 cloud image、第三方、自制） | 默认用户、Guest Additions、网络配置各不相同，等于为每个镜像写一套适配 |
| ISO 手工最小安装 | 学员卡在分区与引导的概率远高于收益；"最小"已由 bento + `assert_absent` 覆盖 |
| arm64（Apple Silicon） | 需要另一套验收矩阵，且 Windows 控制机方案本身是 amd64 假设 |
| FreeBSD / Windows guest | 无 systemd，Ansible 与 k3s 的假设全不成立 |
| 混用 provider（VMware / Parallels / libvirt） | C13 已把平台钉在 VirtualBox；多 provider 等于多一份平台层 |

---

## 17. 独立评审的 8 个问题与处置

评审以"要照这份文档做计划的人"视角读了一遍，提出 8 个会逼出昂贵猜测的缺口。
处置如下（前 7 条已写进上文，第 8 条收窄为显式开关）。

| # | 问题 | 处置 | 落在哪 |
|---|---|---|---|
| 1 | 只用 stdlib 怎么解析 YAML？ | 不自己造。**PyYAML 作为 `required: true` 工具显式声明**，与第一课一致；`reason` 因此必须是字段而非注释 | §2.2、§4.4 |
| 2 | `verify` 指向课程还不存在的脚本？ | 拆成 `verify.self`（开箱可跑）与 `verify.infra`（需真机，作者填）。生成即绿，但"未验证"不被伪装成"已验证" | §4.4、§8 |
| 3 | 剖面预置的 IP 怎么过隐私门禁？ | 白名单**从 `facts.source` 派生**（`privacy.derive`），提取器固定在 core，剖面仍只有数据 | §4.4、§5.2、§9.2 |
| 4 | 反例夹具会触发自己的门禁？ | 夹具**运行时建在临时目录**，`privacy-check.sh --root` 指向它。仓库里零违规内容，也不需要任何豁免 | §5.2 |
| 5 | `decisions.md` 一写就永久冲突？ | 文件分三类：`managed` / `managed-region` / `seed-only`。`decisions.md` 是 seed-only | §7.2 |
| 6 | "CI 绿"到底要不要真跑？ | **已定：A（文件级）**，并明确标注"CI 尚未真跑过" | §14 |
| 7 | 技能怎么"检测已安装"？ | 收窄为**只提示、永不改退出码** | §5.4 |
| 8 | `--require-sections` 会误伤 README？ | 章节检查只作用于 `chapters.dir`；严格度由 `strict_sections` 显式开启 | §5.3、§8 |

补充一行，避免读者误以为 §15 与 §16 也过了这轮评审：

| # | 情况 | 处置 |
|---|---|---|
| 9 | §15 跨平台设计、§16 镜像与多系统**未经过独立评审** | §15 素材来自第一课已实施并验证的 Windows 方案（`docs/windows-ops-vm-design.md` + `win/`），不是新发明；§16 的 box 清单是查 Vagrant Cloud API 实测的，不是记忆。但"泛化到模板"这一步只有本文档一次书面梳理，实施时按 P2/P3 的验收项逐步兜底（§15.14、§16.5） |

评审没有提、我也认为不值得展开的：`sed` vs jinja、`.course/` 命名、许可证、
文档语言、章节空壳粒度。这些实施时随手定，改起来便宜。
