# 大规模重构计划：AsyncMachine 异步强制封装方案

## 核心原则

**Machine 保持纯粹同步，AsyncMachine 强制异步封装**

1. ✅ Machine 类不添加任何异步方法，保持纯粹同步
2. ✅ AsyncMachine override 核心方法为异步版本（添加 "a" 前缀，下划线方法，在下划线后，单词前添加"a"），并强制异步调用
3. ✅ 提取共享逻辑到私有方法，减少代码重复
4. ✅ 抛出明确异常和警告，防止误用
5. ✅ 减少约 60% 的 type ignore
6. ✅ 统一异常消息格式：`"{ClassName}.{method}() is disabled. Use 'await {instance}.{method}(...)' instead."`

## 目标

1. ✅ 解决 AsyncMachine 辅助类的 20+ 个 override 问题（State/Event/Transition）
2. ✅ 保留核心方法的必要 override（dispatch/callbacks/callback 约 7 个）
3. ✅ 保持所有公共接口不变（100% 向后兼容）
4. ✅ 清晰的错误提示，防止同步调用异步方法
5. ✅ 减少约 60% 的 type ignore（从 42 个减少到约 15-20 个）

## 重构范围

- tfsm/core.py: 1439 行 -> 预计 +100-200 行（提取共享逻辑）
- tfsm/extensions/asyncio.py: 804 行 -> 预计 -200-300 行（简化辅助类）
- tfsm/extensions/nesting.py: 1435 行 -> 预计 +50-100 行
- **总计**: 3678 行代码，净变化约 -100 行

## 核心策略

### 策略 1：AsyncMachine 异步方法覆盖（约 7 个核心方法）

**核心思想**：AsyncMachine 用 `async def` 配合a前缀来添加异步版本的方法。对于同步方法，直接抛出RuntimeError

**技术限制**：
- ❌ Python 中同一个类**不能同时定义同名**的同步方法和异步方法
- 异步方法相较于同步方法，添加一个 "a" 前缀
- 同步方法直接override，抛出RuntimeError，因此无法同时提供"同步抛异常版本"和"异步执行版本"

**实际方案**：

**方案 A：直接覆盖（大多数公共 API 方法）**
```python
class AsyncMachine(Machine):
    def dispatch(self, trigger: str, *args: Any, **kwargs: Any) -> bool:
        raise RuntimeError("AsyncMachine需要使用 adispatch")
    # 直接用 async def 覆盖父类的同步方法
    async def adispatch(self, trigger: str, *args: Any, **kwargs: Any) -> bool:
        """Trigger an event on all models assigned to the machine asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await machine.dispatch('event')
                ❌ machine.dispatch('event')  # BUG: Creates coroutine, won't execute!

        If you don't await, you'll get a coroutine object instead of the result.
        """
        results = await self.await_all([partial(getattr(model, trigger), *args, **kwargs) for model in self.models])
        return all(results)
    
    def callbacks(self, funcs: CallbackList, event_data: EventData) -> None:
        raise RuntimeError("AsyncMachine需要使用 acallbacks")
    
    async def acallbacks(self, funcs: CallbackList, event_data: EventData) -> None:
        """Triggers a list of callbacks asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        await self.await_all([partial(event_data.machine.callback, func, event_data) for func in funcs])

    def callback(self, func: Callback, event_data: EventData) -> None:
        raise RuntimeError("AsyncMachine需要使用 acallback")
        
    async def acallback(self, func: Callback, event_data: EventData) -> None:
        """Trigger a callback function asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        func = self.resolve_callable(func, event_data)
        res = func(event_data) if self.send_event else func(*event_data.args, **event_data.kwargs)
        if inspect.isawaitable(res):
            await res

    def _can_trigger(self, model: Any, trigger: str, *args: Any, **kwargs: Any) -> bool:
        raise RuntimeError("AsyncMachine需要使用 _acan_trigger")
    
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

        ⚠️  Use 'await _process_async(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncMachine._process() is disabled. Use 'await machine._process_async(...)' instead."
        )

    # 异步方法：使用不同的名称
    async def _aprocess(self, trigger: partial[Any], model: Any) -> bool:
        """Async version of _process.

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...
```

