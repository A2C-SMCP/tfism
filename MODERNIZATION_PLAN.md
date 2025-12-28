# Python 3.11+ 现代化重构计划

## 概述

本项目将从支持 Python 2.7/3.8+ 升级到 Python 3.11+，并使用现代 Python 包管理工具 `uv` 进行依赖管理。这是一个破坏性更新，将发布为 transitions 1.0。

## 目标

- ✅ 最低 Python 版本: 3.11
- ✅ 使用 `uv` 替代 `pip` 进行依赖管理
- ✅ 采用 `pyproject.toml` 标准配置 (PEP 621)
- ✅ 移除所有 Python 2 兼容性代码
- ✅ 添加完整的类型注解
- ✅ 使用现代 Python 特性提升代码质量

---

## Python 3.11+ 可用的关键新特性

| 特性 | Python 版本 | 用途 |
|------|-------------|------|
| `typing.Self` | 3.11+ | 返回自身类型的方法 |
| `typing.TypeAlias` | 3.10+ | 类型别名注解 |
| `typing.Required/NotRequired` | 3.11+ | TypedDict 的可选/必需字段 |
| `typing.Unpack` | 3.11+ | 解包类型提示 |
| `typing.override` | 3.12+ | 标记重写的方法 |
| `str.removeprefix()/removesuffix()` | 3.9+ | 字符串处理 |
| `tomllib` | 3.11+ | TOML 配置读取 |
| `asyncio.TaskGroup` | 3.11+ | 结构化并发 |
| `dataclass(slots=True)` | 3.10+ | 性能优化 |
| `functools.cache` | 3.9+ | 缓存装饰器 |
| `match/case` | 3.10+ | 模式匹配 |

---

## 分阶段重构计划

### 阶段 1：项目基础设施升级 ✅

#### 1.1 切换到 uv 包管理

**已完成**:
- ✅ 创建 `pyproject.toml` (符合 PEP 621)
- ✅ 配置依赖管理（核心依赖: 无，移除 `six`）
- ✅ 配置可选依赖（diagrams, dev, test, mypy）
- ✅ 配置 uv 开发依赖

**迁移命令**:
```bash
# 安装 uv (如果还没有)
curl -LsSf https://astral.sh/uv/install.sh | sh

# 创建虚拟环境
uv venv --python 3.11

# 激活虚拟环境
source .venv/bin/activate  # Linux/macOS
# 或
.venv\Scripts\activate  # Windows

# 安装开发依赖
uv pip install -e ".[dev]"

# 运行测试
uv run pytest
```

#### 1.2 更新分支结构

**待处理: master → main**

需要手动在 GitHub 上执行以下操作（见下方"GitHub 主分支切换指南"）

---

### 阶段 2：清理兼容性代码

#### 2.1 移除 `__future__` 导入

**文件**: `transitions/__init__.py`

```python
# 删除这一行
from __future__ import absolute_import
```

#### 2.2 移除 `six` 依赖

**影响文件**:
- `transitions/core.py`
- `transitions/extensions/nesting.py`
- `transitions/extensions/markup.py`
- `transitions/extensions/factory.py`

**替换规则**:

```python
# 替换前
from six import string_types
isinstance(x, string_types)

# 替换后
isinstance(x, str)
```

```python
# 替换前
from six import iteritems
for k, v in iteritems(d):

# 替换后
for k, v in d.items():
```

```python
# 替换前
from six.moves import range
range(10)

# 替换后
range(10)  # Python 3 的 range 就是迭代器
```

#### 2.3 移除 Enum 兼容代码

**文件**: `transitions/core.py:16-25`

```python
# 替换前
try:
    from enum import Enum, EnumMeta
except ImportError:
    class Enum: ...
    class EnumMeta: ...

# 替换后
from enum import Enum, EnumMeta
```

#### 2.4 简化类定义

**替换前**:
```python
class State(object):
    ...
```

**替换后**:
```python
class State:
    ...
```

#### 2.5 更新 metaclass 语法

**文件**: `transitions/extensions/diagrams_base.py`

```python
# 替换前
@six.add_metaclass(abc.ABCMeta)
class DiagramBase(object):
    ...

# 替换后
from abc import ABC

class DiagramBase(ABC):
    ...
```

---

### 阶段 3：添加类型注解

#### 3.1 基础类型注解

