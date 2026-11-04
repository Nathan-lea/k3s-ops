# devops-self-study-base（P0–P2）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建成 `devops-self-study-base` 的 P0–P2：能用 `new-course.sh` 生成一个 `minimal` 课程仓库，生成物自带五道门禁能力且开箱全绿。

**Architecture:** 模板仓库自身是 bash 薄壳 + Python 3 标准库（+ PyYAML）。`core/` 逐字（或渲染后）拷进生成物，`profiles/` 只提供数据，`lib/` 是模板仓库私有的生成器实现、**不进生成物**。门禁统一由 `scripts/gate.sh` 分发，每个门禁有自己的正反例自测。

**Tech Stack:** bash（入口/胶水）、Python 3.8+ 标准库 + PyYAML（解析/校验/渲染/扫描）、Git 2.30+。

**Spec:** 本仓库 `docs/devops-self-study-base-design.md`（§4.2 结构、§4.4 契约、§5 门禁、§6 红线、§7 同步、§10 测试、§11 阶段、§14 CI、§15 跨平台、§16 镜像）

**Working directory:** 与 `k3s-ops` 同级的新目录 `devops-self-study-base`（Task 1 创建；下文用 `$BASE` 指它）。计划文件本身留在 `k3s-ops`，不随仓库。

## Global Constraints

- 仓库名、远端名、`.course/template-version` 的 `template` 字段一律为 `devops-self-study-base`。
- `profiles/` 下**不允许出现任何 `*.sh` / `*.py`**；剖面只有数据。
- `core/` 与 `platform/` **不读** `course.yml` 的 `profile` 字段，不出现按剖面分支的逻辑（A1）。
- 默认值：`platforms.vm.provider: virtualbox`、`default_box: bento/ubuntu-24.04`、`arch: amd64`、`assert_absent: []`、`tools[].where: both`、`chapters.dir: docs/chapters`、`chapters.strict_sections: false`。
- 剖面白名单只有 `minimal`、`multi-vm`；P2 只交付 `minimal`，`multi-vm` 在 `new-course.sh` 里明确报"P3 尚未实现"并退出码 2。
- 依赖下限：git ≥ 2.30、python3 ≥ 3.8、pyyaml ≥ 5.4（`course.yml` 里 `required: true`）。
- 平台：Linux 桌面（宿主即控制机，无需 sudo）、Windows 桌面（PS 5.1，仅 `ssh-only` 档）。Windows 实机行为**一律标"未验证"**。
- 行为：不主动 `git push`；不删除已存在文件；不写课程正文（章节只生成八段标题空壳）；不伪装"已验证"。
- 生成器对**非空目标目录必须零写入**后退出码 1。
- CI 验收口径 A（文件级）：workflow 存在且本地静态校验通过，README 与 `definition-of-done.md` 必须写明"CI 尚未真跑过"。

## Review Focus

1. 目标目录非空（含隐藏文件、`.git`）→ 必须拒绝且**一个字节都不写**；对应测试在 Task 3。
2. 课程名/标题含空格、中文、`$`、`{{`、引号 → 路径与生成的 YAML 必须仍然合法；对应测试在 Task 2、Task 11。
3. `course.yml` 缺省字段（`assert_absent`、`tools[].where`、`verify.infra`、`skills`）→ 默认值生效，不抛 KeyError；对应测试在 Task 2。
4. 仓库里出现 BOM 或 CRLF 的 `*.sh`/`*.yml` → 门禁必须报出**具体文件路径**且退出码 1；对应测试在 Task 5。
5. profile 目录缺 `course.yml` 或含未知顶层文件 → 生成器报错退出，不静默跳过；对应测试在 Task 2、Task 3。

---

## Task 1: 初始化仓库与静态契约文件

**Files:**
- Create: `README.md`
- Create: `LICENSE`（MIT，年份 2026）
- Create: `VERSION`（内容 `0.1.0`）
- Create: `CHANGELOG.md`
- Create: `.gitattributes`
- Create: `.gitignore`
- Create: `core/.githooks/pre-push`（可执行，P1 前是 `exit 0` 占位）
- Create: `.gitignore` 之外的空目录占位不建；目录由后续任务创建

**Interfaces:**
- Consumes: 无
- Produces: 仓库根目录与 `main` 分支；`.gitattributes` 的换行规则（Task 5 校验它）；`core/.githooks/pre-push` 路径（Task 4 填充内容）。

- [ ] **Step 1: 建目录并写静态文件**

`README.md` 只写四条：这是什么、三条命令、支持边界、CI 口径。

```markdown
# devops-self-study-base

「DevOps 自学系列」的课程基座：克隆后一条命令生成新的独立课程仓库。

## 三条命令

    git clone <this-repo> devops-self-study-base
    cd devops-self-study-base
    ./new-course.sh ../my-course --profile minimal --name my-course --title "我的课程"

## 支持边界

- 虚拟机平台固定 VirtualBox ≥ 7.0，镜像只用 bento 系，arch 固定 amd64。
- 学员桌面：Linux（宿主即控制机）与 Windows（PS 5.1，`ssh-only` / `control-node` 两档）。
- Windows 实机行为目前**未验证**，见 `core/platform/README.md`。

## CI 口径

workflow 文件已随仓库提供，但**CI 尚未真跑过**（无远程、无 runner）。验收口径是
"文件存在 + 本地静态校验通过"，不包含真实的绿。
```

`.gitattributes` 逐行照抄 Spec §15.9 的代码块（`* text=auto eol=lf` 起，到 `*.jpg binary` 止）。

`.gitignore`：

```gitignore
logs/
*.log
__pycache__/
*.pyc
.venv/
.DS_Store
```

`CHANGELOG.md`：Keep a Changelog 格式，`## [Unreleased]` 下先写三条：

```markdown
- 新增：仓库骨架与静态契约文件
- [未验证] Windows 桌面全流程（见 core/platform/README.md）
- [未验证] CI 真实执行（口径 A：仅文件级验收）
```

- [ ] **Step 2: 初始化 git 与钩子路径**

```bash
cd ../devops-self-study-base     # 从 k3s-ops 出发；即 $BASE
git init -b main
git config core.hooksPath core/.githooks
chmod +x core/.githooks/pre-push
```

- [ ] **Step 3: 验证文件与换行**

Run:

```bash
git add -A && git ls-files --eol | grep -v 'i/lf' ; bash -n core/.githooks/pre-push
```

Expected: 无输出（所有文本文件索引为 `lf`），`bash -n` 退出码 0。

- [ ] **Step 4: 提交**

```bash
git commit -m "chore: 初始化仓库骨架与静态契约文件"
```

---

## Task 2: 契约解析与默认值（`lib/course_schema.py`）

**Files:**
- Create: `lib/course_schema.py`
- Test: `tests/unit/test_course_schema.py`

**Interfaces:**
- Consumes: 无
- Produces（后续任务按此签名调用）:
  - `class ContractError(Exception)`
  - `load_yaml(path: Path) -> dict`
  - `load_profile(profile_dir: Path) -> dict`：读 `<profile_dir>/course.yml`，缺文件抛 `ContractError`
  - `with_defaults(course: dict) -> dict`：补 `tools[].where="both"`、`chapters.dir="docs/chapters"`、`chapters.strict_sections=False`、`platforms.vm.assert_absent=[]`、`verify.infra=""`、`skills={}`
  - `validate(course: dict, *, source: str = "course.yml") -> None`：错误消息格式 `"<source>: <字段路径>: <原因>"`
  - `build_course(profile: dict, *, name: str, title: str, series: str = "devops-self-study", mode: str | None = None) -> dict`
  - `dump_course(course: dict) -> str`：UTF-8、两空格缩进、键顺序稳定（按契约顺序输出）

- [ ] **Step 1: 写失败测试**

`tests/unit/test_course_schema.py`（标准库 `unittest`，不引入 pytest）：

