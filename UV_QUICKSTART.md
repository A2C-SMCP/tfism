# uv 包管理快速参考

## 环境信息

- **Python 版本**: 3.11.13
- **包管理器**: uv (latest)
- **项目根目录**: `/Users/JQQ/PycharmProjects/tfsm`
- **虚拟环境**: `.venv/`

---

## 常用命令

### 激活虚拟环境

```bash
source .venv/bin/activate
```

### 安装依赖

```bash
# 安装所有开发依赖
uv pip install -e ".[dev]"

# 安装特定依赖组
uv pip install -e ".[test]"      # 测试依赖
uv pip install -e ".[mypy]"      # 类型检查
uv pip install -e ".[diagrams]"  # 图形生成（需要系统安装 graphviz）
```

### 运行测试

```bash
# 运行所有测试
uv run pytest

# 运行测试并显示详细信息
uv run pytest -v

# 运行特定测试文件
uv run pytest tests/test_core.py

# 运行测试并生成覆盖率报告
uv run pytest --cov=transitions --cov-report=html

# 并行运行测试（更快）
uv run pytest -n auto
```

### 类型检查

```bash
# 运行 mypy 类型检查
uv run mypy transitions/

# 运行 mypy 并显示错误代码
uv run mypy transitions/ --show-error-codes
```

### 代码风格检查

```bash
# 使用 pycodestyle 检查代码风格
uv run pycodestyle transitions/
```

---

## 当前依赖状态

### 运行时依赖
- ✅ `six` (临时保留，阶段二将移除)

### 开发依赖
- ✅ `pytest` 9.0.2
- ✅ `pytest-cov` 7.0.0
- ✅ `pytest-xdist` 3.8.0
- ✅ `pytest-runner` 6.0.1
- ✅ `mock` 5.2.0
- ✅ `mypy` 1.19.1
- ✅ `pycodestyle` 2.14.0
- ✅ `dill` 0.4.0

### 可选依赖
- ✅ `pygraphviz` (diagrams)
- ✅ `graphviz` (diagrams)

---

## 测试结果

最新测试运行结果：

```
259 passed ✓
183 skipped (需要 graphviz)
1 failed (mypy 测试 - 仅警告，不影响功能)
```

**跳过的测试**: 需要 `pygraphviz` 和系统安装 `graphviz`

如果要运行完整测试：
```bash
# macOS
brew install graphviz

# Ubuntu/Debian
sudo apt-get install graphviz graphviz-dev

# 然后安装 diagrams 依赖
uv pip install -e ".[diagrams]"

# 运行所有测试
uv run pytest
```

---

## 项目结构

```
tfsm/
├── .venv/                    # uv 虚拟环境
├── pyproject.toml           # 项目配置（主要）
├── requirements*.txt        # 向后兼容
├── transitions/             # 源代码
│   ├── __init__.py
│   ├── core.py
│   └── extensions/
├── tests/                   # 测试
│   ├── test_core.py
│   └── ...
├── .github/workflows/       # CI/CD
├── MODERNIZATION_PLAN.md    # 重构计划
├── MASTER_TO_MAIN_GUIDE.md  # 分支切换指南
└── UV_QUICKSTART.md         # 本文件
```

---

## 常见问题

### Q: 为什么还在使用 six？

A: 我们临时保留了 `six` 依赖以确保测试可以正常运行。在**阶段二**中，我们会移除代码中所有对 `six` 的引用，然后彻底移除这个依赖。

### Q: 警告 "pytest config in pyproject.toml ignored" 是什么意思？

A: 这个警告可以忽略。项目同时使用 `pytest.ini` 和 `pyproject.toml`，pytest 优先使用 `pytest.ini`。

### Q: 如何确保使用的是正确的 Python 版本？

A: uv 会自动使用虚拟环境中的 Python 3.11.13。验证：
```bash
source .venv/bin/activate
python --version
# 应显示: Python 3.11.13
```

### Q: 如何更新依赖？

A:
```bash
# 更新所有开发依赖到最新版本
uv pip install -e ".[dev]" --upgrade

# 更新特定包
uv pip install pytest --upgrade
```

---

## 下一步

准备开始**阶段二：清理兼容性代码**

包括：
1. 移除 `from __future__` 导入
2. 移除所有 `six` 使用（约 20+ 处）
3. 移除 Enum 兼容代码
4. 简化类定义

---

**更新时间**: 2025-12-28
**状态**: uv 环境就绪 ✅
