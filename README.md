# AI 代码审计（每周/每日）

本仓库包含脚本与配置，用于对 GitHub 镜像仓库执行每日/每周 Codex Code Review usage
（官方用量口径），并发送 Lark 报告。

仓库地址：https://github.com/pw-OpenCapsule/codex-review

> 代码仓库只保存脚本和示例配置。真实仓库清单、人员映射、token、webhook 等运行配置不进 Git。

## 公开前检查

目标状态：代码仓库可以公开，真实配置保持 private。

公开前必须确认：
- Git 历史已经清理，不包含真实 `config/settings.env`、`config/repos.txt`、`config/lark_user_map.tsv`。
- 已轮换历史中出现过的 GitLab token、Lark webhook、summary API token 等凭据。
- GitHub Actions、cron、部署机脚本和本地 clone 的 remote 已指向正确仓库。

## 配置管理

真实配置文件被 `.gitignore` 忽略：
- `config/settings.env`：运行配置、token、webhook、内部域名
- `config/repos.txt`：待审计仓库白名单
- `config/lark_user_map.tsv`：Git author 与 Lark 用户映射

仓库只保留示例文件：
- `config/settings.env.example`
- `config/repos.example.txt`
- `config/lark_user_map.example.tsv`

初始化本地配置：

```bash
cp config/settings.env.example config/settings.env
cp config/repos.example.txt config/repos.txt
cp config/lark_user_map.example.tsv config/lark_user_map.tsv
```

生产环境使用独立 private 配置仓库同步真实配置：

- 代码仓库：https://github.com/pw-OpenCapsule/codex-review
- 配置仓库：https://github.com/pw-OpenCapsule/codex-review-config

不建议用 public 仓库的 submodule 管理密钥；用 private 配置仓库 + 环境变量路径更清晰。

```bash
git clone https://github.com/pw-OpenCapsule/codex-review.git /opt/codex-review
git clone https://github.com/pw-OpenCapsule/codex-review-config.git /etc/codex-review

export CODEX_REVIEW_SETTINGS=/etc/codex-review/settings.env
export REPOS_FILE=/etc/codex-review/repos.txt
export LARK_USER_MAP=/etc/codex-review/lark_user_map.tsv
```

也可以把 private 配置仓库同步到本仓库的 `config/` 目录；这些真实文件已被 Git 忽略，不会被误提交。

命名规则
- GitLab 仓路径：group/project
- GitHub 镜像仓名：<project>（与 GitLab 项目名一致）
- GitHub 镜像全名：${GITHUB_ORG}/<project>

依赖
- bash, git, curl
- gh CLI 使用审计 Bot 登录
  - 无人值守建议配置 GH_TOKEN/GITHUB_TOKEN，并运行一次 gh auth setup-git

快速开始
1) 从 `config/*.example.*` 复制出本地真实配置
2) 编辑 `config/settings.env`
3) 编辑 `config/repos.txt`（支持分支）
4) （可选）首次运行 scripts/init_repos.sh（仅建仓与同步，不创建 PR / 评论）
5) （可选）运行 scripts/sync_gogs_repos.sh（从 Gogs 同步仓库列表）
6) 运行 scripts/daily_review.sh
7) 运行 scripts/send_lark_report.sh

定时任务示例（东京）
- 每日运行（脚本内部按 daily/every3d/every5d/weekly/manual 节奏筛选）：0 8 * * * /opt/codex-review/scripts/daily_review.sh && /opt/codex-review/scripts/send_lark_report.sh
- 仅每周运行：0 8 * * 1 /opt/codex-review/scripts/daily_review.sh && /opt/codex-review/scripts/send_lark_report.sh

无人值守建议
- GitHub：设置 GH_TOKEN 或 GITHUB_TOKEN（Bot Token），确保 gh 与 git 均可无交互使用
- GitLab：配置 GITLAB_AUTH="user:token" 避免交互登录

手动重跑（可选）
- FORCE_REVIEW=1：忽略上次基线，重新生成本次 PR 差异
- FORCE_COMMENT=1：即使已有 @codex review，也会追加一条触发评论