**选择标准**：
- **公共 API 方法**（dispatch, callbacks, callback）：使用方案 A（直接覆盖）
- **内部方法**（_process）：使用方案 B（重命名）以保持清晰性

**关键点**：
- ✅ AsyncMachine 重写所有核心方法为异步版本
- ✅ 文档明确说明"必须使用 await"
- ✅ 返回类型从具体值变为 Coroutine（故意的 LSP 违反）
- ✅ 保留 `# type: ignore[override]` 并添加清晰注释

### 策略 2：辅助类异步覆盖（约 15-20 个 override）

**与 AsyncMachine 一样**，AsyncState、AsyncEvent、AsyncTransition 等辅助类也用 `async def` 直接覆盖同步方法。

**示例**：直接用 `async def` 覆盖（没有 "a" 前缀）

```python
class AsyncState(State):
    """Async state with async-only transition methods.
    所有状态转换方法（enter/exit）都是异步的。
    """

    # 直接覆盖，没有前缀
    async def enter(self, event_data: "AsyncEventData") -> None:  # type: ignore[override]
        """Triggered when a state is entered asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        _LOGGER.debug("%sEntering state %s...", event_data.machine.name, self.name)
        await event_data.machine.callbacks(self.on_enter, event_data)
        _LOGGER.info("%sFinished processing state %s enter callbacks.", event_data.machine.name, self.name)

    async def exit(self, event_data: "AsyncEventData") -> None:  # type: ignore[override]
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

    async def trigger(self, model: Any, *args: Any, **kwargs: Any) -> bool:  # type: ignore[override]
        """Serially execute all transitions that match the current state.

        ⚠️  CRITICAL: Must be awaited!
        """
        func = partial(self._trigger, EventData(None, self, self.machine, model, args=args, kwargs=kwargs))
        return await self.machine.process_context(func, model)

class AsyncTransition(Transition):
    """Async transition with async-only execution.
    所有转换执行方法（execute/_eval_conditions/_change_state）都是异步的。
    """

    condition_cls = AsyncCondition

    async def _eval_conditions(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Evaluate transition conditions asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        res = await event_data.machine.await_all([partial(cond.check, event_data) for cond in self.conditions])
        if not all(res):
            _LOGGER.debug("%sTransition condition failed.", event_data.machine.name)
            return False
        return True

    async def execute(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Execute the transition asynchronously.

        ⚠️  CRITICAL: Must be awaited!
        """
        _LOGGER.debug("%sInitiating transition from %s to %s...", event_data.machine.name, self.source, self.dest)
        await event_data.machine.callbacks(self.prepare, event_data)

        if not await self._eval_conditions(event_data):
            return False

        await event_data.machine.cancel_running_transitions(event_data.model)
        await event_data.machine.callbacks(event_data.machine.before_state_change, event_data)
        await event_data.machine.callbacks(self.before, event_data)

        if self.dest is not None:
            await self._change_state(event_data)

        await event_data.machine.callbacks(self.after, event_data)
        await event_data.machine.callbacks(event_data.machine.after_state_change, event_data)
        return True
```

**关键点**：
- ✅ 所有方法直接用 `async def` 覆盖，**没有 "a" 前缀**
- ✅ 文档明确说明必须使用 await
- ✅ 保留 `# type: ignore[override]` 并添加清晰注释

# TODO 其它需要处理的 Async 类：
# - NestedAsyncState: 覆盖 scoped_enter/scoped_exit
# - NestedAsyncEvent: 覆盖 trigger_nested/_process
# - NestedAsyncTransition: 覆盖 _change_state
# - HierarchicalAsyncMachine: 继承自 AsyncMachine
# - AsyncCondition: 覆盖 check
# - AsyncTimeout: 覆盖 enter/exit/create_timer

