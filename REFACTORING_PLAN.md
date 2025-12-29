# 大规模重构计划：AsyncMachine 异步强制封装方案

## 核心原则

**Machine 保持纯粹同步，AsyncMachine 强制异步封装**

1. ✅ Machine 类不添加任何异步方法，保持纯粹同步
2. ✅ AsyncMachine override 核心方法为异步版本（添加 "a" 前缀，下划线方法，在下划线后，单词前添加"a"），并强制异步调用
3. ✅ 提取共享逻辑到私有方法，减少代码重复
4. ✅ AsyncMachine中同步方法抛出明确异常和警告，防止误用
5. ✅ 减少约 60% 的 type ignore
6. ✅ 统一异常消息格式：`"{ClassName}.{method}() is disabled. Use 'await {instance}.{method}(...)' instead."`

## 目标

1. ✅ 解决 AsyncMachine 辅助类的 20+ 个 override 问题（State/Event/Transition）
2. ✅ 保留核心方法的必要 override（dispatch/callbacks/callback 约 7 个）
3. ✅ 统一异步方法命名（加 "a" 前缀），保持 Machine 类完全向后兼容
4. ✅ 清晰的错误提示，防止同步调用异步方法
5. ✅ 减少约 60% 的 type ignore（从 42 个减少到约 15-20 个）

## 重构范围

- tfsm/core.py: 1439 行 -> 预计 +100-200 行（提取共享逻辑）
- tfsm/extensions/asyncio.py: 804 行 -> 预计 -200-300 行（简化辅助类）
- tfsm/extensions/nesting.py: 1435 行 -> 预计 +50-100 行
- **总计**: 3678 行代码，净变化约 -100 行

## 核心策略

### 策略 1：AsyncMachine 异步方法覆盖（约 7 个核心方法）

**核心思想**：AsyncMachine 采用"同步方法抛 RuntimeError + 异步方法加 'a' 前缀"的策略，强制用户使用异步版本

**技术限制**：
- ❌ Python 中同一个类**不能同时定义同名**的同步方法和异步方法
- 异步方法相较于同步方法，添加一个 "a" 前缀
- 同步方法直接override，抛出RuntimeError，因此无法同时提供"同步抛异常版本"和"异步执行版本"

**实际方案**：

**方案 A：同步版本抛 RuntimeError + 异步版本加 "a" 前缀（大多数公共 API 方法）**
```python
class AsyncMachine(Machine):
    def dispatch(self, trigger: str, *args: Any, **kwargs: Any) -> bool:
        raise RuntimeError("AsyncMachine.dispatch() is disabled. Use 'await machine.adispatch(...)' instead.")

    async def adispatch(self, trigger: str, *args: Any, **kwargs: Any) -> bool:
        """Trigger an event on all models assigned to the machine asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await machine.adispatch('event')
                ❌ machine.adispatch('event')  # BUG: Creates coroutine, won't execute!

        If you don't await, you'll get a coroutine object instead of the result.
        """
        results = await self.await_all([partial(getattr(model, trigger), *args, **kwargs) for model in self.models])
        return all(results)

    def callbacks(self, funcs: CallbackList, event_data: EventData) -> None:
        raise RuntimeError("AsyncMachine.callbacks() is disabled. Use 'await machine.acallbacks(...)' instead.")

    async def acallbacks(self, funcs: CallbackList, event_data: EventData) -> None:
        """Triggers a list of callbacks asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        await self.await_all([partial(event_data.machine.callback, func, event_data) for func in funcs])

    def callback(self, func: Callback, event_data: EventData) -> None:
        raise RuntimeError("AsyncMachine.callback() is disabled. Use 'await machine.acallback(...)' instead.")

    async def acallback(self, func: Callback, event_data: EventData) -> None:
        """Trigger a callback function asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        func = self.resolve_callable(func, event_data)
        res = func(event_data) if self.send_event else func(*event_data.args, **event_data.kwargs)
        if inspect.isawaitable(res):
            await res

    def _can_trigger(self, model: Any, trigger: str, *args: Any, **kwargs: Any) -> bool:
        raise RuntimeError("AsyncMachine._can_trigger() is disabled. Use 'await machine._acan_trigger(...)' instead.")

    async def _acan_trigger(self, model: Any, trigger: str, *args: Any, **kwargs: Any) -> bool:
        """Check if an event can be triggered (async).

        ⚠️  CRITICAL: Must be awaited!
        """
        # ... 实现逻辑 ...
```

**方案 B：重命名（少数内部方法）**
```python
class AsyncMachine(Machine):
    # 同步方法：禁用并引导到异步版本
    def _process(self, trigger: Any) -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncMachine!

        ⚠️  Use 'await _aprocess(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncMachine._process() is disabled. Use 'await machine._aprocess(...)' instead."
        )

    # 异步方法：使用不同的名称（在下划线后添加 "a" 前缀）
    async def _aprocess(self, trigger: partial[Any], model: Any) -> bool:
        """Async version of _process.

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...
```

**选择标准**：
- **公共 API 方法**（dispatch, callbacks, callback）：使用方案 A（同步版本抛 RuntimeError + 异步版本加 "a" 前缀）
- **内部方法**（_process, _can_trigger）：使用方案 B（同步抛 RuntimeError + 异步使用 `_a` 前缀）

**关键点**：
- ✅ AsyncMachine 所有核心方法都采用"同步抛 RuntimeError + 异步加 'a' 前缀"策略
- ✅ 文档明确说明"必须使用 await"
- ✅ 同步方法提供清晰的错误消息，引导用户使用异步版本
- ✅ 保留 `# type: ignore[override]` 并添加清晰注释（对于内部方法）

### 策略 2：辅助类异步覆盖（约 15-20 个 override）

**与 AsyncMachine 一样**，AsyncState、AsyncEvent、AsyncTransition 等辅助类也采用"同步抛 RuntimeError + 异步加 'a' 前缀"的策略。

**示例**：同步方法抛 RuntimeError + 异步方法加 "a" 前缀

