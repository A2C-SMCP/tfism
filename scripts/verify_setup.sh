#!/bin/bash
# 快速验证 uv 环境和项目状态

set -e

echo "🔍 检查环境..."
echo ""

echo "📌 Python 版本:"
source .venv/bin/activate
python --version
echo ""

echo "📌 uv 版本:"
uv --version
echo ""

echo "📌 当前分支:"
git branch --show-current
echo ""

echo "📌 已安装的关键包:"
uv pip list | grep -E "(transitions|six|pytest|mypy)"
echo ""

echo "🧪 运行基础功能测试..."
python -c "
from transitions import Machine

class Matter:
    pass

model = Matter()
machine = Machine(model=model, states=['solid', 'liquid', 'gas'], initial='solid')
assert model.state == 'solid', 'Initial state should be solid'
model.to_liquid()
assert model.state == 'liquid', 'State should be liquid'
print('✅ 基础状态机功能正常')
"
echo ""

echo "🧪 快速测试套件 (仅核心测试)..."
uv run pytest tests/test_core.py::TestTransitions::test_transitioning -v
echo ""

echo "✅ 环境验证完成！"
echo ""
echo "📖 查看 UV_QUICKSTART.md 了解更多命令"