```python
from typing import Optional, List, Callable, Union, Any
from enum import Enum
from transitions.core import EventData

class State:
    name: Union[str, Enum]
    on_enter: List[Callable[[EventData], Any]]
    on_exit: List[Callable[[EventData], Any]]
    ignore_invalid_triggers: Optional[bool]
    final: bool

    def __init__(
        self,
        name: Union[str, Enum],
        on_enter: Optional[Union[str, List[str]]] = None,
        on_exit: Optional[Union[str, List[str]]] = None,
        ignore_invalid_triggers: Optional[bool] = None,
        final: bool = False
    ):
        ...
```

#### 3.2 使用 `typing.Self` (Python 3.11+)

```python
from typing import Self

class Machine:
    def add_state(self, state: State) -> Self:
        """返回 self 以支持链式调用"""
        ...
        return self
```

#### 3.3 使用 `TypeAlias` (Python 3.10+)

```python
from typing import TypeAlias

StateName: TypeAlias = Union[str, Enum]
Callback: TypeAlias = Callable[[EventData], Any]
CallbackList: TypeAlias = List[Union[str, Callback]]
```

#### 3.4 使用 `override` 装饰器 (Python 3.12+)

```python
from typing import override

class AsyncState(State):
    @override
    def enter(self, event_data: EventData) -> None:
        ...
```

---

### 阶段 4：使用现代 Python 特性

#### 4.1 使用 `dataclass` 重构 State 类

**当前** (transitions/core.py:80-150):
```python
class State:
    def __init__(self, name, on_enter=None, on_exit=None,
                 ignore_invalid_triggers=None, final=False):
        self._name = name
        self.final = final
        self.ignore_invalid_triggers = ignore_invalid_triggers
        self.on_enter = listify(on_enter) if on_enter else []
        self.on_exit = listify(on_exit) if on_exit else []
```

**重构后**:
```python
from dataclasses import dataclass, field
from typing import Self, Optional, Union

@dataclass(slots=True)
class State:
    _name: Union[str, Enum]
    final: bool = False
    ignore_invalid_triggers: Optional[bool] = None
    on_enter: List[Union[str, Callable]] = field(default_factory=list)
    on_exit: List[Union[str, Callable]] = field(default_factory=list)

    def __post_init__(self):
        if not self.on_enter:
            self.on_enter = []
        if not self.on_exit:
            self.on_exit = []
```

**优势**:
- 自动生成 `__init__`, `__repr__`, `__eq__`
- `slots=True` 减少内存占用 (~40%)
- 类型安全
- 更少样板代码

#### 4.2 使用 f-strings

**替换前**:
```python
_LOGGER.debug("%sEntering state %s. Processing callbacks...",
              event_data.machine.name, self.name)
```

**替换后**:
```python
_LOGGER.debug(f"{event_data.machine.name}Entering state {self.name}. Processing callbacks...")
```

#### 4.3 使用 `str.removeprefix/removesuffix`

```python
# 替换前
if s.startswith('prefix_'):
    s = s[7:]

# 替换后
s = s.removeprefix('prefix_')
```

#### 4.4 使用 `functools.cache`

```python
# 替换前
from functools import lru_cache

@lru_cache(maxsize=None)
def resolve_callback(name):
    ...

# 替换后
from functools import cache

@cache
def resolve_callback(name):
    ...
```

#### 4.5 使用 `match/case` 重构条件逻辑

**示例** - transitions/extensions/nesting.py 可能的逻辑:

```python
# 替换前
if state_type == 'nested':
    ...
elif state_type == 'hierarchical':
    ...
elif state_type == 'async':
    ...
else:
    ...

# 替换后
match state_type:
    case 'nested':
        ...
    case 'hierarchical':
        ...
    case 'async':
        ...
    case _:
        ...
```

#### 4.6 使用 `tomllib` 读取配置

如果项目需要读取 TOML 配置:

```python
import tomllib  # Python 3.11+

with open('config.toml', 'rb') as f:
    config = tomllib.load(f)
```

---

### 阶段 5：性能优化

#### 5.1 使用 `__slots__` 优化内存

```python
class State:
    __slots__ = ['_name', 'final', 'ignore_invalid_triggers', 'on_enter', 'on_exit']
```

或使用 `@dataclass(slots=True)` (Python 3.10+)

**收益**:
- 减少对象内存占用 (~40%)
- 提升属性访问速度
- 防止动态添加属性

#### 5.2 使用 `asyncio.TaskGroup` (Python 3.11+)

**文件**: `transitions/extensions/asyncio.py`

```python
import asyncio

async def process_transitions(transitions):
    async with asyncio.TaskGroup() as tg:
        for t in transitions:
            tg.create_task(t.execute())
```

**优势**:
- 结构化并发
- 自动异常传播
- 更清晰的错误处理

---