```python
class AsyncState(State):
    """Async state with async-only transition methods.
    所有状态转换方法（enter/exit）都是异步的。
    """

    # 同步方法：禁用并引导到异步版本
    def enter(self, event_data: "AsyncEventData") -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncState!

        ⚠️  Use 'await aenter(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncState.enter() is disabled. Use 'await state.aenter(...)' instead."
        )

    async def aenter(self, event_data: "AsyncEventData") -> None:
        """Triggered when a state is entered asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        _LOGGER.debug("%sEntering state %s...", event_data.machine.name, self.name)
        await event_data.machine.callbacks(self.on_enter, event_data)
        _LOGGER.info("%sFinished processing state %s enter callbacks.", event_data.machine.name, self.name)

    def exit(self, event_data: "AsyncEventData") -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncState!

        ⚠️  Use 'await aexit(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncState.exit() is disabled. Use 'await state.aexit(...)' instead."
        )

    async def aexit(self, event_data: "AsyncEventData") -> None:
        """Triggered when a state is exited asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        _LOGGER.debug("%sExiting state %s...", event_data.machine.name, self.name)
        await event_data.machine.callbacks(self.on_exit, event_data)
        _LOGGER.info("%sFinished processing state %s exit callbacks.", event_data.machine.name, self.name)

class AsyncEvent(Event):
    """Async event with async-only execution.
    所有事件处理方法（trigger/_trigger/_process）都是异步的。
    """

    def trigger(self, model: Any, *args: Any, **kwargs: Any) -> bool:  # type: ignore[override]
        """Synchronous version is disabled in AsyncEvent!

        ⚠️  Use 'await atrigger(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncEvent.trigger() is disabled. Use 'await event.atrigger(...)' instead."
        )

    async def atrigger(self, model: Any, *args: Any, **kwargs: Any) -> bool:
        """Serially execute all transitions that match the current state asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        func = partial(self._atrigger, EventData(None, self, self.machine, model, args=args, kwargs=kwargs))
        return await self.machine.process_context(func, model)

class AsyncTransition(Transition):
    """Async transition with async-only execution.
    所有转换执行方法（execute/_eval_conditions/_change_state）都是异步的。
    """

    condition_cls = AsyncCondition

    def _eval_conditions(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Synchronous version is disabled in AsyncTransition!

        ⚠️  Use 'await _aeval_conditions(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncTransition._eval_conditions() is disabled. Use 'await transition._aeval_conditions(...)' instead."
        )

    async def _aeval_conditions(self, event_data: EventData) -> bool:
        """Evaluate transition conditions asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        res = await event_data.machine.await_all([partial(cond.check, event_data) for cond in self.conditions])
        if not all(res):
            _LOGGER.debug("%sTransition condition failed.", event_data.machine.name)
            return False
        return True

    def execute(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Synchronous version is disabled in AsyncTransition!

        ⚠️  Use 'await aexecute(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncTransition.execute() is disabled. Use 'await transition.aexecute(...)' instead."
        )

    async def aexecute(self, event_data: EventData) -> bool:
        """Execute the transition asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        _LOGGER.debug("%sInitiating transition from %s to %s...", event_data.machine.name, self.source, self.dest)
        await event_data.machine.callbacks(self.prepare, event_data)

        if not await self._aeval_conditions(event_data):
            return False

        await event_data.machine.cancel_running_transitions(event_data.model)
        await event_data.machine.callbacks(event_data.machine.before_state_change, event_data)
        await event_data.machine.callbacks(self.before, event_data)

        if self.dest is not None:
            await self._achange_state(event_data)

        await event_data.machine.callbacks(self.after, event_data)
        await event_data.machine.callbacks(event_data.machine.after_state_change, event_data)
        return True
```

**关键点**：
- ✅ 所有方法采用"同步抛 RuntimeError + 异步加 'a' 前缀"策略
- ✅ 文档明确说明必须使用 await
- ✅ 保留 `# type: ignore[override]` 并添加清晰注释

# TODO 其它需要处理的 Async 类：
# - NestedAsyncState: 同步版本抛 RuntimeError + 异步版本 ascoped_enter/ascoped_exit
# - NestedAsyncEvent: 同步版本抛 RuntimeError + 异步版本 atrigger_nested/_aprocess
# - NestedAsyncTransition: 同步版本抛 RuntimeError + 异步版本 _achange_state
# - HierarchicalAsyncMachine: 继承自 AsyncMachine
# - AsyncCondition: 同步版本抛 RuntimeError + 异步版本 acheck
# - AsyncTimeout: 同步版本抛 RuntimeError + 异步版本 aenter/aexit/acreate_timer

# 这些类的处理方式与上述类似：同步方法抛 RuntimeError + 异步方法加 "a" 前缀
```

### 策略 3：提取共享逻辑到私有方法

减少 Machine 和 AsyncMachine 之间的代码重复。对于与同步/异步调用无关的可复用逻辑代码，进行适当抽取

## 实施策略

### Phase 1: 提取共享逻辑到私有方法（预计影响 +100-150 行）

**目标**：在 Machine 中提取共享逻辑，减少代码重复

**重构的方法**：

由于 Machine 和 AsyncMachine 的逻辑差异主要在于同步/异步调用，大部分核心逻辑无法直接共享。但可以提取以下与同步/异步无关的辅助逻辑：

```python
# 在 Machine 类中添加：

def _validate_transition_execution(self, event_data: EventData) -> bool:
    """验证转换执行前的条件检查（共享逻辑）"""
    if not self._eval_conditions(event_data):
        return False

    # 取消正在运行的任务（仅 AsyncMachine 需要，但基类可以提供空实现）
    self._cancel_running_transitions_if_needed(event_data.model)
    return True

def _cancel_running_transitions_if_needed(self, model: Any) -> None:
    """取消正在运行的转换（基类空实现，由 AsyncMachine 覆盖）"""
    pass  # 同步版本无需取消任务

def _execute_state_change(self, event_data: EventData) -> None:
    """执行状态变更的共享逻辑"""
    if self.dest is not None:  # 内部转换检查
        self._change_state(event_data)