```python
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from lib.course_schema import ContractError, build_course, dump_course, validate, with_defaults

MINIMAL = {
    "course": {"name": "demo", "title": "演示", "series": "devops-self-study"},
    "profile": "minimal",
    "tools": [{"name": "git", "min_version": "2.30", "check": "git --version",
               "install": "apt-get install -y git", "required": True}],
    "platforms": {"vm": {"provider": "virtualbox", "default_box": "bento/ubuntu-24.04", "arch": "amd64"}},
    "facts": {"source": "docs/architecture.md"},
    "verify": {"self": "./scripts/gate.sh all"},
    "chapters": {"pattern": "{nn}-{title}.md"},
}

class DefaultsTest(unittest.TestCase):
    def test_defaults_fill_missing(self):
        c = with_defaults(MINIMAL)
        self.assertEqual(c["tools"][0]["where"], "both")
        self.assertEqual(c["chapters"]["dir"], "docs/chapters")
        self.assertFalse(c["chapters"]["strict_sections"])
        self.assertEqual(c["platforms"]["vm"]["assert_absent"], [])
        self.assertEqual(c["verify"]["infra"], "")
        self.assertEqual(c["skills"], {})

    def test_validate_rejects_unknown_top_key(self):
        c = with_defaults(MINIMAL); c["profiles"] = {}
        with self.assertRaises(ContractError) as e:
            validate(c)
        self.assertIn("profiles", str(e.exception))

    def test_validate_rejects_missing_install(self):
        c = with_defaults(MINIMAL); del c["tools"][0]["install"]
        with self.assertRaises(ContractError) as e:
            validate(c)
        self.assertIn("tools[0].install", str(e.exception))

    def test_validate_rejects_unsupported_mode(self):
        c = with_defaults(MINIMAL); c["platforms"]["windows"] = {"mode": "wsl2"}
        with self.assertRaises(ContractError) as e:
            validate(c)
        self.assertIn("windows.mode", str(e.exception))

class BuildTest(unittest.TestCase):
    def test_build_course_injects_identity(self):
        c = build_course(MINIMAL, name="my-course", title='A "quoted" $title')
        self.assertEqual(c["course"]["name"], "my-course")
        self.assertEqual(validate(with_defaults(c)), None)
        text = dump_course(c)
        self.assertIn('title: A "quoted" $title', text)
        self.assertTrue(text.endswith("\n"))
```

- [ ] **Step 2: 跑测试确认失败**

Run: `python3 -m unittest tests.unit.test_course_schema -v`
Expected: FAIL，`ModuleNotFoundError: No module named 'lib'` 或 `ImportError`。

- [ ] **Step 3: 实现 `lib/course_schema.py`**

实现要求：
- `load_yaml` 用 `yaml.safe_load`，文件为空返回 `{}`；解析失败时把 `yaml.YAMLError` 包成 `ContractError`，消息带行号。
- `validate` 检查：顶层键集合 ⊆ `{course, profile, tools, platforms, facts, verify, chapters, skills, privacy, stubs}`；`course.name` 匹配 `^[a-z0-9]+(-[a-z0-9]+)*$`；`profile ∈ {minimal, multi-vm}`；每个 tool 必须有 `name/min_version/check/install/required`，`where ∈ {host, control, both}`；`platforms.vm.provider == "virtualbox"`；`platforms.vm.arch == "amd64"`；`platforms.windows.mode ∈ {ssh-only, control-node}`；`chapters.pattern` 含 `{nn}`；每个 `privacy.allow[]` 必须有 `literal` 与 `reason`。
- `build_course` 深拷贝 profile，写入 `course.name/title/series` 与 `profile`；`mode` 非空时写 `platforms.windows.mode`。
- `dump_course` 用 `yaml.safe_dump(..., allow_unicode=True, sort_keys=False, default_flow_style=False)`，并在文件头加一行 `# 生成物：改配置只改本文件`。

- [ ] **Step 4: 跑测试确认通过**

Run: `python3 -m unittest tests.unit.test_course_schema -v`
Expected: `OK`（5 个测试）。

- [ ] **Step 5: 提交**

```bash
git add lib/course_schema.py tests/unit/test_course_schema.py
git commit -m "feat: course.yml 契约解析与默认值"
```

---

## Task 3: `minimal` 数据与 `new-course.sh --dry-run`

**Files:**
- Create: `profiles/minimal/course.yml`
- Create: `profiles/minimal/chapters/00-README.md`（只含标题与一句"章节待写"）
- Create: `profiles/minimal/files/.gitkeep`
- Create: `new-course.sh`（可执行）
- Create: `lib/gen.py`（本任务只实现 `render_profile` / `plan`）
- Test: `tests/test-generate.sh`（本任务只实现 dry-run 与拒绝非空目录两组断言）

**Interfaces:**
- Consumes: `lib.course_schema` 的 `load_profile`、`with_defaults`、`validate`、`build_course`、`dump_course`、`ContractError`
- Produces:
  - `lib/gen.py`: `@dataclass(frozen=True) class RenderedFile: relpath: str; content: bytes; mode: int = 0o644`
  - `lib/gen.py`: `render_profile(profile_dir: Path) -> list[RenderedFile]`（`chapters/` 与 `files/` 原样收集，不渲染）
  - `lib/gen.py`: `plan(files: list[RenderedFile]) -> str`（每行 `create <relpath>`，按路径排序；`course.yml` 由 `build_course` + `dump_course` 合成后放在清单第一项）
  - `new-course.sh` 参数：`<target-dir> --profile <name> [--name <kebab>] [--title <text>] [--series <text>] [--mode <ssh-only|control-node>] [--no-git] [--dry-run]`
  - 退出码：`0` 成功；`1` 目标/配置错误；`2` 用法错误（缺 `--profile`、未知参数、`multi-vm` 未实现）

- [ ] **Step 1: 写 `profiles/minimal/course.yml`**

```yaml
# 剖面种子值：生成时写一次，作者按课程改
profile: minimal
course:
  name: ""
  title: ""
  series: devops-self-study
  language: zh
  audience: ""
tools:
  - name: git
    min_version: "2.30"
    check: "git --version"
    install: "apt-get install -y git"
    required: true
    where: both
  - name: python3
    min_version: "3.8"
    check: "python3 --version"
    install: "apt-get install -y python3"
    required: true
    where: both
  - name: pyyaml
    min_version: "5.4"
    check: "python3 -c 'import yaml; print(yaml.__version__)'"
    install: "python3 -m pip install pyyaml"
    required: true
    where: both
skills:
  required: [brainstorming]
  optional: [systematic-debugging]
platforms:
  vm:
    provider: virtualbox
    default_box: bento/ubuntu-24.04
    arch: amd64
    assert_absent: []
  windows:
    mode: ssh-only
    min_ps: "5.1"
  linux:
    require_vboxusers: true
    kernel_module: vboxdrv
facts:
  source: docs/architecture.md
  note: 改拓扑只改这个文件；其他位置出现副本即为缺陷
verify:
  self: ./scripts/gate.sh all
  infra: ""
  expect_exit: 0
  evidence: logs/verify.log
privacy:
  derive: []
  allow: []
chapters:
  dir: docs/chapters
  pattern: "{nn}-{title}.md"
  strict_sections: false
  groups:
    - 准备环境
    - 核心操作
    - 故障排查
stubs: []
```

`chapters/` 下按 `groups` 生成三个空壳文件：`01-准备环境.md`、`02-核心操作.md`、`03-故障排查.md`，每个文件只有 `# 第 1 章 准备环境` 之类的一级标题。`00-README.md` 写 `# 章节目录\n\n> 章节正文待写。\n`。

- [ ] **Step 2: 写失败测试（dry-run 与目标目录保护）**