### 阶段 6：类型检查和 CI/CD

#### 6.1 配置 strict mypy

**文件**: `pyproject.toml` (已配置)

```toml
[tool.mypy]
python_version = "3.11"
warn_return_any = true
warn_unused_configs = true
disallow_untyped_defs = false  # 逐步启用
check_untyped_defs = true
strict_optional = true
```

**运行类型检查**:
```bash
uv run mypy transitions/
```

#### 6.2 更新 CI/CD

**文件**: `.github/workflows/pytest.yml`

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python-version: ["3.11", "3.12", "3.13"]
        extras: ["[diagrams]"]
        include:
          - python-version: "3.13"
            extras: "[]"
          - python-version: "3.13"
            extras: "[diagrams,mypy]"

    steps:
      - uses: actions/checkout@v4
      - name: Set up Python ${{ matrix.python-version }}
        uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
      - name: Install uv
        run: curl -LsSf https://astral.sh/uv/install.sh | sh
      - name: Install dependencies
        run: |
          uv venv --python ${{ matrix.python-version }}
          uv pip install -e ".${{ matrix.extras }}"
```

---

### 阶段 7：文档和测试

#### 7.1 更新 README

- 移除 "Compatible with Python 2.7+" 说明
- 更新为 "Requires Python 3.11+"
- 添加 uv 安装说明

#### 7.2 更新 CHANGELOG

```markdown
# [1.0.0] - 2025-XX-XX

## Breaking Changes

- 最低 Python 版本从 2.7/3.8 提升到 3.11
- 移除 `six` 依赖
- 使用 `uv` 替代 `pip` 进行依赖管理
- 切换到 `pyproject.toml` 配置 (PEP 621)

## Added

- 完整的类型注解支持
- 使用 `dataclass` 重构核心类
- 性能优化（`__slots__`）
- 更严格的类型检查

## Removed

- Python 2.7 支持
- Python 3.8-3.10 支持
- `six` 兼容层
```

#### 7.3 测试覆盖

确保所有新代码都有类型注解和测试：

```bash
# 运行类型检查
uv run mypy transitions/

# 运行测试
uv run pytest --cov=transitions --cov-report=html
```

---

## 预期收益

| 指标 | 当前 | 升级后 | 提升 |
|------|------|--------|------|
| 代码行数 | ~5400 | ~5200 | -3.7% |
| 外部依赖 | 6 | 0 | -100% |
| 类型安全 | 无 | 完整 | ✅ |
| IDE 支持 | ~60% | 95%+ | +58% |
| 内存占用 | 基准 | -40% | ⬇️ |
| 性能 | 基准 | +10-20% | ⬆️ |

---

## 执行时间线

| 阶段 | 预计工作量 | 优先级 |
|------|-----------|--------|
| 阶段 1: 基础设施 | ✅ 已完成 | P0 |
| 阶段 2: 清理兼容性 | 2-3 小时 | P0 |
| 阶段 3: 类型注解 | 4-6 小时 | P0 |
| 阶段 4: 现代特性 | 3-4 小时 | P1 |
| 阶段 5: 性能优化 | 2-3 小时 | P1 |
| 阶段 6: CI/CD | 1 小时 | P0 |
| 阶段 7: 文档 | 2 小时 | P1 |

**总计**: 约 14-19 小时

---

## 风险和缓解措施

### 风险 1: 破坏性变更影响现有用户

**缓解**:
- 发布 major 版本 (1.0.0)
- 提供详细的迁移指南
- 在 README 顶部标注破坏性变更

### 风险 2: 第三方集成兼容性

**缓解**:
- 保持公共 API 不变
- 仅内部实现现代化
- 充分的测试覆盖

### 风险 3: CI/CD 配置错误

**缓解**:
- 逐步迁移，保持现有 CI 正常运行
- 在 feature branch 上测试新配置
- 代码审查

---

## 下一步

立即执行的任务：
1. ✅ 切换到 uv (已完成)
2. ⏳ 切换主分支 master → main
3. ⏳ 执行阶段 2: 清理兼容性代码
4. ⏳ 执行阶段 3: 添加类型注解

---

## 参考资料

- [PEP 621 – Storing project metadata in pyproject.toml](https://peps.python.org/pep-0621/)
- [uv 官方文档](https://github.com/astral-sh/uv)
- [Python 3.11 新特性](https://docs.python.org/3.11/whatsnew/3.11.html)
- [Python 3.12 新特性](https://docs.python.org/3.12/whatsnew/3.12.html)
- [typing 模块文档](https://docs.python.org/3/library/typing.html)