def _log_transition_execution(self, event_data: EventData, phase: str) -> None:
    """记录转换执行日志"""
    _LOGGER.debug(f"{event_data.machine.name}{phase}")
```

**注意**：由于同步/异步的本质差异，大部分方法无法直接共享。Phase 1 主要关注：
- 日志记录逻辑
- 参数验证逻辑
- 状态名称解析逻辑

**测试验证**：
- 运行所有测试，确保没有破坏现有功能
- 验证私有方法签名正确

### Phase 2: 更新 AsyncMachine 核心方法（预计影响 -50 行）

**目标**：简化 AsyncMachine 的核心方法，确保所有异步方法都有清晰的文档说明

**技术限制说明**：
由于 Python 中同一个类不能同时定义同名的方法（后定义会覆盖前面的），我们采用以下两种方案：

**重构后**：

```python
class AsyncMachine(Machine):
    """Asynchronous state machine with async-only methods.

    ⚠️  CRITICAL:
        All methods are async and MUST be awaited.
        Forgetting to await will create coroutine objects (silent bugs).
    """

    # 方案 A：同步版本抛 RuntimeError + 异步版本加 "a" 前缀（大多数公共 API 方法）
    def dispatch(self, trigger: str, *args: Any, **kwargs: Any) -> bool:
        """Synchronous version is disabled in AsyncMachine!

        ⚠️  Use 'await adispatch(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncMachine.dispatch() is disabled. Use 'await machine.adispatch(...)' instead."
        )

    async def adispatch(self, trigger: str, *args: Any, **kwargs: Any) -> bool:
        """Trigger an event on all models assigned to the machine asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await machine.adispatch('event')
                ❌ machine.adispatch('event')  # BUG: Creates coroutine, won't execute!

        If you don't await, you'll get a coroutine object instead of the result.

        Args:
            trigger: Event name
            *args: Arguments passed to the event trigger
            **kwargs: Keyword arguments passed to the event trigger

        Returns:
            bool: The truth value of all triggers combined with AND
        """
        results = await self.await_all([partial(getattr(model, trigger), *args, **kwargs) for model in self.models])
        return all(results)

    def callbacks(self, funcs: CallbackList, event_data: EventData) -> None:
        """Synchronous version is disabled in AsyncMachine!

        ⚠️  Use 'await acallbacks(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncMachine.callbacks() is disabled. Use 'await machine.acallbacks(...)' instead."
        )

    async def acallbacks(self, funcs: CallbackList, event_data: EventData) -> None:
        """Triggers a list of callbacks asynchronously.

        ⚠️  CRITICAL: Must be awaited: await machine.acallbacks(...)
        """
        await self.await_all([partial(event_data.machine.callback, func, event_data) for func in funcs])

    def callback(self, func: Callback, event_data: EventData) -> None:
        """Synchronous version is disabled in AsyncMachine!

        ⚠️  Use 'await acallback(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncMachine.callback() is disabled. Use 'await machine.acallback(...)' instead."
        )

    async def acallback(self, func: Callback, event_data: EventData) -> None:
        """Trigger a callback function asynchronously.

        ⚠️  CRITICAL: Must be awaited: await machine.acallback(...)

        Automatically awaits awaitable results from callbacks.
        """
        func = self.resolve_callable(func, event_data)
        res = func(event_data) if self.send_event else func(*event_data.args, **event_data.kwargs)
        if inspect.isawaitable(res):
            await res

    def _can_trigger(self, model: Any, trigger: str, *args: Any, **kwargs: Any) -> bool:
        """Synchronous version is disabled in AsyncMachine!

        ⚠️  Use 'await _acan_trigger(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncMachine._can_trigger() is disabled. Use 'await machine._acan_trigger(...)' instead."
        )

    async def _acan_trigger(self, model: Any, trigger: str, *args: Any, **kwargs: Any) -> bool:
        """Check if an event can be triggered asynchronously.

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...

    # 方案 B：重命名（少数内部方法，需要明确区分）
    def _process(self, trigger: Any) -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncMachine!

        ⚠️  Use 'await _aprocess(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncMachine._process() is disabled. Use 'await machine._aprocess(...)' instead."
        )

    async def _aprocess(self, trigger: partial[Any], model: Any) -> bool:
        """Async version of _process.

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...
```

**关键改进**：
- ✅ 公共 API 方法（dispatch, callbacks, callback）采用"同步版本抛 RuntimeError + 异步版本加 'a' 前缀"策略
- ✅ 内部方法（_process）采用重命名方案（同步抛 RuntimeError + 异步使用 `_aprocess`）
- ✅ 所有异步方法都有清晰的文档说明必须使用 await
- ✅ 保留 `# type: ignore[override]` 并添加注释说明这是故意的 LSP 违反
- ✅ 提供正确和错误用法的示例

**测试验证**：
- 运行所有异步测试
- 验证文档示例可以正确执行
- 确保性能没有退化

### Phase 3: 更新辅助类文档和实现（预计影响 -100-150 行）

**目标**：为所有辅助类（AsyncState/AsyncEvent/AsyncTransition）添加清晰的异步使用文档

**更新策略**：

1. **AsyncState**：