`tests/test-generate.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 1) 缺 --profile：退出码 2，输出列出可选值
set +e; out=$(./new-course.sh "$tmp/c1" 2>&1); rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: 缺 --profile 应为 2，实际 $rc"; exit 1; }
grep -q -- "--profile" <<<"$out" || { echo "FAIL: 未提示 --profile"; exit 1; }

# 2) multi-vm 未实现：退出码 2
set +e; ./new-course.sh "$tmp/c2" --profile multi-vm >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: multi-vm 应为退出码 2，实际 $rc"; exit 1; }

# 3) 非空目标：退出码 1 且零写入
mkdir -p "$tmp/c3"; echo keep >"$tmp/c3/.hidden"
before=$(cd "$tmp/c3" && find . -printf '%p %s\n' | sort | sha256sum)
set +e; ./new-course.sh "$tmp/c3" --profile minimal --name demo >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "FAIL: 非空目标应为退出码 1，实际 $rc"; exit 1; }
after=$(cd "$tmp/c3" && find . -printf '%p %s\n' | sort | sha256sum)
[ "$before" = "$after" ] || { echo "FAIL: 目标目录被写入"; exit 1; }

# 4) dry-run：打印清单且不落盘
./new-course.sh "$tmp/c4" --profile minimal --name demo --title 演示 --dry-run >"$tmp/plan"
grep -q '^create docs/chapters/01-' "$tmp/plan" || { echo "FAIL: 缺少章节目录"; exit 1; }
grep -q '^create course.yml$' "$tmp/plan" || { echo "FAIL: 缺少 course.yml"; exit 1; }
[ ! -e "$tmp/c4" ] || { echo "FAIL: dry-run 创建了目录"; exit 1; }

echo "PASS: test-generate (dry-run)"
```

- [ ] **Step 3: 跑测试确认失败**

Run: `bash tests/test-generate.sh`
Expected: FAIL（`./new-course.sh: No such file or directory`）。

- [ ] **Step 4: 实现 `lib/gen.py` 与 `new-course.sh`**

`new-course.sh` 只做：`set -euo pipefail`、解析参数、校验 `python3`/`PyYAML` 可用、`exec python3 "$repo/lib/gen.py" ...`。不在 bash 里解析 YAML。

`lib/gen.py` 的子命令：`gen.py plan <target> --profile ...`（dry-run）与 `gen.py write ...`（Task 11 才实现写盘；本任务遇到 `write` 时 `raise SystemExit("write 尚未实现")`，退出码 1）。

`render_profile` 规则：`chapters/*` → `chapters.dir/<同名>`；`files/**` → 相对仓库根的原路径；跳过 `.gitkeep`。

`plan()` 输出示例：

```
create course.yml
create docs/chapters/00-README.md
create docs/chapters/01-准备环境.md
```

- [ ] **Step 5: 跑测试确认通过**

Run: `bash tests/test-generate.sh`
Expected: `PASS: test-generate (dry-run)`，退出码 0。

- [ ] **Step 6: 提交**

```bash
git add profiles/minimal new-course.sh lib/gen.py tests/test-generate.sh
git commit -m "feat: minimal 剖面数据与生成器 dry-run"
```

---

## Task 4: 隐私门禁（8 条规则 + 自测）

**Files:**
- Create: `core/scripts/privacy-check.sh`（薄壳，`exec python3 .../privacy_scan.py "$@"`）
- Create: `core/scripts/privacy_scan.py`
- Create: `core/.githooks/pre-push`（内容替换掉 Task 1 的占位）
- Create: `.privacy-allow.yml`（模板仓库自己的豁免，带 `reason`）
- Create: `tests/lib/harness.sh`
- Test: `tests/test-privacy-gate.sh`

**Interfaces:**
- Consumes: `lib.course_schema.load_yaml`（只在 `--course` 给定时）
- Produces:
  - CLI: `privacy-check.sh [--root DIR] [--course FILE] [--allow FILE]`
  - 输出：每条命中一行 `path:line: <rule_id>: <message>`；命中即退出码 1；全干净输出 `privacy: OK (<n> files)` 退出码 0
  - `rule_id` 固定为：`abs-path`、`private-key`、`kubeconfig-secret`、`cloud-key`、`plain-password`、`private-ip`、`contact`、`sensitive-name`
  - `tests/lib/harness.sh` 提供：`new_tmpdir`、`assert_exit`、`assert_contains`

- [ ] **Step 1: 写失败测试**

`tests/test-privacy-gate.sh` 必须覆盖 8 条规则各一个反例 + 一个干净正例：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/harness.sh
tmp=$(new_tmpdir)

check_hit() { # $1=rule $2=filename $3=content
  local d; d=$(mktemp -d "$tmp/case.XXXX")
  printf '%b' "$3" >"$d/$2"
  set +e; out=$(bash core/scripts/privacy-check.sh --root "$d" 2>&1); rc=$?; set -e
  [ "$rc" -eq 1 ] || { echo "FAIL: $1 未拦截 (rc=$rc)"; exit 1; }
  grep -q "$2:1: $1:" <<<"$out" || { echo "FAIL: $1 位置/ID 不对: $out"; exit 1; }
}

# 注意：触发串用 "" 拼接，让本测试脚本自身不被隐私门禁判红（夹具只在运行时成型）。
check_hit abs-path        notes.md   '路径 /da""ta/Materials/x\n'
check_hit private-key     id_rsa     '-----BEGIN OPENSSH ""PRIVATE KEY-----\n'
check_hit kubeconfig-secret cfg.yaml 'client-key-da""ta: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQo=\n'
check_hit cloud-key       env.sh     'AWS_SECRET_ACCESS_""KEY=abcdefghijklmnopqrstuvwxyz0123456789ABCD\n'
check_hit plain-password  db.yml     'pass""word=Sup3rS3cret!\n'
check_hit private-ip      topo.md    '节点地址 192.168.""56.20\n'
check_hit contact         mail.md    '联系 admin""@example.com\n'
check_hit sensitive-name  kubeconfig 'apiVersion: v1\n'

# 正例：干净文件 + 白名单内的值
clean=$(mktemp -d "$tmp/clean.XXXX")
printf '示例地址 192.0.2.10\n' >"$clean/doc.md"
out=$(bash core/scripts/privacy-check.sh --root "$clean")
grep -q 'privacy: OK' <<<"$out" || { echo "FAIL: 干净输入误报: $out"; exit 1; }

# 白名单需要 reason
printf 'allow:\n  - literal: 192.168.56.20\n' >"$tmp/allow.yml"
set +e; out=$(bash core/scripts/privacy-check.sh --root "$clean" --allow "$tmp/allow.yml" 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] && grep -q 'reason' <<<"$out" || { echo "FAIL: 缺 reason 未报错"; exit 1; }

echo "PASS: test-privacy-gate"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test-privacy-gate.sh`
Expected: FAIL（`core/scripts/privacy-check.sh` 不存在）。

- [ ] **Step 3: 实现 `privacy_scan.py` 与薄壳**

规则细节（每条一次命中即报，不去重跨 rule）：
- `abs-path`：`(?<![\w$])/(data|home|Users|root|opt)/`（避免误伤 `$HOME` 与 URL）。
- `private-key`：`-----BEGIN [A-Z ]*PRIVATE KEY-----`。
- `kubeconfig-secret`：kubeconfig 的 `client-key-` / `client-certificate-` / `certificate-authority-` 前缀字段后跟 ≥ 64 个 base64 字符。
- `cloud-key`：AWS 访问密钥 ID（`AKIA` + 16 位大写字母数字）、AWS 秘密访问密钥赋值、`BEGIN RSA` / `BEGIN EC` 私钥头。
- `plain-password`：`(?i)(password|passwd|pwd)\s*[=:]\s*\S+`，但值以 `<` 开头（`<...>`）跳过。
- `private-ip`：`\b(10\.\d{1,3}|192\.168\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3})\.\d{1,3}\b`。
- `contact`：邮箱正则 + `\b1[3-9]\d{9}\b`（11 位连续数字）。
- `sensitive-name`：文件名精确匹配 `kubeconfig`、`id_rsa`、`id_ed25519`、`*.pem`、`*.key`（白名单可豁免）。

白名单：`--course` 的 `privacy.allow[].literal` + `privacy.derive[]`（从 `facts.source` 提取 `ip-like-scalars`）+ `--allow` 文件的 `allow[]`。每条必须有非空 `reason`，否则报 `allow[i].reason: 缺失` 并退出码 1。跳过目录：`.git/`、`logs/`、`node_modules/`、`__pycache__/`；**跳过白名单文件本身**（`--course` 与 `--allow` 指向的文件），否则豁免值会自己触发规则。

薄壳 `privacy-check.sh`：`exec python3 "$(dirname "$0")/privacy_scan.py" "$@"`。

- [ ] **Step 4: 写 `.privacy-allow.yml` 与 pre-push**

`.privacy-allow.yml`（模板仓库自用；设计文档里的示例 IP 需要豁免）：

```yaml
allow:
  - literal: 192.168.56.10
    reason: 设计文档中的拓扑示例地址，非真实主机
  - literal: 192.168.56.11
    reason: 设计文档中的拓扑示例地址，非真实主机