# 这些类的处理方式与上述类似：直接用 async def 覆盖父类方法
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

    # 方案 A：直接用 async def 覆盖（大多数公共 API 方法）
    async def dispatch(self, trigger: str, *args: Any, **kwargs: Any) -> bool:  # type: ignore[override]
        """Trigger an event on all models assigned to the machine asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await machine.dispatch('event')
                ❌ machine.dispatch('event')  # BUG: Creates coroutine, won't execute!

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

    async def callbacks(self, funcs: CallbackList, event_data: EventData) -> None:  # type: ignore[override]
        """Triggers a list of callbacks asynchronously.

        ⚠️  CRITICAL: Must be awaited: await machine.callbacks(...)
        """
        await self.await_all([partial(event_data.machine.callback, func, event_data) for func in funcs])

    async def callback(self, func: Callback, event_data: EventData) -> None:  # type: ignore[override]
        """Trigger a callback function asynchronously.

        ⚠️  CRITICAL: Must be awaited: await machine.callback(...)

        Automatically awaits awaitable results from callbacks.
        """
        func = self.resolve_callable(func, event_data)
        res = func(event_data) if self.send_event else func(*event_data.args, **event_data.kwargs)
        if inspect.isawaitable(res):
            await res

    async def _can_trigger(self, model: Any, trigger: str, *args: Any, **kwargs: Any) -> bool:  # type: ignore[override]
        """Check if an event can be triggered asynchronously.

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...

    # 方案 B：重命名（少数内部方法，需要明确区分）
    def _process(self, trigger: Any) -> None:  # type: ignore[override]
        """Synchronous version is disabled in AsyncMachine!

        ⚠️  Use 'await _process_async(...)' instead.

        Raises:
            RuntimeError: Always raised when called
        """
        raise RuntimeError(
            "AsyncMachine._process() is disabled. Use 'await machine._process_async(...)' instead."
        )

    async def _process_async(self, trigger: partial[Any], model: Any) -> bool:
        """Async version of _process.

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...
```

**关键改进**：
- ✅ 公共 API 方法（dispatch, callbacks, callback）直接用 `async def` 覆盖
- ✅ 内部方法（_process）采用重命名方案，明确区分同步/异步版本
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

    # 直接用 async def 覆盖父类的 enter 方法
    async def enter(self, event_data: "AsyncEventData") -> None:  # type: ignore[override]
        """Triggered when a state is entered asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await state.enter(event_data)
                ❌ state.enter(event_data)  # BUG: Creates coroutine, won't execute!

        Args:
            event_data: (AsyncEventData): The currently processed event.
        """
        _LOGGER.debug("%sEntering state %s. Processing callbacks...", event_data.machine.name, self.name)
        await event_data.machine.callbacks(self.on_enter, event_data)
        _LOGGER.info("%sFinished processing state %s enter callbacks.", event_data.machine.name, self.name)

    # 直接用 async def 覆盖父类的 exit 方法
    async def exit(self, event_data: "AsyncEventData") -> None:  # type: ignore[override]
        """Triggered when a state is exited asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await state.exit(event_data)
                ❌ state.exit(event_data)  # BUG: Creates coroutine, won't execute!

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

    # 直接用 async def 覆盖父类的 trigger 方法
    async def trigger(self, model: Any, *args: Any, **kwargs: Any) -> bool:  # type: ignore[override]
        """Serially execute all transitions that match the current state asynchronously.

        ⚠️  CRITICAL:
            This is an async method and MUST be awaited:
                ✅ await event.trigger(...)
                ❌ event.trigger(...)  # BUG: Creates coroutine, won't execute!

        Returns:
            bool: True if a transition was successfully executed
        """
        func = partial(self._trigger, EventData(None, self, self.machine, model, args=args, kwargs=kwargs))
        return await self.machine.process_context(func, model)

    async def _trigger(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Internal trigger function (async).

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...

    async def _process(self, event_data: EventData) -> None:  # type: ignore[override]
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

    # 直接用 async def 覆盖父类的 _eval_conditions 方法
    async def _eval_conditions(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Evaluate transition conditions asynchronously.

        ⚠️  CRITICAL: Must be awaited.
        """
        res = await event_data.machine.await_all([partial(cond.check, event_data) for cond in self.conditions])
        if not all(res):
            _LOGGER.debug("%sTransition condition failed: Transition halted.", event_data.machine.name)
            return False
        return True

    # 直接用 async def 覆盖父类的 execute 方法
    async def execute(self, event_data: EventData) -> bool:  # type: ignore[override]
        """Execute the transition asynchronously.

        ⚠️  CRITICAL: Must be awaited.

        Returns:
            bool: True if transition was successful, False otherwise
        """
        _LOGGER.debug("%sInitiating transition from %s to %s...", event_data.machine.name, self.source, self.dest)
        await event_data.machine.callbacks(self.prepare, event_data)

        if not await self._eval_conditions(event_data):
            return False

        await event_data.machine.cancel_running_transitions(event_data.model)
        await event_data.machine.callbacks(event_data.machine.before_state_change, event_data)
        await event_data.machine.callbacks(self.before, event_data)

        if self.dest is not None:
            await self._change_state(event_data)

        await event_data.machine.callbacks(self.after, event_data)
        await event_data.machine.callbacks(event_data.machine.after_state_change, event_data)
        return True

    async def _change_state(self, event_data: EventData) -> None:  # type: ignore[override]
        """Change state asynchronously.

        ⚠️  CRITICAL: Must be awaited.
        """
        # ... 实现逻辑 ...
```

**预期变化**：
- 所有辅助类都用 `async def` 直接覆盖父类方法
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

## 预期结果

### 代码质量改进

| 指标 | 重构前 | 重构后 | 改进 |
|------|--------|--------|------|
| type: ignore 数量 | ~42 个 | ~15-20 个 | ↓ 50-60% |
| 异步辅助类 override | 20+ 个 | 7 个核心方法 | ↓ 65% |
| 代码行数（asyncio.py） | 804 行 | ~650-700 行 | ↓ 100-150 行 |
| 文档覆盖率 | 60% | 95% | ↑ 35% |

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
# 用户忘记 await，立即得到明确的错误
machine.dispatch('event')  # 抛出 RuntimeError
# RuntimeError: AsyncMachine.dispatch() is disabled. Use 'await machine.dispatch(...)' instead.
```

**使用示例改进**：

```python
# ✅ 清晰的正确用法示例
async def main():
    machine = AsyncMachine(states=['A', 'B'], initial='A')
    result = await machine.advance()  # 明确的 async 用法
    print(f"Transition result: {result}")  # bool 值

# ❌ 明确的错误用法示例（会抛出异常）
def wrong_example():
    machine = AsyncMachine(states=['A', 'B'], initial='A')
    machine.advance()  # 立即抛出 RuntimeError
```

### 性能影响

**预期性能变化**：
- 运行时性能：无明显影响（仅增加少量类型检查）
- 首次导入时间：+1-2%（增加了文档和辅助方法）
- 内存占用：无明显变化
- 异步执行性能：无变化（保持 asyncio.gather 的并发能力）

### 向后兼容性

**破坏性变化**：
- ❌ 无法在同步上下文中调用 AsyncMachine 方法（会抛 RuntimeError）
- ✅ 正确的异步用法完全兼容

**迁移指南**：

旧代码（可能有 bug）：
```python
# 如果用户忘记 await，之前会创建 coroutine（静默 bug）
machine = AsyncMachine(...)
result = machine.dispatch('event')  # 旧版本：返回 coroutine
```

新代码（强制正确）：
```python
# 现在必须使用 await，否则会抛出清晰的错误
machine = AsyncMachine(...)
result = await machine.dispatch('event')  # 正确用法
```

**兼容性保证**：
- ✅ 所有正确的异步代码（已使用 await）无需修改
- ✅ 所有测试用例无需修改（如果测试正确使用了 await）
- ❌ 错误的用法（忘记 await）会在运行时立即失败（改进！）

### 测试覆盖

**测试验证清单**：
- [ ] 所有现有测试通过（100% 向后兼容的正确用法）
- [ ] 新增测试验证同步方法抛出 RuntimeError
- [ ] 新增测试验证异步方法正常工作
- [ ] 文档示例可以正确执行
- [ ] mypy 类型检查通过（包含必要的 type ignore）
- [ ] 性能基准测试无退化

### 风险评估

**低风险**：
- ✅ 正确的异步代码完全兼容
- ✅ 所有改动都在 asyncio 模块内，不影响核心 Machine
- ✅ 向后兼容性良好

**中风险**：
- ⚠️ 错误的用法（忘记 await）会立即失败（但这是改进，不是问题）
- ⚠️ 需要更新用户文档说明新的错误消息

**缓解措施**：
- 在 CHANGELOG 中明确说明破坏性变化
- 提供迁移指南
- 逐步发布（先作为警告，然后才是错误）

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
- ✅ 保持 100% 向后兼容性（对于正确用法）
- ✅ 为未来改进奠定基础