```python
class AsyncState(State):
    """Async state with async-only transition methods.

    ⚠️  IMPORTANT:
        All state transition methods (enter/exit) are async and MUST be awaited.
        Forgetting to await will create coroutine objects instead of executing.
    """

    # 同步方法：禁用并引导到异步版本
    def enter(self, event_data: "AsyncEventData") -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncState!

        ⚠️  Use 'await aenter(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncState.enter() is disabled. Use 'await state.aenter(...)' instead."
        )

    # 异步方法：添加 "a" 前缀
    async def aenter(self, event_data: "AsyncEventData") -> None:
        """Triggered when a state is entered asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await state.aenter(event_data)
                ❌ state.aenter(event_data)  # BUG: Creates coroutine, won't execute!

        Args:
            event_data: (AsyncEventData): The currently processed event.
        """
        _LOGGER.debug("%sEntering state %s. Processing callbacks...", event_data.machine.name, self.name)
        await event_data.machine.callbacks(self.on_enter, event_data)
        _LOGGER.info("%sFinished processing state %s enter callbacks.", event_data.machine.name, self.name)

    # 同步方法：禁用并引导到异步版本
    def exit(self, event_data: "AsyncEventData") -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncState!

        ⚠️  Use 'await aexit(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncState.exit() is disabled. Use 'await state.aexit(...)' instead."
        )

    # 异步方法：添加 "a" 前缀
    async def aexit(self, event_data: "AsyncEventData") -> None:
        """Triggered when a state is exited asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await state.aexit(event_data)
                ❌ state.aexit(event_data)  # BUG: Creates coroutine, won't execute!

        Args:
            event_data: (AsyncEventData): The currently processed event.
        """
        _LOGGER.debug("%sExiting state %s. Processing callbacks...", event_data.machine.name, self.name)
        await event_data.machine.callbacks(self.on_exit, event_data)
        _LOGGER.info("%sFinished processing state %s exit callbacks.", event_data.machine.name, self.name)
```

2. **AsyncEvent**：

```python
class AsyncEvent(Event):
    """Async event with async-only execution methods.

    ⚠️  IMPORTANT:
        All event processing methods (trigger/_trigger/_process) are async and MUST be awaited.
    """

    # 同步方法：禁用并引导到异步版本
    def trigger(self, model: Any, *args: Any, **kwargs: Any) -> bool:  # type: ignore[override]
        """Synchronous version is disabled in AsyncEvent!

        ⚠️  Use 'await atrigger(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncEvent.trigger() is disabled. Use 'await event.atrigger(...)' instead."
        )

    # 异步方法：添加 "a" 前缀
    async def atrigger(self, model: Any, *args: Any, **kwargs: Any) -> bool:
        """Serially execute all transitions that match the current state asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await event.atrigger(...)
                ❌ event.atrigger(...)  # BUG: Creates coroutine, won't execute!

        Returns:
            bool: True if a transition was successfully executed
        """
        func = partial(self._atrigger, EventData(None, self, self.machine, model, args=args, kwargs=kwargs))
        return await self.machine.process_context(func, model)

    def _trigger(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Synchronous version is disabled in AsyncEvent!

        ⚠️  Use 'await _atrigger(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncEvent._trigger() is disabled. Use 'await event._atrigger(...)' instead."
        )

    async def _atrigger(self, event_data: EventData) -> bool:
        """Internal trigger function (async).

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...

    def _process(self, event_data: EventData) -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncEvent!

        ⚠️  Use 'await _aprocess(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncEvent._process() is disabled. Use 'await event._aprocess(...)' instead."
        )

    async def _aprocess(self, event_data: EventData) -> None:
        """Process event transitions (async).

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...
```

3. **AsyncTransition**：

```python
class AsyncTransition(Transition):
    """Async transition with async-only execution methods.

    ⚠️  IMPORTANT:
        All transition methods (execute/_eval_conditions/_change_state) are async and MUST be awaited.
    """

    condition_cls = AsyncCondition

    # 同步方法：禁用并引导到异步版本
    def _eval_conditions(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Synchronous version is disabled in AsyncTransition!

        ⚠️  Use 'await _aeval_conditions(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncTransition._eval_conditions() is disabled. Use 'await transition._aeval_conditions(...)' instead."
        )

    # 异步方法：在下划线后添加 "a" 前缀
    async def _aeval_conditions(self, event_data: EventData) -> bool:
        """Evaluate transition conditions asynchronously.

        ⚠️  CRITICAL: Must be awaited.
        """
        res = await event_data.machine.await_all([partial(cond.check, event_data) for cond in self.conditions])
        if not all(res):
            _LOGGER.debug("%sTransition condition failed: Transition halted.", event_data.machine.name)
            return False
        return True

    def execute(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Synchronous version is disabled in AsyncTransition!

        ⚠️  Use 'await aexecute(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncTransition.execute() is disabled. Use 'await transition.aexecute(...)' instead."
        )

    # 异步方法：添加 "a" 前缀
    async def aexecute(self, event_data: EventData) -> bool:
        """Execute the transition asynchronously.

        ⚠️  CRITICAL: Must be awaited.

        Returns:
            bool: True if transition was successful, False otherwise
        """
        _LOGGER.debug("%sInitiating transition from %s to %s...", event_data.machine.name, self.source, self.dest)
        await event_data.machine.callbacks(self.prepare, event_data)

        if not await self._aeval_conditions(event_data):
            return False

        await event_data.machine.cancel_running_transitions(event_data.model)
        await event_data.machine.callbacks(event_data.machine.before_state_change, event_data)
        await event_data.machine.callbacks(self.before, event_data)

        if self.dest is not None:
            await self._achange_state(event_data)

        await event_data.machine.callbacks(self.after, event_data)
        await event_data.machine.callbacks(event_data.machine.after_state_change, event_data)
        return True

    def _change_state(self, event_data: EventData) -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncTransition!

        ⚠️  Use 'await _achange_state(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncTransition._change_state() is disabled. Use 'await transition._achange_state(...)' instead."
        )

    async def _achange_state(self, event_data: EventData) -> None:
        """Change state asynchronously.

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...
```

**预期变化**：
- 所有辅助类采用"同步抛 RuntimeError + 异步加 'a' 前缀"策略
- 统一添加清晰的异步使用文档
- 保留必要的 `# type: ignore[override]` 注释

**测试验证**：
- 运行所有异步测试
- 验证状态转换正常工作
- 检查日志输出正确

### Phase 4: 更新模块和类级文档（预计影响 +50 行）

**目标**：在模块和类级别添加清晰的文档，说明异步强制策略

**1. 模块级文档（tfsm/extensions/asyncio.py）**：

