# GitHub 主分支切换指南 (master → main)

本文档说明如何将 GitHub 仓库的主分支从 `master` 重命名为 `main`。

## 概述

GitHub 现在使用 `main` 作为默认主分支名称。切换主分支名称是一个相对简单的操作，但需要遵循正确的步骤以避免破坏协作和集成。

---

## 方法一：使用 GitHub 自动化工具（推荐）

### 步骤 1: 在 GitHub 网页上操作

1. 访问仓库页面：https://github.com/pytransitions/transitions

2. 进入 **Settings** → **Branches**

3. 找到 **"Branch name"** 或 **"Default branch"** 部分

4. 点击 **"Switch to main branch"** 或类似的按钮（如果有）

5. 确认操作

**注意**: GitHub 会在后台自动处理：
- 重命名分支
- 更新所有相关的 PR、分支保护规则、CI/CD 配置

---

## 方法二：手动切换（完整流程）

如果 GitHub 没有提供自动化选项，按照以下步骤手动操作：

### 步骤 1: 在本地创建 main 分支

```bash
# 切换到 master 分支
git checkout master

# 拉取最新代码
git pull origin master

# 创建 main 分支
git branch -m master main

# 推送 main 分支到远程
git push -u origin main
```

### 步骤 2: 更新 GitHub 默认分支

1. 访问 GitHub 仓库页面
2. 进入 **Settings** → **Branches**
3. 在 **"Default branch"** 下拉菜单中选择 **main**
4. 点击 **Update** 按钮
5. 确认操作

### 步骤 3: 更新本地仓库配置

```bash
# 更新远程分支跟踪
git branch --set-upstream-to=origin/main main

# （可选）删除本地的 master 分支
git branch -d master
```

### 步骤 4: 同步团队成员

所有协作者需要运行：

```bash
# 获取新的远程分支
git fetch origin

# 切换到 main 分支
git checkout main

# （可选）删除旧的 master 分支
git branch -d master
```

---

## 步骤 3: 更新其他平台和集成

### GitHub Actions

**文件**: `.github/workflows/pytest.yml`

需要更新的部分：

```yaml
on:
  push:
    branches: [main, dev-gha]  # 修改: master → main
  pull_request:
    branches: [main]           # 修改: master → main
```

**我会帮你更新这个文件** ✅

### 其他 CI/CD 平台

如果有以下集成，也需要更新：

- **Travis CI**: 在 `.travis.yml` 中更新分支名称
- **CircleCI**: 在 `.circleci/config.yml` 中更新
- **GitLab CI**: 在 `.gitlab-ci.yml` 中更新
- **Jenkins**: 更新 Jenkinsfile 配置

### 第三方服务

检查并更新以下服务：

- **Coveralls**: 通常通过 GitHub 集成自动更新
- **ReadTheDocs**: 在项目设置中更新默认分支
- **PyPI**: 不受影响（与 Git 分支无关）
- **Fedora Copr**: 更新构建配置中的分支引用

---

## 步骤 4: 更新文档和脚本

### README.md

更新所有指向 master 分支的链接和徽章：

```markdown
# 检查是否有以下内容需要更新
[![Build Status](...branch=master...)]  # 改为 branch=main
git clone -b master ...                 # 改为 -b main
```

### setup.py / pyproject.toml

更新 URL（如果有显式引用）：

```toml
[project.urls]
Repository = "https://github.com/pytransitions/transitions"
# 通常不需要指定分支，GitHub 会使用默认分支
```

### Contributing 指南

如果有 `CONTRIBUTING.md`，更新 PR 目标分支说明：

```markdown
创建 Pull Request 到 main 分支
```

---

## 步骤 5: 处理现有的 Pull Requests

### 如果有未合并的 PR

1. GitHub 重命名主分支后，PR 会自动重新定向到 `main`
2. 如果 PR 基于旧的 `master` 分支，需要更新：

```bash
# 协作者更新 PR
git checkout feature-branch
git rebase origin/main
git push --force
```

---

## 步骤 6: 清理旧的 master 分支（可选）