自动发送报告（可选）
- AUTO_SEND_LARK=1：在创建 PR 后自动等待审查结果并发送 Lark 报告
- REVIEW_WAIT_SECONDS：最长等待秒数（到期仍发送）
- REVIEW_POLL_INTERVAL：轮询间隔秒数
- CODEX_REVIEW_AUTHOR：指定 Codex 账号 login 用于判断审查完成（不填则根据评论内容判断）
- 日报在周六/周日不发送，周一补发周六/周日并发送周一日报
- 审查无风险项且未标注 P0-P5 时不发送 Lark 与摘要

报告内容复核与翻译（codex exec，2026-05-25 起替换 codex.leeguoo.com）
- 调本地 `codex exec` 在镜像 repo 里读源码做「复核 + 翻译」：剔除幻觉/误报，剩下的按 P0-P5 翻译成中文
- 复核工作目录为 `${WORKDIR}/<mirror-repo>`，对 PR 文件做 git blame 时也是这个目录
- 配置项：
  - `CODEX_EXEC_BIN`（默认 `codex`）— codex CLI 路径
  - `CODEX_EXEC_TIMEOUT`（默认 300）— 单次复核超时秒数
  - `CODEX_EXEC_MODEL`（默认空）— 留空用 codex 默认模型
  - `CODEX_EXEC_EXTRA_ARGS`（默认空）— 透传给 codex 的额外参数
- 旧的 `CODEX_SUMMARY_API/TOKEN/MODEL` 已废弃，如有残留请删除

Meegle 自动建缺陷
- 飞书 webhook 发送成功后，每个 P0-P5 问题各建一条 Meegle 缺陷到「Code Review」项目（type=`issue`）
- 责任人 (`current_status_operator`) 通过 `git blame` 找到引入这行代码的人，经 `LARK_USER_MAP` 映射成 Meegle user_key
- 幂等：`${STATE_DIR}/meegle-created.tsv` 记录已建过的 (file, line, summary) → work_item_id，重跑不会重复建
- 配置项：
  - `MEEGLE_PROJECT_KEY`（默认 Code Review project）
  - `MEEGLE_WORK_ITEM_TYPE="issue"`
  - `MEEGLE_BIN`（默认 `meegle`）— meegle-cli 路径
  - `MEEGLE_DEFAULT_ASSIGNEE`（默认空）— blame 失败时的兜底人
  - `MEEGLE_AUTO_CREATE`（默认 1）— 总开关，dry-run 时 meegle CLI 自动走 `--dry-run`
  - `MEEGLE_SEVERITY_MAP`（默认 `P0:1 P1:2 P2:3 P3:4 P4:5 P5:5`，对应严重/重要/一般/次要/微小）
- 首次使用前需在运行机器上 `meegle auth login --device-code`

其它运行配置
- LARK_USER_MAP：Git 与 Lark 用户映射表（默认 config/lark_user_map.tsv）
- REPOS_FILE：仓库白名单路径（默认 config/repos.txt）
- CODEX_REVIEW_SETTINGS：运行配置路径（默认 config/settings.env）
- LARK_MENTION_MAX：报告中最多 @ 的作者数量（默认 3）
- SNIPPET_CONTEXT：代码片段上下文行数（默认 3，向上/向下各扩展）

拉取请求（PR）状态机（每日/每周）
- 若自上次审计后无变更，跳过。
- 若本次拉取请求已存在，复用。
- 若本次拉取请求已存在但已关闭，跳过并推进基线。
- 每个拉取请求仅触发一次 @codex review。

风险评分与排序
- 评分 = (risk_files * DIR_WEIGHT) + loc_score
- risk_files：位于 HIGH_RISK_DIRS 的文件数
- loc_score：ceil(total_loc / LOC_WEIGHT)，上限 MAX_LOC_SCORE
- 按评分从高到低处理队列。