```python
"""
tfsm.extensions.asyncio
------------------------------

Asynchronous state machine implementation with async-only enforcement.

This module contains asynchronous variants of the core tfsm classes:
- AsyncMachine: Async-only state machine with enforced async methods
- AsyncState: Async-only state with enforced async callbacks
- AsyncEvent: Async-only event handling
- AsyncTransition: Async-only transition execution
- HierarchicalAsyncMachine: Hierarchical async state machine

⚠️ CRITICAL DESIGN DECISION:

All async classes in this module follow an **async-only enforcement strategy**:
1. Synchronous methods inherited from parent classes are DISABLED
2. Calling a synchronous method will raise RuntimeError immediately
3. All methods MUST be awaited in async contexts
4. Forgetting to await will create coroutine objects (silent bugs)

Example (AsyncMachine):

    ✅ CORRECT:
        machine = AsyncMachine(states=['A', 'B'], initial='A')
        await machine.advance()  # Async execution

    ❌ WRONG - returns coroutine without executing:
        machine.advance()  # BUG: Creates coroutine, doesn't execute!

    ❌ WRONG - raises RuntimeError:
        # Sync methods are disabled and will raise immediately
        # (This is intentional to prevent silent bugs)

This design deliberately violates Liskov Substitution Principle (LSP) for good reason:
- Prevents hard-to-debug bugs from missing awaits
- Forces explicit async usage
- Provides clear error messages for incorrect usage
- Maintains type safety with type: ignore[override] comments

The alternative (allowing both sync and async) would lead to:
- Silent bugs from forgotten awaits
- Confusion about when to use sync vs async
- Difficult-to-trace coroutine objects in code

For hierarchical state machines, see HierarchicalAsyncMachine.
For timeout functionality, see AsyncTimeout.

This module uses `asyncio` for concurrency. The extension `tfsm-anyio`
illustrates how they can be extended to make use of other concurrency libraries.

Note: Overriding base methods with async variants is not considered good practice
in general. However, the alternative would mean either increasing the complexity
of the base classes or copying code fragments, which would increase code
complexity and reduce maintainability. If you know a better solution, please
file an issue.
"""
```

**2. 类级文档示例**：