```

`core/.githooks/pre-push`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec bash scripts/gate.sh privacy
```

- [ ] **Step 5: 跑测试确认通过**

Run: `bash tests/test-privacy-gate.sh`
Expected: `PASS: test-privacy-gate`。

再跑模板仓库自身：`bash core/scripts/privacy-check.sh --root . --allow .privacy-allow.yml`
Expected: `privacy: OK (<n> files)`，退出码 0。

- [ ] **Step 6: 提交**

```bash
git add core/scripts core/.githooks .privacy-allow.yml tests/lib tests/test-privacy-gate.sh
git commit -m "feat: 隐私门禁（8 条规则 + 正反例自测）"
```

---

## Task 5: 文档门禁（七项 + BOM/换行）

**Files:**
- Create: `core/scripts/check-docs.py`
- Create: `core/scripts/gen-stats.py`（本任务只实现 `--count-chapters <dir>`，供 `check-docs.py` 检测硬编码数字）
- Test: `tests/test-docs-gate.sh`

**Interfaces:**
- Consumes: `lib.course_schema.load_yaml`、`with_defaults`
- Produces:
  - CLI: `check-docs.py [--root DIR] [--course FILE] [--sections] [--strict] [--eol]`
  - 输出：`path:line: <check_id>: <message>`；有问题退出码 1
  - `check_id`：`fence`、`table`、`anchor`、`heading`、`encoding`、`trailing-ws`、`sentence`、`bom`、`eol`、`hardcoded-count`
  - `gen-stats.py --count-chapters docs/chapters` 输出整数，退出码 0

- [ ] **Step 1: 写失败测试**

`tests/test-docs-gate.sh` 用临时目录构造四个反例 + 一个正例：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/harness.sh
tmp=$(new_tmpdir); d="$tmp/repo"; mkdir -p "$d/docs/chapters"

# 正例
printf '# 标题\n\n正文一句话。\n' >"$d/docs/ok.md"
printf '# 第 1 章 准备\n\n## 概念\n\n正文。\n\n## 清单\n\n正文。\n\n## 命令\n\n正文。\n\n## 实测输出\n\n正文。\n\n## 常见报错\n\n正文。\n\n## 坑\n\n正文。\n\n## 练习\n\n正文。\n\n## 答案\n\n正文。\n' >"$d/docs/chapters/01-a.md"
bash core/scripts/check-docs.py --root "$d" >/dev/null || { echo "FAIL: 正例被拦"; exit 1; }

# 围栏奇数
printf '# x\n\n```bash\necho hi\n' >"$d/docs/bad1.md"
# 表格错列
printf '# x\n\n| a | b |\n|---|---|\n| 1 |\n' >"$d/docs/bad2.md"
# 锚点失效
printf '# x\n\n见 [y](#不存在)。\n' >"$d/docs/bad3.md"
# 行尾空格
printf '# x\n\n有空格。 \n' >"$d/docs/bad4.md"

set +e; out=$(bash core/scripts/check-docs.py --root "$d" 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "FAIL: 反例未拦截"; exit 1; }
grep -q 'bad1.md:3: fence:' <<<"$out" || { echo "FAIL: fence 位置错"; exit 1; }
grep -q 'bad2.md:5: table:' <<<"$out" || { echo "FAIL: table 位置错"; exit 1; }
grep -q 'bad3.md:3: anchor:' <<<"$out" || { echo "FAIL: anchor 位置错"; exit 1; }
grep -q 'bad4.md:3: trailing-ws:' <<<"$out" || { echo "FAIL: 行尾空格未报"; exit 1; }

# --sections 只作用于 chapters.dir，不碰 README
set +e; out=$(bash core/scripts/check-docs.py --root "$d" --sections 2>&1); rc=$?; set -e
if grep -q 'docs/ok.md' <<<"$out"; then echo "FAIL: --sections 误伤非章节文件"; exit 1; fi
if grep -q 'chapters/01-a.md' <<<"$out"; then echo "FAIL: 八段齐全的章节被误报"; exit 1; fi

# BOM 与 CRLF
printf '\xef\xbb\xbf# x\n' >"$d/docs/bom.md"
printf '#!/usr/bin/env bash\r\necho hi\r\n' >"$d/run.sh"
set +e; out=$(bash core/scripts/check-docs.py --root "$d" --eol 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "FAIL: BOM/CRLF 未拦截"; exit 1; }
grep -q 'bom.md:1: bom:' <<<"$out" || { echo "FAIL: BOM 未报"; exit 1; }
grep -q 'run.sh:1: eol:' <<<"$out" || { echo "FAIL: CRLF 未报"; exit 1; }