建议确认的配置
- GITHUB_ORG, GITHUB_REPO_VISIBILITY, DEFAULT_BRANCH
- AUTO_SEND_LARK, REVIEW_WAIT_SECONDS, REVIEW_POLL_INTERVAL, CODEX_REVIEW_AUTHOR
- CODEX_EXEC_BIN, CODEX_EXEC_TIMEOUT, CODEX_EXEC_MODEL, CODEX_EXEC_EXTRA_ARGS
- MEEGLE_PROJECT_KEY, MEEGLE_WORK_ITEM_TYPE, MEEGLE_BIN, MEEGLE_AUTO_CREATE, MEEGLE_SEVERITY_MAP
- LARK_MESSAGE_TYPE（post 或 interactive）
- REVIEW_RANGE（yesterday 或 incremental，默认 yesterday；周更建议 incremental）
- DAILY_REVIEW_RANGE（默认 yesterday）
- INTERVAL_REVIEW_RANGE（every3d/every5d 使用，默认 incremental）
- WEEKLY_REVIEW_RANGE（默认 incremental）
- WEEKLY_REVIEW_DOW（可选，1-7，周一=1；仅 weekly 使用）
- LOG_YESTERDAY_COMMITS（默认 1，打印昨日提交摘要）
- YESTERDAY_LOG_LIMIT（默认 20，最多打印多少条）
- REVIEW_DASHBOARD_URL（可选，飞书报告末尾追加的状态页链接）
- AUTO_BUILD_REVIEW_DASHBOARD（可选，发送报告后刷新状态页，默认 0）
- REVIEW_DASHBOARD_DAYS（状态页默认历史天数，默认 30）
- WORKDIR, STATE_DIR, RUN_DIR
- GITLAB_HOST, GITLAB_PROTOCOL, GITLAB_AUTH, SYNC_FROM_GITLAB
- LARK_WEBHOOK_URL

运行预览（不创建 PR/评论）
- ./scripts/daily_review.sh --dry
- MAX_REVIEWS_PER_RUN（0 表示不限制）

文件说明
- config/settings.env.example：运行配置示例
- config/repos.example.txt：GitLab 仓白名单示例（支持分支）
- config/lark_user_map.example.tsv：Git 与 Lark 用户映射表示例
- config/settings.env：本地真实运行配置，已忽略
- config/repos.txt：本地真实仓白名单，已忽略
- config/lark_user_map.tsv：本地真实用户映射，已忽略
- scripts/daily_review.sh：按 daily/weekly 配置创建拉取请求并触发 Codex 审查
- scripts/init_repos.sh：首次建仓与同步（不创建 PR / 评论）
- scripts/sync_gogs_repos.sh：从 Gogs 拉取仓库列表并写入 REPOS_FILE
- scripts/send_lark_report.sh：发送 Lark 报告
- scripts/build_review_dashboard.sh：从历史 run 记录和 GitHub PR 状态生成静态 review 状态页
- templates/AGENTS.md：放在每个镜像仓库根目录

Review 状态页
- 生成最近 30 天状态页：`./scripts/build_review_dashboard.sh`
- 指定范围：`./scripts/build_review_dashboard.sh --days 90`
- 按项目生成：`./scripts/build_review_dashboard.sh --repo pw-admin`
- 默认输出：
  - `$RUN_DIR/review-dashboard.html`
  - `$RUN_DIR/review-dashboard.json`
- 页面展示已处理、未处理、等待审查、是否已发送群消息，并支持前端搜索/筛选。
- 设置 `REVIEW_DASHBOARD_URL` 后，飞书报告末尾会附带状态页入口；设置 `AUTO_BUILD_REVIEW_DASHBOARD=1` 后，发送报告结束会自动刷新页面。

白名单格式
- group/project@branch [daily|every3d|every5d|weekly|manual]
- 不写分支时默认使用 DEFAULT_BRANCH
- `every3d` / `every5d` 按工作日间隔计算，周六/周日自动跳过；日本节假日不内置判断。
- `manual` 自动任务跳过，配合 FORCE_REVIEW 手动触发。

GitLab 鉴权格式
- GITLAB_AUTH 形如 user:token

同步说明
- SYNC_FROM_GITLAB=1 时，会从 GitLab 拉取指定分支并推送到 GitHub 镜像

镜像仓库要求
- GitHub 仓库若不存在会自动新建（需 gh 有组织建仓权限）

远程部署
- 生产机器：leo@192.168.0.190（Mac，免密 SSH 已通）
- 代码目录：/Users/leo/codex-review
- 本地修改后用 `./scripts/deploy.sh "commit message"` 一键推到远程
- deploy.sh 会先检查远程脏工作区 + 撞 cron 检测，再做 commit + push + ssh pull