```python
class AsyncMachine(Machine):
    """Asynchronous state machine with enforced async-only methods.

    AsyncMachine is a pure async state machine implementation that enforces
    async usage by disabling all synchronous methods inherited from Machine.

    ⚠️ ASYNC-ONLY ENFORCEMENT:

    This class deliberately violates Liskov Substitution Principle (LSP) to prevent
    hard-to-debug bugs. All synchronous methods from Machine are DISABLED and will
    raise RuntimeError if called.

    CRITICAL RULES:
        1. All methods MUST be awaited
        2. Forgetting await creates coroutine objects (silent bugs)
        3. Sync methods raise RuntimeError immediately
        4. Use only in async contexts

    Example:
        >>> # ✅ CORRECT - Async usage
        >>> machine = AsyncMachine(states=['A', 'B'], initial='A')
        >>> await machine.advance()  # Returns bool, executes transition

        >>> # ❌ WRONG - Missing await (creates coroutine)
        >>> machine.advance()  # Returns <coroutine>, doesn't execute!

        >>> # ❌ WRONG - Sync method raises RuntimeError
        >>> # (sync methods are intentionally disabled)

    Attributes:
        states (OrderedDict): Collection of all registered states.
        events (dict): Collection of events ordered by trigger/event.
        models (list): List of models attached to the machine.
        initial (str): Name of the initial state for new models.
        prepare_event (list): Callbacks executed when an event is triggered (async).
        before_state_change (list): Callbacks executed after condition checks but before transition (async).
        after_state_change (list): Callbacks executed after the transition (async).
        finalize_event (list): Callbacks executed after all events have been processed (async).
        on_exception: A callable called when an event raises an exception (async).
        queued (bool or str): Whether events should be executed immediately or sequentially.
        send_event (bool): When True, arguments are wrapped in EventData objects.
        auto_transitions (bool):  When True (default), auto-generates to_{state}() methods.
        ignore_invalid_triggers (bool): When True, invalid triggers are silently ignored.
        name (str): Name of the machine instance for log messages.

    Type Safety:
        This class uses `# type: ignore[override]` comments to intentionally suppress
        mypy errors about LSP violations. This is documented and intentional.

    Performance:
        AsyncMachine uses asyncio.gather() for parallel callback execution, which
        may have different performance characteristics than the synchronous Machine.
    """

    state_cls = AsyncState
    transition_cls = AsyncTransition
    event_cls = AsyncEvent
    async_tasks: dict[int, list["asyncio.Task[Any]"]] = {}
    protected_tasks: list["asyncio.Task[Any]"] = []
    current_context: contextvars.ContextVar[Optional["asyncio.Task[Any]"]] = contextvars.ContextVar("current_context", default=None)
```

**预期变化**：
- 模块文档明确说明异步强制策略和设计理由
- 所有异步类都有清晰的类级文档说明
- 提供正确和错误用法的示例
- 说明 type: ignore[override] 的必要性

**测试验证**：
- 文档示例可以正确执行
- 用户能清楚理解同步/异步的区别

### Phase 5: 清理和优化（预计影响 -50 行）

**目标**：移除不再需要的代码，优化性能

**清理项**：
1. 移除未使用的辅助函数
2. 统一代码风格
3. 优化异步执行性能
4. 移除过时的 TODO 注释

**测试验证**：
- 运行完整测试套件
- 性能基准测试
- 类型检查（mypy）

### Phase 6: 测试用例重构（预计影响 +200-300 行）

**目标**：修改所有测试用例，确保 3214 个测试全部通过，并添加新测试覆盖新功能

**重要原则**：
1. ✅ **3214 个测试一个不能少** - 只能修改，不能删除
2. ✅ **100% 功能覆盖率** - 所有现有功能必须被测试
3. ✅ **添加新测试** - 覆盖新能力（RuntimeError 检测等）

**详细策略**：参见本文档"测试覆盖"部分的 Phase 6（第 1042-1280 行）

**关键修改点**：
1. 修改 `tests/test_async.py` 中的异步方法调用
2. 修改 `tests/test_nesting.py` 中的异步方法调用
3. 添加 RuntimeError 检测测试（50-100 个新测试）
4. 更新 `machine.callbacks` → `machine.acallbacks`
5. 更新 `machine.callback` → `machine.acallback`
6. 更新 `machine.dispatch` → `machine.adispatch`（如果直接调用）

**测试验证**：
- 运行完整测试套件，确保 3214 个测试全部通过
- 对比重构前后的测试覆盖率
- 性能基准测试，确保无退化
- mypy 类型检查通过

## 预期结果

### 代码质量改进

| 指标 | 重构前 | 重构后 | 改进 |
|------|--------|--------|------|
| type: ignore 数量 | ~42 个 | ~15-20 个 | ↓ 50-60% |
| 异步辅助类 override | 20+ 个 | 7 个核心方法 | ↓ 65% |
| 代码行数（asyncio.py） | 804 行 | ~650-700 行 | ↓ 100-150 行 |
| 文档覆盖率 | 60% | 95% | ↑ 35% |
| 测试用例数量 | 3214 个 | ~3264-3314 个 | ↑ 50-100 个 |

### 类型安全改进

**重构前的问题**：
- 42 个 `# type: ignore[override]` 分散在整个文件
- 难以区分哪些 override 是必要的，哪些是设计缺陷
- mypy 警告被批量忽略，可能掩盖真实问题

**重构后的改进**：
- 仅保留 15-20 个必要的 `# type: ignore[override]`（故意违反 LSP）
- 每个 type ignore 都有清晰的注释说明原因
- 同步方法直接抛出 RuntimeError，防止误用
- 类型检查更加严格，减少误报

### 可维护性改进

**文档改进**：
- ✅ 模块级文档清晰说明异步强制策略
- ✅ 所有异步类都有"同步版本已禁用"的警告
- ✅ 提供正确和错误用法的对比示例
- ✅ 解释 LSP 违反的设计理由

**代码结构改进**：
- ✅ 清晰的类级文档说明设计决策
- ✅ 一致的错误消息格式
- ✅ 明确的方法命名约定（同步方法抛异常，异步方法实际工作）

### 用户体验改进

**错误提示改进**：

重构前：
```python
# 用户忘记 await，得到 coroutine 对象（静默 bug）
result = machine.dispatch('event')  # 返回 <coroutine>
if result:  # 总是 True，因为 coroutine 对象是 truthy
    print("Transition succeeded")  # 永远执行，即使转换失败
```

重构后：
```python
# 用户调用同步方法，立即得到明确的错误
machine.dispatch('event')  # 抛出 RuntimeError
# RuntimeError: AsyncMachine.dispatch() is disabled. Use 'await machine.adispatch(...)' instead.
```

**使用示例改进**：

```python
# ✅ 清晰的正确用法示例
async def main():
    machine = AsyncMachine(states=['A', 'B'], initial='A')
    result = await machine.adispatch('advance')  # 明确的 async 用法（加 "a" 前缀）
    print(f"Transition result: {result}")  # bool 值

# ❌ 明确的错误用法示例（会抛出异常）
def wrong_example():
    machine = AsyncMachine(states=['A', 'B'], initial='A')
    machine.dispatch('advance')  # 立即抛出 RuntimeError
```

### 性能影响

**预期性能变化**：
- 运行时性能：无明显影响（仅增加少量类型检查）
- 首次导入时间：+1-2%（增加了文档和辅助方法）
- 内存占用：无明显变化
- 异步执行性能：无变化（保持 asyncio.gather 的并发能力）

### 向后兼容性

**破坏性变化**：
- ❌ 同步方法会抛 RuntimeError（防止误用）
- ❌ 异步方法名称改变（加 "a" 前缀）：`dispatch` → `adispatch`, `callbacks` → `acallbacks`, etc.
- ⚠️ 需要更新所有 AsyncMachine 相关代码

**迁移指南**：

旧代码（可能有 bug）：
```python
# 如果用户忘记 await，之前会创建 coroutine（静默 bug）
machine = AsyncMachine(...)
result = machine.dispatch('event')  # 旧版本：返回 coroutine
```

新代码（强制正确）：
```python
# 现在必须使用 await + 加 "a" 前缀的异步方法
machine = AsyncMachine(...)
result = await machine.adispatch('event')  # 正确用法
```

**兼容性保证**：
- ❌ **所有使用 AsyncMachine 的代码都需要修改**（方法名加 "a" 前缀）
- ✅ 所有使用 Machine 的代码无需修改（保持纯粹同步）
- ✅ 同步方法抛 RuntimeError，帮助发现需要修改的地方

### 测试覆盖

**当前测试情况**：

经过代码调研，当前测试分布如下：
- **总测试数**：3214 个测试用例（pytest collection）
- **核心测试文件**：
  - `tests/test_core.py`: 71 个测试方法，Machine 类的核心测试
  - `tests/test_async.py`: 34 个测试方法（继承 TestTransitions），AsyncMachine 的测试
  - `tests/test_nesting.py`: 48 个测试方法，嵌套状态机的测试
  - `core + async + nesting`: 714 个测试用例（包含参数化测试）
- **测试继承结构**：
  - `TestAsync` 继承自 `TestTransitions`（在 test_core.py 中定义）
  - `TestAsync` 通过 `self.machine_cls = AsyncMachine` 覆盖父类设置
  - 因此 TestAsync 会运行所有 TestTransitions 的测试，但使用 AsyncMachine

**当前 AsyncMachine 的方法覆盖**（需要重构）：

1. **AsyncMachine 类**（tfsm/extensions/asyncio.py 第 272 行）：
   - `async def dispatch(...)` - 第 368 行
   - `async def callbacks(...)` - 第 381 行
   - `async def callback(...)` - 第 386 行
   - `async def _can_trigger(...)` - 第 500 行
   - `def _process(...)` - 第 527 行（抛 RuntimeError）
   - `async def _process_async(...)` - 第 530 行

2. **辅助类**：
   - **AsyncState**: `async def enter(...)`, `async def exit(...)`
   - **NestedAsyncState**: `async def scoped_enter(...)`, `async def scoped_exit(...)`
   - **AsyncEvent**: `async def trigger(...)`, `async def _trigger(...)`, `async def _process(...)`
   - **NestedAsyncEvent**: `async def trigger_nested(...)`, `async def _process(...)`
   - **AsyncTransition**: `async def _eval_conditions(...)`, `async def execute(...)`, `async def _change_state(...)`
   - **AsyncCondition**: `async def check(...)`

**测试用例修改策略**：

### Phase 6: 测试用例重构（关键！）

**原则**：
1. ✅ **3214 个测试一个不能少** - 功能测试用例只能改不能删
2. ✅ **保持 100% 功能覆盖率** - 所有现有功能必须被测试覆盖
3. ✅ **添加新测试** - 覆盖新能力（RuntimeError 检测、新方法名等）
4. ⚠️ **方法名修改** - 由于重构涉及方法名变化，测试代码需要相应修改

#### 6.1 测试用例修改范围

**需要修改的测试文件**：
1. `tests/test_async.py` - 直接使用 AsyncMachine 的测试
2. `tests/test_nesting.py` - 使用 HierarchicalAsyncMachine 的测试
3. 其他间接使用 AsyncMachine 的测试文件

**不需要修改的测试文件**：
- `tests/test_core.py` - 仅使用 Machine，无需修改
- 其他仅使用同步 Machine 的测试

#### 6.2 方法名映射表

测试代码需要将以下方法调用更新为新的异步方法名（加 "a" 前缀）：

| 旧方法名 | 新方法名 | 影响范围 |
|---------|---------|---------|
| `machine.dispatch(event)` | `await machine.adispatch(event)` | 高频使用 |
| `machine.callbacks(...)` | `await machine.acallbacks(...)` | 内部调用 |
| `machine.callback(...)` | `await machine.acallback(...)` | 内部调用 |
| `machine._can_trigger(...)` | `await machine._acan_trigger(...)` | 内部调用 |
| `machine._process(...)` | `await machine._aprocess(...)` | 内部调用 |
| `state.enter(...)` | `await state.aenter(...)` | 内部调用 |
| `state.exit(...)` | `await state.aexit(...)` | 内部调用 |
| `event.trigger(...)` | `await event.atrigger(...)` | 内部调用 |
| `transition.execute(...)` | `await transition.aexecute(...)` | 内部调用 |
| `transition._eval_conditions(...)` | `await transition._aeval_conditions(...)` | 内部调用 |
| `transition._change_state(...)` | `await transition._achange_state(...)` | 内部调用 |

**不需要修改的方法**（查询方法，保持同步）：
- `machine.is_A()`, `machine.is_B()` 等 - 状态查询方法
- `machine.get_state(...)` - 获取状态实例
- `machine.add_model(...)` - 添加模型
- `machine.add_transition(...)` - 添加转换
- 其他配置方法

#### 6.3 测试修改模式

**模式 1：直接调用的异步方法**
```python
# 旧代码
asyncio.run(machine.go())
asyncio.run(machine.to_B())
asyncio.run(machine.dispatch("go"))

# 新代码（需要根据实际情况判断是否需要改）
# 如果这些方法最终调用了 dispatch，可能需要更新
# 具体取决于是否生成 to_X 方法使用了异步 dispatch
```

**模式 2：内部方法调用**
```python
# 旧代码（在测试回调中）
async def on_enter(event_data):
    await event_data.machine.callbacks(...)  # 需要改为 acallbacks

# 新代码
async def on_enter(event_data):
    await event_data.machine.acallbacks(...)
```

**模式 3：新增 RuntimeError 测试**
```python
# 新增：验证同步方法抛出 RuntimeError
def test_sync_dispatch_raises_error(self):
    machine = AsyncMachine(states=["A", "B"], initial="A")
    with self.assertRaises(RuntimeError) as cm:
        machine.dispatch("go")
    self.assertIn("disabled", str(cm.exception))
    self.assertIn("adispatch", str(cm.exception))
```

#### 6.4 测试迁移步骤

**Step 1: 准备阶段**
1. 创建 `tests/test_async_refactor.py` 作为新测试的临时文件
2. 运行完整测试套件，记录当前通过数量（3214 个）

**Step 2: 逐步修改**
1. **先修改内部方法调用**（callbacks, callback 等）：
   - 全局搜索替换 `machine.callbacks` → `machine.acallbacks`
   - 全局搜索替换 `machine.callback` → `machine.acallback`
   - 运行测试，记录失败数量

2. **再修改公共 API 方法**（dispatch 等）：
   - 逐个文件检查 `machine.dispatch` 的使用
   - 根据实际情况更新为 `await machine.adispatch`
   - 运行测试，记录失败数量

3. **修改辅助类方法**（如果测试直接调用）：
   - `state.enter` → `await state.aenter`
   - `state.exit` → `await state.aexit`
   - 运行测试，记录失败数量

**Step 3: 添加新测试**
1. 添加 RuntimeError 检测测试（所有被禁用的同步方法）
2. 添加新方法名功能测试
3. 添加错误消息格式测试

**Step 4: 验证与修复**
1. 运行完整测试套件，确保 3214 个测试全部通过
2. 对比重构前后的测试覆盖率
3. 性能基准测试，确保无退化

#### 6.5 新增测试清单

**必须添加的测试**：

1. **RuntimeError 检测测试**（针对每个被禁用的同步方法）：
   - [ ] `test_sync_dispatch_raises_runtime_error`
   - [ ] `test_sync_callbacks_raises_runtime_error`
   - [ ] `test_sync_callback_raises_runtime_error`
   - [ ] `test_sync_can_trigger_raises_runtime_error`
   - [ ] `test_sync_process_raises_runtime_error`
   - [ ] `test_sync_state_enter_raises_runtime_error`
   - [ ] `test_sync_state_exit_raises_runtime_error`
   - [ ] `test_sync_event_trigger_raises_runtime_error`
   - [ ] `test_sync_transition_execute_raises_runtime_error`

2. **新异步方法功能测试**：
   - [ ] `test_async_dispatch_functionality`
   - [ ] `test_async_callbacks_functionality`
   - [ ] `test_async_callback_functionality`
   - [ ] `test_async_can_trigger_functionality`
   - [ ] `test_async_process_functionality`

3. **错误消息格式测试**：
   - [ ] `test_error_message_format_sync_methods`
   - [ ] `test_error_message_includes_async_method_name`

4. **边界情况测试**：
   - [ ] `test_mixed_sync_and_async_callbacks`
   - [ ] `test_nested_async_transitions`
   - [ ] `test_async_exception_handling`

**预估新增测试数量**：50-100 个新测试用例

#### 6.6 测试失败处理预案

**常见失败场景**：

1. **方法名未更新**：
   - 症状：AttributeError: 'AsyncMachine' object has no attribute 'dispatch'
   - 解决：更新为 `adispatch`

2. **忘记 await**：
   - 症状：coroutine was never awaited
   - 解决：在异步方法调用前添加 `await`

3. **同步方法抛 RuntimeError**：
   - 症状：RuntimeError: AsyncMachine.dispatch() is disabled
   - 解决：这是预期行为，更新测试以验证 RuntimeError

4. **类型不匹配**：
   - 症状：Type error 或 mypy 错误
   - 解决：添加适当的类型注解或 type ignore

**回滚策略**：
- 每个步骤后提交代码，便于回滚
- 保留原测试文件作为参考
- 使用 Git 分支隔离重构工作

#### 6.7 测试覆盖验证

**验证脚本**：
```python
# scripts/verify_test_coverage.py
import subprocess
import sys

def run_tests():
    result = subprocess.run(
        ["uv", "run", "pytest", "tests/", "-v", "--tb=short"],
        capture_output=True,
        text=True
    )
    print(result.stdout)
    print(result.stderr)

    # 检查测试数量
    if "3214 tests collected" not in result.stdout:
        print("ERROR: Test count mismatch!")
        sys.exit(1)

    # 检查是否全部通过
    if result.returncode != 0:
        print("ERROR: Some tests failed!")
        sys.exit(1)

    print("SUCCESS: All 3214 tests passed!")
    sys.exit(0)

if __name__ == "__main__":
    run_tests()
```

**测试验证清单**：
- [ ] 所有现有 3214 个测试通过
- [ ] 新增测试全部通过
- [ ] 测试覆盖率报告显示覆盖率未降低
- [ ] mypy 类型检查通过
- [ ] 性能基准测试无退化

**风险警告**：

⚠️ **高风险区域**：
1. **auto_transitions 生成的触发器方法**（如 `to_B`, `to_C`）：
   - 这些方法可能是同步的，最终调用 `dispatch`
   - 如果 `dispatch` 改为 `adispatch`，需要确保生成的方法也相应更新
   - **必须彻底测试所有自动生成的触发器方法**

2. **模型方法装饰**：
   - AsyncMachine 会为模型添加触发器方法
   - 需要确保这些动态生成的方法正确调用异步版本

3. **回调链中的异步调用**：
   - 复杂的回调链可能包含多个异步调用
   - 需要确保整个链条都正确使用 await

4. **嵌套状态机**：
   - HierarchicalAsyncMachine 有额外的异步覆盖
   - 需要特别关注嵌套场景的测试

**缓解措施**：
1. 在重构前运行完整测试套件，记录基线
2. 使用增量重构策略，每次只修改一个方法
3. 每次修改后立即运行相关测试
4. 保留详细的测试失败日志
5. 在单独的分支中进行重构，确保可以快速回滚

### 风险评估

**高风险**：
- ⚠️ **测试用例大规模修改**：AsyncMachine 的方法名全部改变，需要修改所有相关测试
- ⚠️ **auto_transitions 生成的触发器方法**：需要确保 `to_B` 等方法正确调用异步版本
- ⚠️ **用户代码破坏性变化**：所有使用 AsyncMachine 的代码都需要修改
- ⚠️ **3214 个测试必须全部通过**：不能有任何一个测试失败或删除

**中风险**：
- ⚠️ 动态生成的方法（模型装饰）可能需要特殊处理
- ⚠️ 复杂的回调链可能包含隐藏的异步调用
- ⚠️ 嵌套状态机的额外异步覆盖需要仔细测试

**低风险**：
- ✅ 所有改动都在 asyncio 模块内，不影响核心 Machine
- ✅ Machine 类的测试无需修改（约 2000+ 个测试）
- ✅ 同步方法抛 RuntimeError 有明确的错误消息

**缓解措施**：
1. **测试优先策略**：
   - 先重构测试用例，确保测试能验证新功能
   - 每个代码修改立即运行测试验证
   - 保留原测试文件作为参考

2. **增量重构策略**：
   - 按方法逐个重构，而非一次性全部修改
   - 每完成一个方法的重构，立即运行完整测试套件
   - 使用 Git 分支隔离，便于回滚

3. **文档与迁移支持**：
   - 在 CHANGELOG 中明确说明破坏性变化
   - 提供详细的迁移指南和示例
   - 添加自动化迁移脚本（如果可能）

4. **用户沟通**：
   - 提前发布公告，说明即将发生的破坏性变化
   - 提供预发布版本供用户测试
   - 设置迁移反馈渠道

### 后续改进方向

重构完成后，可以考虑以下改进：

1. **泛型类型分离**（长期目标）：
   - 使用 Protocol 区分 SyncMachine 和 AsyncMachine
   - 完全消除 type ignore，但需要更大的架构改动

2. **静态分析工具**：
   - 开发自定义 mypy 插件检测 await 漏用
   - 在静态分析阶段发现问题

3. **运行时检查**：
   - 在 debug 模式下添加额外的 await 检测
   - 使用协程追踪技术发现未 awaited 的 coroutine

### 总结

这次重构通过"异步强制封装"策略，显著提升了代码质量、可维护性和用户体验：

- ✅ 减少 50-60% 的 type ignore，提高类型安全性
- ✅ 清晰的文档和错误消息，降低学习曲线
- ✅ 运行时错误检测，防止静默 bug
- ✅ 统一异步方法命名（加 "a" 前缀），Machine 类保持 100% 向后兼容
- ✅ 为未来改进奠定基础