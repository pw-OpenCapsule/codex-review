AI 代码审计（每日）

本仓库包含脚本与配置，用于对 GitHub 镜像仓库执行每日 Codex Code Review usage
（官方用量口径），并发送 Lark 报告。

命名规则
- GitLab 仓路径：group/project
- GitHub 镜像仓名：code-review-<group>-<project>
- GitHub 镜像全名：${GITHUB_ORG}/code-review-<group>-<project>
- 前缀可通过 REPO_PREFIX 调整

依赖
- bash, git, curl
- gh CLI 使用审计 Bot 登录

快速开始
1) 编辑 config/settings.env
2) 编辑 config/repos.txt（支持分支）
3) 运行 scripts/daily_review.sh
4) 运行 scripts/send_lark_report.sh

定时任务示例（东京，08:00）
0 8 * * * /opt/codex-review/scripts/daily_review.sh && /opt/codex-review/scripts/send_lark_report.sh

拉取请求（PR）状态机（每日）
- 若自上次审计后无变更，跳过。
- 若今日拉取请求已存在，复用。
- 若今日拉取请求已存在但已关闭，跳过并推进基线。
- 每个拉取请求仅触发一次 @codex review。

风险评分与排序
- 评分 = (risk_files * DIR_WEIGHT) + loc_score
- risk_files：位于 HIGH_RISK_DIRS 的文件数
- loc_score：ceil(total_loc / LOC_WEIGHT)，上限 MAX_LOC_SCORE
- 按评分从高到低处理队列。

建议确认的配置
- GITHUB_ORG, REPO_PREFIX, DEFAULT_BRANCH
- WORKDIR, STATE_DIR, RUN_DIR
- GITLAB_HOST, GITLAB_PROTOCOL, GITLAB_AUTH, SYNC_FROM_GITLAB
- LARK_WEBHOOK_URL
- MAX_REVIEWS_PER_RUN（0 表示不限制）

文件说明
- config/settings.env：运行配置
- config/repos.txt：GitLab 仓白名单（支持分支）
- scripts/daily_review.sh：创建每日拉取请求并触发 Codex 审查
- scripts/send_lark_report.sh：发送 Lark 报告
- templates/AGENTS.md：放在每个镜像仓库根目录

白名单格式
- group/project@branch
- 不写分支时默认使用 DEFAULT_BRANCH

GitLab 鉴权格式
- GITLAB_AUTH 形如 user:token

同步说明
- SYNC_FROM_GITLAB=1 时，会从 GitLab 拉取指定分支并推送到 GitHub 镜像

镜像仓库要求
- GitHub 仓库需提前创建，脚本不会自动新建