### 确认一切正常后

```bash
# 删除远程 master 分支（谨慎！）
git push origin --delete master

# 确保本地也删除
git branch -d master
```

**⚠️ 警告**: 删除前确保：
- 所有 PR 已合并或迁移
- 所有 CI/CD 配置已更新
- 团队成员已切换到 main
- 所有文档已更新

---

## 检查清单

使用以下清单确保没有遗漏：

- [ ] 在本地创建 main 分支
- [ ] 推送 main 到远程仓库
- [ ] 在 GitHub 设置中更新默认分支
- [ ] 更新 GitHub Actions 配置 (.github/workflows/pytest.yml)
- [ ] 更新 README.md 中的分支引用
- [ ] 更新其他文档 (CONTRIBUTING.md 等)
- [ ] 通知团队成员
- [ ] 检查 CI/CD 是否正常工作
- [ ] 检查第三方集成 (Coveralls, ReadTheDocs 等)
- [ ] （可选）删除 master 分支

---

## 回滚计划

如果出现问题，可以快速回滚：

```bash
# 恢复 master 分支
git checkout -b master origin/master

# 在 GitHub 设置中将默认分支改回 master

# 推送更新
git push -u origin master
```

---

## 你需要手动完成的操作

我无法直接访问你的 GitHub 仓库，以下操作需要你手动完成：

### ✅ 在 GitHub 网页上操作

1. **访问**: https://github.com/pytransitions/transitions/settings/branches

2. **更改默认分支**:
   - 找到 "Default branch" 部分
   - 点击 "Switch to/from another branch"
   - 输入 `main` 或从下拉菜单选择
   - 点击 "Update"

3. **确认**: GitHub 会显示一个确认对话框，确认操作

### ✅ 在本地执行命令

```bash
# 1. 切换到 master 并拉取最新代码
git checkout master
git pull origin master

# 2. 重命名分支为 main
git branch -m master main

# 3. 推送新的 main 分支
git push -u origin main

# 4. 设置远程跟踪
git remote set-head -a origin

# 5. （可选）删除本地 master 分支
git branch -d master
```

### ✅ 通知团队成员

发送邮件或消息给协作者：

```
主题: [ACTION REQUIRED] Switching from master to main branch

Hi team,

We are renaming our default Git branch from "master" to "main"
to follow the inclusive naming convention.

**What you need to do:**

1. Fetch the latest changes: git fetch origin
2. Switch to the new main branch: git checkout main
3. Update your local branches: git branch -d master

**Timeline:**
- Main branch created: [date]
- Default branch changed on GitHub: [date]
- Old master branch will be removed: [date]

Please let me know if you encounter any issues.

Thanks!
```

---

## 我可以帮你完成的部分

✅ **我会自动处理**:
- 更新 `.github/workflows/pytest.yml` 中的分支引用
- 更新 README.md 中的徽章和链接（如果需要）
- 更新其他文档中的分支引用

只需要告诉我你已经完成了 GitHub 和本地的分支切换，我会立即更新配置文件。

---

## 常见问题

### Q: 会影响现有的克隆和拉取吗？

A: 不会。用户的本地仓库不会有变化，但他们需要：
```bash
git fetch origin
git checkout main
```

### Q: 会破坏历史记录吗？

A: 不会。重命名分支不会改变提交历史。

### Q: 如果我忘记了某些依赖 master 的服务怎么办？

A: 你可以随时创建新的 master 分支：
```bash
git checkout main
git checkout -b master
git push origin master
```

### Q: 需要更新 PyPI 吗？

A: 不需要。PyPI 发布与 Git 分支无关。

---

## 参考资源

- [GitHub 官方文档: Renaming a branch](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/renaming-a-branch)
- [GitHub 文档: Updating the default branch](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-branches-in-your-repository/changing-the-default-branch)
- [GitHub 的 inclusive naming 倡议](https://github.com/github/renaming)

---

**准备好后，请告诉我你已经完成了分支切换，我会立即更新所有相关的配置文件！** 🚀