echo "PASS: test-docs-gate"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test-docs-gate.sh`
Expected: FAIL（`check-docs.py` 不存在）。

- [ ] **Step 3: 实现 `check-docs.py`**

要求：
- 遍历 `--root` 下所有 `*.md`，跳过 `.git/`、`logs/`。
- 七项检查严格按 Spec §5.3；`anchor` 用 GitHub slug 规则（小写、空格转 `-`、去标点）；`heading` 需先剔除围栏内容；`sentence` 只要求文件末行非空且以 `。`/`.`/`!`/`?`/`）`/`)` 结尾。
- `--eol` 只查 `git ls-files` 里的文件：`*.sh|*.py|*.yml|*.yaml|*.md|Vagrantfile` 索引必须是 `lf`，`*.ps1` 索引必须是 `lf`（worktree 由 `.gitattributes` 转 `crlf`）。**不在 git 仓库里时**（测试夹具）按扩展名遍历目录，`*.sh|*.py|*.yml|*.yaml|*.md` 必须为 `lf`，`*.ps1` 必须为 `crlf`。
- `--sections` / `--strict` 只作用 `course.yml` 的 `chapters.dir` 与 `chapters.pattern`；`--strict` 要求八段标题下各至少一行非空正文。`--sections` 不要求正文（空壳章节合法）。
- `hardcoded-count`：在 `docs/**.md` 里匹配 `共\s*\d+\s*章`，命中时警告（stderr），**不改退出码**。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test-docs-gate.sh`
Expected: `PASS: test-docs-gate`。

Run: `python3 core/scripts/check-docs.py --root . --eol`
Expected: 退出码 0（此时仓库内文本文件都是 LF；若报 `.privacy-allow.yml` 之类新文件，按 `.gitattributes` 修正）。

- [ ] **Step 5: 提交**

```bash
git add core/scripts/check-docs.py core/scripts/gen-stats.py tests/test-docs-gate.sh
git commit -m "feat: 文档门禁（七项检查 + BOM/换行）"
```

---

## Task 6: 前置条件门禁

**Files:**
- Create: `core/scripts/check-prereqs.sh`
- Create: `core/scripts/check_prereqs.py`
- Test: `tests/test-prereqs.sh`

**Interfaces:**
- Consumes: `lib.course_schema.load_yaml`、`with_defaults`
- Produces:
  - CLI: `check-prereqs.sh [--course FILE] [--where host|control] [--root DIR]`
  - 输出顺序：每个工具一块（`[ok]` / `[missing]` / `[old]` / `[warn]`），最后技能提示；缺失必装项退出码 1
  - 每个失败块必须含 `install:` 行，且命令可复制粘贴

- [ ] **Step 1: 写失败测试**

`tests/test-prereqs.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/harness.sh
tmp=$(new_tmpdir)

cat >"$tmp/course.yml" <<'YAML'
course: {name: demo, title: 演示, series: devops-self-study}
profile: minimal
tools:
  - {name: definitely-not-installed-xyz, min_version: "1.0",
     check: "definitely-not-installed-xyz --version",
     install: "apt-get install -y definitely-not-installed-xyz",
     required: true, where: both}
  - {name: control-only-tool, min_version: "1.0", check: "control-only-tool --version",
     install: "apt-get install -y control-only-tool", required: true, where: control}
platforms: {vm: {provider: virtualbox, default_box: bento/ubuntu-24.04, arch: amd64}}
facts: {source: docs/architecture.md}
verify: {self: "./scripts/gate.sh all"}
chapters: {pattern: "{nn}-{title}.md"}
skills: {required: [brainstorming], optional: []}
YAML

set +e; out=$(bash core/scripts/check-prereqs.sh --course "$tmp/course.yml" --where host 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "FAIL: 缺工具未拦截"; exit 1; }
grep -q 'apt-get install -y definitely-not-installed-xyz' <<<"$out" || { echo "FAIL: 无安装命令"; exit 1; }
grep -q 'control-only-tool' <<<"$out" && { echo "FAIL: where=control 在宿主被检查"; exit 1; }
grep -q 'brainstorming' <<<"$out" || { echo "FAIL: 技能清单未打印"; exit 1; }
grep -q '真机验证未完成' <<<"$out" || { echo "FAIL: verify.infra 为空未警告"; exit 1; }

echo "PASS: test-prereqs"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test-prereqs.sh`
Expected: FAIL（脚本不存在）。

- [ ] **Step 3: 实现**

`check_prereqs.py` 逻辑：
1. `with_defaults` 后按 `--where` 过滤（`host` → `host`+`both`；`control` → `control`+`both`）。
2. 跑 `tools[].check`（`sh -c`，超时 10 秒），用 `re.search(r'(\d+)\.(\d+)(?:\.(\d+))?', stdout+stderr)` 取版本，与 `min_version` 比较。
3. 缺失 → `[missing] name (要求 >= X)` + `install: <cmd>`；有输出但版本低 → `[old] name (当前 Y, 要求 >= X)` + `install:`。
4. `required: false` 的失败降级为 `[warn]`，不改退出码。
5. `verify.infra` 为空时 stderr 打：

```
[warn] 真机验证未完成：course.yml 的 verify.infra 为空
       DoD 不允许勾选“已验证”，见 docs/definition-of-done.md
```

6. `skills` 只打印（Spec §5.4 原文），永不改退出码。

`check-prereqs.sh` 薄壳同样 `exec python3`。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test-prereqs.sh`
Expected: `PASS: test-prereqs`。

- [ ] **Step 5: 提交**

```bash
git add core/scripts/check-prereqs.sh core/scripts/check_prereqs.py tests/test-prereqs.sh
git commit -m "feat: 前置条件门禁（缺失工具给安装命令）"
```

---

## Task 7: 镜像门禁与干净起点

**Files:**
- Create: `core/platform/vm/boxes.yml`
- Create: `core/platform/vm/baseline.sh`
- Create: `core/platform/vm/probe.sh`
- Create: `core/scripts/check-boxes.sh`
- Create: `core/scripts/check_boxes.py`
- Test: `tests/test-boxes.sh`

**Interfaces:**
- Consumes: `lib.course_schema.load_yaml`、`with_defaults`
- Produces:
  - `boxes.yml` 结构：`families: {debian: {pkg: apt, firewall: ufw, selinux: false}, rhel: {pkg: dnf, firewall: firewalld, selinux: true}}`；`boxes: {bento/ubuntu-24.04: debian, bento/rockylinux-9: rhel, ...}`（只存 Spec §16.3 允许清单）
  - `check-boxes.sh [--course FILE] [--facts FILE]`：未知 box → `[error] unknown box: <name>` + `did you mean: <candidate>`，退出码 1；≥2 家族 → stderr 提示"跨系课程需在命令块标注执行节点"，退出码不变
  - `baseline.sh [--course FILE] [--facts FILE] [--warn]`：VM 内执行；空 `assert_absent` 时只打印 `os-release`/`uname -r`；命中 → `[error] <name> 已安装`，退出码 1（`--warn` 时改 0）
  - `check_boxes.py --print-assert-absent --course FILE`：每行一个待断言命令名，无则输出空、退出码 0（供 `baseline.sh` 调）
  - `probe.sh [--facts FILE]`：宿主执行，写 `logs/vm-probe.txt`（`vagrant box list` + 每台 VM 的 `ostype`/`GuestAdditionsVersion`），失败只警告

- [ ] **Step 1: 写失败测试**

`tests/test-boxes.sh` 覆盖四个断言（不建 VM，用临时目录造 `node` 假可执行文件）：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/harness.sh
tmp=$(new_tmpdir); mkdir -p "$tmp/bin"

# 1) 未知 box → 退出码 1 + 候选
cat >"$tmp/course-bad.yml" <<'YAML'
course: {name: demo, title: 演示, series: devops-self-study}
profile: minimal
tools: [{name: git, min_version: "2.30", check: "git --version", install: "x", required: true}]
platforms: {vm: {provider: virtualbox, default_box: bento/ubunut-24.04, arch: amd64}}
facts: {source: docs/architecture.md}
verify: {self: "./scripts/gate.sh all"}
chapters: {pattern: "{nn}-{title}.md"}
YAML
set +e; out=$(bash core/scripts/check-boxes.sh --course "$tmp/course-bad.yml" 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "FAIL: 未知 box 未拦截"; exit 1; }
grep -q 'did you mean: bento/ubuntu-24.04' <<<"$out" || { echo "FAIL: 未给候选: $out"; exit 1; }

# 2) 省略节点 box → 继承 default_box（不报未知）
cat >"$tmp/facts.yml" <<'YAML'
nodes:
  - {name: app-1, role: app, ip: 192.0.2.10}
YAML
cat >"$tmp/course-ok.yml" <<'YAML'
course: {name: demo, title: 演示, series: devops-self-study}
profile: minimal
tools: [{name: git, min_version: "2.30", check: "git --version", install: "x", required: true}]
platforms: {vm: {provider: virtualbox, default_box: bento/ubuntu-24.04, arch: amd64}}
facts: {source: docs/facts.yml}
verify: {self: "./scripts/gate.sh all"}
chapters: {pattern: "{nn}-{title}.md"}
YAML
bash core/scripts/check-boxes.sh --course "$tmp/course-ok.yml" --facts "$tmp/facts.yml" >/dev/null

# 3) 两家族 → 提示但不改退出码
cat >"$tmp/facts2.yml" <<'YAML'
nodes:
  - {name: app-1, role: app, ip: 192.0.2.10, box: bento/ubuntu-24.04}
  - {name: db-1, role: db, ip: 192.0.2.11, box: bento/rockylinux-9}
YAML
set +e; out=$(bash core/scripts/check-boxes.sh --course "$tmp/course-ok.yml" --facts "$tmp/facts2.yml" 2>&1); rc=$?; set -e
[ "$rc" -eq 0 ] || { echo "FAIL: 跨系不应改退出码"; exit 1; }
grep -q '跨系' <<<"$out" || { echo "FAIL: 无跨系提示"; exit 1; }

# 4) assert_absent 命中 / 为空
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/nginx"; chmod +x "$tmp/bin/nginx"
cat >"$tmp/course-absent.yml" <<'YAML'
course: {name: demo, title: 演示, series: devops-self-study}
profile: minimal
tools: [{name: git, min_version: "2.30", check: "git --version", install: "x", required: true}]
platforms: {vm: {provider: virtualbox, default_box: bento/ubuntu-24.04, arch: amd64, assert_absent: [nginx]}}
facts: {source: docs/facts.yml}
verify: {self: "./scripts/gate.sh all"}
chapters: {pattern: "{nn}-{title}.md"}
YAML
set +e; out=$(PATH="$tmp/bin:$PATH" bash core/platform/vm/baseline.sh --course "$tmp/course-absent.yml" 2>&1); rc=$?; set -e
[ "$rc" -eq 1 ] || { echo "FAIL: 缺席断言未拦截"; exit 1; }
grep -q 'nginx' <<<"$out" || { echo "FAIL: 未报 nginx"; exit 1; }

PATH="$tmp/bin:$PATH" bash core/platform/vm/baseline.sh --course "$tmp/course-ok.yml" >/dev/null

echo "PASS: test-boxes"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test-boxes.sh`
Expected: FAIL（脚本不存在）。

- [ ] **Step 3: 实现**

- `boxes.yml` 只放 Spec §16.3 名单（bento/ubuntu-22.04/24.04/25.04/26.04、debian-11/12/13、rockylinux-8/9/10、almalinux-8/9/10、oracle-9/10 按实测名称、centos-stream-9、fedora-latest、opensuse-leap-15、amazonlinux-2023），每个映射到 `debian` 或 `rhel`。
- `check_boxes.py` 的"最近候选"用 `difflib.get_close_matches`。
- `baseline.sh` 用 bash（VM 内可能没有 Python 之外的依赖，只依赖 `command -v`、`cat`、`uname`），读 `assert_absent` 时用 `python3 -c` 调 `check_boxes.py --print-assert-absent`。
- `probe.sh` 用 `VBoxManage showvminfo <name> --machinereadable`，节点名从 `facts.source` 读；`logs/` 不存在则 `mkdir -p`。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test-boxes.sh`
Expected: `PASS: test-boxes`。

- [ ] **Step 5: 提交**

```bash
git add core/platform/vm core/scripts/check-boxes.sh core/scripts/check_boxes.py tests/test-boxes.sh
git commit -m "feat: 镜像门禁与 VM 内干净起点断言"
```

---

## Task 8: `gate.sh` 统一入口

**Files:**
- Create: `core/scripts/gate.sh`
- Create: `tests/run-all.sh`
- Test: `tests/test-gate.sh`

**Interfaces:**
- Consumes: Task 4/5/6/7 的四个门禁脚本
- Produces:
  - `gate.sh {privacy|docs|prereqs|boxes|redlines|all} [--root DIR]`
  - `all` 顺序固定：privacy → docs → prereqs → boxes → redlines；任一失败立即退出该码；全通过打印 `gate: all OK`
  - `privacy` 自动带上 `<root>/course.yml`（存在时）与 `<root>/.privacy-allow.yml`（存在时）
  - `redlines` 只打印四条红线与"无法自动验证"的说明，永远退出码 0
  - `tests/run-all.sh` 依次跑 `test-privacy-gate.sh`、`test-docs-gate.sh`、`test-prereqs.sh`、`test-boxes.sh`、`test-gate.sh`，失败即停

- [ ] **Step 1: 写失败测试**

`tests/test-gate.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/harness.sh
out=$(bash core/scripts/gate.sh redlines)
grep -q '不确认就删文件' <<<"$out" || { echo "FAIL: 红线未打印"; exit 1; }
grep -q '无法自动验证' <<<"$out" || { echo "FAIL: 未说明强度边界"; exit 1; }
set +e; bash core/scripts/gate.sh no-such-gate >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || { echo "FAIL: 未知子命令应为 2"; exit 1; }
echo "PASS: test-gate"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test-gate.sh`
Expected: FAIL。

- [ ] **Step 3: 实现**

`gate.sh` 只做 `case` 分发 + 参数透传，不内联业务逻辑。`--root` 统一转成 `--root`/`--course "$root/course.yml"` 传给子门禁（`course.yml` 不存在时不传 `--course`，由子脚本用默认值）。

`redlines` 输出（逐字）：

```
[redlines] 本模板的四条行为红线（脚本只能提示，不能代替评审）：
  1. 未经确认不删除文件
  2. 未经确认不开始写内容
  3. 隐私检查必须执行（pre-push + CI）
  4. 必须按流程执行（见 AGENTS.md 的流程分级）
[redlines] 前两条与第四条的部分内容无法自动验证；违反者应留下痕迹（docs/decisions.md）。
```

- [ ] **Step 4: 跑测试确认通过**

```bash
bash tests/test-gate.sh && bash tests/run-all.sh
```

Expected: `PASS: test-gate`，随后五个 `PASS:` 行。

- [ ] **Step 5: 提交**

```bash
git add core/scripts/gate.sh tests/run-all.sh tests/test-gate.sh
git commit -m "feat: gate.sh 统一门禁入口"
```

---

## Task 9: `core/` 文档种子与 `AGENTS.md.tmpl`

**Files:**
- Create: `core/AGENTS.md.tmpl`
- Create: `core/docs/conventions.md`
- Create: `core/docs/decisions.md`
- Create: `core/docs/definition-of-done.md`
- Create: `core/docs/architecture.md.tmpl`
- Create: `core/docs/retrospective.md.tmpl`
- Create: `core/README.md.tmpl`（生成物 README 模板）
- Modify: `tests/run-all.sh`（加入 `test-docs-seeds.sh`）
- Test: `tests/test-docs-seeds.sh`

**Interfaces:**
- Consumes: 无（纯模板文件）
- Produces: 模板占位符只有六个：`{{course_name}}`、`{{course_title}}`、`{{series}}`、`{{profile}}`、`{{chapters_dir}}`、`{{template_version}}`（Task 11 渲染）
- `AGENTS.md.tmpl` 必须含 `<!-- TEMPLATE:BEGIN -->` 与 `<!-- TEMPLATE:END -->` 各一次（§7.2 的 `managed-region`）

- [ ] **Step 1: 写失败测试**

`tests/test-docs-seeds.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
f=core/AGENTS.md.tmpl
[ "$(grep -c '<!-- TEMPLATE:BEGIN -->' "$f")" -eq 1 ] || { echo "FAIL: BEGIN 标记"; exit 1; }
[ "$(grep -c '<!-- TEMPLATE:END -->' "$f")" -eq 1 ] || { echo "FAIL: END 标记"; exit 1; }
for kw in '不确认就删' '不确认就开始写' '隐私检查' '流程分级' '单一事实源'; do
  grep -q "$kw" "$f" || { echo "FAIL: AGENTS.md 缺 $kw"; exit 1; }
done
grep -q '^## 完成定义' core/docs/definition-of-done.md || { echo "FAIL: DoD 结构"; exit 1; }
grep -q '逃生路径已演练' core/docs/definition-of-done.md || { echo "FAIL: DoD 缺单点演练"; exit 1; }
grep -q 'CI 尚未真跑过' core/README.md.tmpl || { echo "FAIL: README 缺 CI 口径"; exit 1; }
grep -q '常见报错' core/docs/conventions.md || { echo "FAIL: 八段式未写"; exit 1; }
for f in core/docs/*.md.tmpl; do
  grep -q '{{' "$f" || { echo "FAIL: $f 无模板占位符"; exit 1; }
done
echo "PASS: test-docs-seeds"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test-docs-seeds.sh`
Expected: FAIL（文件不存在）。

- [ ] **Step 3: 写 `AGENTS.md.tmpl`**

结构（顺序固定）：

1. `# AGENTS.md — {{course_title}}`
2. `<!-- TEMPLATE:BEGIN -->` 到 `<!-- TEMPLATE:END -->` 之间：四条红线（每条一句"不做什么"）、流程分级（轻量默认 + 5 条升级条件）、单一事实源（`course.yml` 与事实源文件）、隐私（禁止 `--no-verify`）、提交规范、生成物版本线。
3. 区域外：`## 本课程补充约定`（空 + 一行 `<!-- 作者可在此自由增删 -->`）。

`docs/definition-of-done.md` 的完成定义至少六条，第 1 条"方案已确认"，第 2 条"`verify.infra` 非空且已跑过"，第 5 条"逃生路径已演练并记录耗时"。

`docs/conventions.md` 写八段式（概念 → 清单 → 命令 → 实测输出 → 常见报错 → 坑 → 练习 → 答案）、术语表、提交规范（Conventional Commits）、数字规则（禁止手写"共 N 章"）。

`docs/architecture.md.tmpl`：拓扑表头 + `事实源：{{chapters_dir}}/...` 指向 `course.yml` 的 `facts.source`，留空表格。

`docs/retrospective.md.tmpl`：14 个二级标题（背景、目标、做了什么、没做什么、数字、决策、踩坑、短板、改进、复用性、验证方式、未验证项、下一步、附录）。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test-docs-seeds.sh`
Expected: `PASS: test-docs-seeds`。

- [ ] **Step 5: 提交**

```bash
git add core/AGENTS.md.tmpl core/docs core/README.md.tmpl tests/test-docs-seeds.sh
git commit -m "feat: core 文档种子与 AGENTS.md 契约模板"
```

---

## Task 10: 平台层（Linux 检查 + Windows `ssh-only`）

**Files:**
- Create: `core/platform/README.md`
- Create: `core/platform/linux/check.sh`
- Create: `core/platform/windows/emit.ps1`
- Create: `core/platform/windows/check.ps1`
- Create: `core/platform/windows/up.ps1`
- Create: `core/platform/windows/down.ps1`
- Create: `core/platform/windows/destroy.ps1`
- Modify: `tests/run-all.sh`（加入 `test-platform.sh`）
- Test: `tests/test-platform.sh`

**Interfaces:**
- Consumes: `lib.course_schema`（读 `platforms` 与事实源），`core/scripts/check-boxes.sh`（跨系提示复用）
- Produces:
  - `check.sh [--strict]`：六项检查（Spec §15.7），默认只提示退出码 0；`--strict` 有问题退出码 1
  - `emit.ps1`：`function Write-Utf8NoBom([string]$Path, [string]$Text)` 与 `function Test-Admin`
  - `check.ps1`：七项（Spec §15.8）——PS 版本、管理员、Hyper-V/WSL2、`ssh`、路径含空格/中文、网段、内存；每项输出 `[ok]`/`[warn]`/`[fail]`
  - `up.ps1`：`-NoElevate` 可选；非管理员时 `Start-Process -Verb RunAs` 自提权后父进程 `exit 0`；调 `vagrant up`
  - `down.ps1` / `destroy.ps1`：`vagrant halt` / `vagrant destroy -f`，各带 `-Confirm` 之外的二次确认（destroy 必须输入 `yes`）
  - `platform/README.md`：平台矩阵 + "什么没验证"（Windows 四项）

- [ ] **Step 1: 写失败测试**

`tests/test-platform.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ps=core/platform/windows
for f in "$ps"/*.ps1; do
  grep -nE '\?\?|\?\.|-Parallel|Set-Content|Out-File' "$f" && { echo "FAIL: $f 含 PS7+ 或默认编码写文件"; exit 1; }
  head -c3 "$f" | od -An -tx1 | grep -q 'ef bb bf' && { echo "FAIL: $f 有 BOM"; exit 1; }
  [ "$(git check-attr eol -- "$f" | awk -F': ' '{print $3}')" = "crlf" ] || { echo "FAIL: $f 未声明 eol=crlf"; exit 1; }
done
grep -q 'Write-Utf8NoBom' "$ps/emit.ps1" || { echo "FAIL: emit.ps1 缺函数"; exit 1; }
grep -q 'Test-Admin' "$ps/check.ps1" || true
grep -q 'hypervisorlaunchtype' "$ps/check.ps1" || { echo "FAIL: Hyper-V 指引"; exit 1; }
grep -q '未验证' core/platform/README.md || { echo "FAIL: 未写未验证项"; exit 1; }
bash -n core/platform/linux/check.sh
bash core/platform/linux/check.sh >/dev/null || true
echo "PASS: test-platform"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test-platform.sh`
Expected: FAIL。

- [ ] **Step 3: 实现 Linux 与 Windows 脚本**

Linux `check.sh` 用 `mktemp` 保存检查结果，六项逐条打印，`--strict` 时统计失败数。缺 `VBoxManage` 时也给安装指引（Oracle 官方仓库），因为这是最常见的第一道坎。

Windows 侧：所有脚本开头 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`；所有写文件走 `emit.ps1`；输出不带 emoji；不引入 PS 7 语法。`up.ps1` 的 `ssh-only` 档只做"检查 → 提权 → `vagrant up`"，不引导控制机。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test-platform.sh`
Expected: `PASS: test-platform`。

- [ ] **Step 5: 提交**

```bash
git add core/platform tests/test-platform.sh
git commit -m "feat: 平台层（Linux 检查 + Windows ssh-only 档）"
```

---

## Task 11: 渲染、写盘与生成物契约

**Files:**
- Modify: `lib/gen.py`（补 `render_core` / `write` / `core_manifest` / `write` 子命令）
- Modify: `new-course.sh`（`--dry-run` 之外走 `gen.py write`）
- Test: `tests/test-generate.sh`（追加生成物断言）

**Interfaces:**
- Consumes: Task 2/3 的 `course_schema` 与 `RenderedFile`；Task 9 的六个占位符；Task 10 的 `platform/` 文件
- Produces:
  - `render_core(template_root: Path, course: dict) -> list[RenderedFile]`：读 `core/**`，`*.tmpl` 渲染后去掉后缀；按 `platforms.windows.mode` 裁剪（`ssh-only` 不含 `provision-control.sh`、`guest/bin/*`、`gen-nodes.py`）
  - `write(target: Path, files: list[RenderedFile]) -> list[str]`：先全部渲染到内存，再一次性落盘；任何异常在落盘前抛
  - `core_manifest(files: list[RenderedFile]) -> str`：`sha256  relpath` 每行，按路径排序
  - 生成物 `.course/template-version` 字段固定：`template`、`version`、`profile`、`sha`、`generated_at`

- [ ] **Step 1: 追加失败测试**

在 `tests/test-generate.sh` 末尾追加（保留原有四组）：

```bash
# 5) 完整生成：结构 + 契约 + 无模板残留
./new-course.sh "$tmp/c5" --profile minimal --name demo-course --title "演示课程"
[ -f "$tmp/c5/course.yml" ] || { echo "FAIL: 缺 course.yml"; exit 1; }
[ -f "$tmp/c5/.course/template-version" ] || { echo "FAIL: 缺 template-version"; exit 1; }
grep -q 'template: devops-self-study-base' "$tmp/c5/.course/template-version" || { echo "FAIL: 来源线错误"; exit 1; }
grep -q 'name: demo-course' "$tmp/c5/course.yml" || { echo "FAIL: 课程名未注入"; exit 1; }
! grep -rq '{{' "$tmp/c5" --exclude-dir=.git || { echo "FAIL: 有未渲染的占位符"; exit 1; }
[ ! -e "$tmp/c5/core" ] || { echo "FAIL: core/ 不应出现在生成物"; exit 1; }
[ -e "$tmp/c5/platform/windows/provision-control.sh" ] && { echo "FAIL: ssh-only 出现控制机脚本"; exit 1; }
[ -f "$tmp/c5/scripts/gate.sh" ] || { echo "FAIL: 缺门禁"; exit 1; }
bash "$tmp/c5/scripts/gate.sh" all >/dev/null || { echo "FAIL: 生成物门禁不绿"; exit 1; }
[ -f "$tmp/c5/tests/run-all.sh" ] || { echo "FAIL: tests 未入库"; exit 1; }
(cd "$tmp/c5" && git ls-files | grep -q '^tests/') || { echo "FAIL: tests 未被跟踪"; exit 1; }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash tests/test-generate.sh`
Expected: FAIL（`write 尚未实现` 或生成物缺文件）。

- [ ] **Step 3: 实现渲染与写盘**

规则：
- 只有 `*.tmpl` 渲染；渲染用 `str.replace` 逐个替换六个占位符（不用 `string.Template`，避免 YAML 里的 `$` 被当变量）。
- 渲染后若内容仍含 `{{`，直接 `ContractError`（不生成半成品）。
- `core/` 目录不进生成物：文件映射到仓库根（`core/scripts/gate.sh` → `scripts/gate.sh`，`core/docs/conventions.md` → `docs/conventions.md`）。
- `core/.githooks/pre-push` → `.githooks/pre-push`，保留可执行位（`mode=0o755`）。
- 生成后：`mkdir -p` 各级目录；写文件；`chmod` 按 `mode`；写 `.course/core-manifest.txt` 与 `.course/template-version`；`git init -b main` + `git config core.hooksPath .githooks` + `git add -A` + `git commit`（`--no-git` 时跳过这四步）。生成器的 commit 作者用 `git -c user.name=... -c user.email=...`，不读全局配置。
- 目标目录检查放在**渲染之前**：存在且非空（含 `.git` 之外的隐藏文件也算）→ 退出码 1。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash tests/test-generate.sh`
Expected: `PASS: test-generate`（全部五组）。

- [ ] **Step 5: 提交**

```bash
git add lib/gen.py new-course.sh tests/test-generate.sh
git commit -m "feat: 渲染写盘与生成物契约（.course、manifest、git init）"
```

---

## Task 12: 端到端测试、CI 与 P2 验收

**Files:**
- Create: `tests/test-idempotent.sh`
- Create: `tests/test-profile-purity.sh`
- Create: `core/.github/workflows/gate.yml`
- Create: `core/.gitea/workflows/gate.yml`
- Modify: `tests/run-all.sh`（并入 `test-generate.sh`、`test-idempotent.sh`、`test-profile-purity.sh`，末尾打 `ALL PASS`）
- Modify: `README.md`（补 P2 已实现清单与"未实现"清单）
- Modify: `CHANGELOG.md`（P2 条目）

**Interfaces:**
- Consumes: Task 11 的生成器
- Produces:
  - `test-idempotent.sh`：非空目录 → 退出码 1 且零写入（复用 Task 3 的断言，扩大覆盖面到 `.git` 与嵌套子目录）
  - `test-profile-purity.sh`：`profiles/**` 下无 `*.sh`/`*.py`；`profiles/` 一级目录名 ⊆ `{minimal, multi-vm}`；`profiles/minimal/course.yml` 的 `profile` 与目录名一致
  - 两个 workflow：`on: [push, pull_request]`、`runs-on: ubuntu-latest`、装 `python3-yaml`、跑 `bash scripts/gate.sh all` 与 `bash tests/run-all.sh`

- [ ] **Step 1: 写两个测试并跑（预期失败/通过各半）**

`test-profile-purity.sh` 现在应**通过**（`profiles/` 只有数据）；`test-idempotent.sh` 现在应**通过**（Task 11 已实现）。两者都要在 `run-all.sh` 里能被调用。

Run: `bash tests/test-idempotent.sh && bash tests/test-profile-purity.sh`
Expected: 两个 `PASS:`。

- [ ] **Step 2: 写 CI workflow（两份等价）**

```yaml
name: gate
on: [push, pull_request]
jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y python3-yaml
      - run: bash scripts/gate.sh all
      - run: bash tests/run-all.sh
```

Gitea 版只把 `uses: actions/checkout@v4` 换成 `uses: actions/checkout@v4`（Gitea 兼容该语法），其余逐字相同；两文件差异必须只有注释首行。

Run: `python3 -c "import yaml,sys; [yaml.safe_load(open(p)) for p in sys.argv[1:]]" core/.github/workflows/gate.yml core/.gitea/workflows/gate.yml`
Expected: 无输出，退出码 0。

- [ ] **Step 3: 更新 README 与 CHANGELOG**

README 增加两段：**已实现（P0–P2）**（minimal 生成、五道门禁、Linux/Windows ssh-only、自测九个中的六个）与**尚未实现（P3+）**（`multi-vm`、`control-node`、`sync-template.sh`、节点级 `box:` 覆盖）。CHANGELOG 的 `[Unreleased]` 增加对应条目，并保留两条 `[未验证]`。

- [ ] **Step 4: 全量验收**

```bash
bash tests/run-all.sh
bash core/scripts/gate.sh all
```

Expected:
- `tests/run-all.sh` 输出 10 个 `PASS:`（privacy、docs、prereqs、boxes、gate、docs-seeds、platform、generate、idempotent、profile-purity），末尾 `ALL PASS`；
- `gate.sh all` 末尾 `gate: all OK`。

- [ ] **Step 5: P2 手工验收（记录，不算 CI）**

Linux 桌面走一遍：

```bash
./new-course.sh /tmp/p2-demo --profile minimal --name p2-demo --title "P2 演示"
cd /tmp/p2-demo && bash scripts/gate.sh all
```

Expected: 全绿。把输出贴进 `docs/decisions.md` 之前的 `CHANGELOG.md` 不写"已验证 Windows"。

- [ ] **Step 6: 提交**

```bash
git add tests core/.github core/.gitea README.md CHANGELOG.md
git commit -m "test: P2 端到端验收与 CI 骨架"
```

---

## 完成判据（P2）

| # | 判据 | 命令 |
|---|---|---|
| 1 | `minimal` × `ssh-only` 生成成功 | `bash tests/test-generate.sh` |
| 2 | 生成物门禁全绿 | `cd <生成物> && bash scripts/gate.sh all` |
| 3 | 非空目录零写入 | `bash tests/test-idempotent.sh` |
| 4 | 剖面只有数据 | `bash tests/test-profile-purity.sh` |
| 5 | 镜像门禁静态通过 | `bash tests/test-boxes.sh` |
| 6 | 模板自测全绿 | `bash tests/run-all.sh` |
| 7 | CI 文件存在且 YAML 合法 | Task 12 Step 2 |
| 8 | Linux 桌面手工走通 | Task 12 Step 5 |

**明确不在 P2 判据内**：`multi-vm`、`control-node`、`sync-template.sh`、节点级 `box:` 覆盖、Windows 实机四项、CI 真实执行——全部标"未实现"或"未验证"。

## 与 Spec 的差异（需回写设计文档）

1. 新增 `lib/`（模板仓库私有生成器）与 `core/scripts/privacy_scan.py`、`check_prereqs.py`、`check_boxes.py`：实现语言定为"bash 薄壳 + Python"，Spec §4.2 的树要补这三个文件与 `lib/`。
2. 新增模板仓库自用的 `.privacy-allow.yml`：Spec §5.2 只描述了 `course.yml` 的 `privacy.allow`，需补一句"模板仓库自身用根目录 `.privacy-allow.yml`，结构相同、同样要求 `reason`"。
3. 新增 `tests/test-gate.sh`、`tests/test-docs-seeds.sh`、`tests/unit/test_course_schema.py`：Spec §10 的九项测试表要补这三项（模板自测从 9 变 12）。

以上三条在 Task 12 完成后，单独提交一次到 `k3s-ops` 的设计文档（不改 Spec 的决策，只补实现落点）。
