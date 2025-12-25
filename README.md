AI 代码审计（每日）

本仓库包含脚本与配置，用于对 GitHub 镜像仓库执行每日 Codex Code Review usage
（官方用量口径），并发送 Lark 报告。

命名规则
- GitLab 仓路径：group/project
- GitHub 镜像仓名：<project>（与 GitLab 项目名一致）
- GitHub 镜像全名：${GITHUB_ORG}/<project>

依赖
- bash, git, curl
- gh CLI 使用审计 Bot 登录
  - 无人值守建议配置 GH_TOKEN/GITHUB_TOKEN，并运行一次 gh auth setup-git

快速开始
1) 编辑 config/settings.env
2) 编辑 config/repos.txt（支持分支）
3) （可选）首次运行 scripts/init_repos.sh（仅建仓与同步，不创建 PR / 评论）
4) 运行 scripts/daily_review.sh
5) 运行 scripts/send_lark_report.sh

定时任务示例（东京，08:00）
0 8 * * * /opt/codex-review/scripts/daily_review.sh && /opt/codex-review/scripts/send_lark_report.sh

无人值守建议
- GitHub：设置 GH_TOKEN 或 GITHUB_TOKEN（Bot Token），确保 gh 与 git 均可无交互使用
- GitLab：配置 GITLAB_AUTH="user:token" 避免交互登录

手动重跑（可选）
- FORCE_REVIEW=1：忽略上次基线，重新生成今日 PR 差异
- FORCE_COMMENT=1：即使已有 @codex review，也会追加一条触发评论

自动发送报告（可选）
- AUTO_SEND_LARK=1：在创建 PR 后自动等待审查结果并发送 Lark 报告
- REVIEW_WAIT_SECONDS：最长等待秒数（到期仍发送）
- REVIEW_POLL_INTERVAL：轮询间隔秒数
- CODEX_REVIEW_AUTHOR：指定 Codex 账号 login 用于判断审查完成（不填则根据评论内容判断）

报告内容润色（可选）
- 使用 CODEX_SUMMARY_API 将 review 内容转为中文摘要（无链接、适合 Lark 阅读）
- CODEX_SUMMARY_TOKEN：调用摘要 API 的 token（直接填 token，不需要 Bearer）
- CODEX_SUMMARY_MODEL：摘要模型（默认 gpt-4o-mini）
- LARK_USER_MAP：Git 与 Lark 用户映射表（默认 config/lark_user_map.tsv）
- LARK_MENTION_MAX：报告中最多 @ 的作者数量（默认 3）

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
- GITHUB_ORG, GITHUB_REPO_VISIBILITY, DEFAULT_BRANCH
- AUTO_SEND_LARK, REVIEW_WAIT_SECONDS, REVIEW_POLL_INTERVAL, CODEX_REVIEW_AUTHOR
- CODEX_SUMMARY_API, CODEX_SUMMARY_TOKEN, CODEX_SUMMARY_MODEL
- LARK_MESSAGE_TYPE（post 或 interactive）
- REVIEW_RANGE（yesterday 或 incremental，默认 yesterday）
- WORKDIR, STATE_DIR, RUN_DIR
- GITLAB_HOST, GITLAB_PROTOCOL, GITLAB_AUTH, SYNC_FROM_GITLAB
- LARK_WEBHOOK_URL

运行预览（不创建 PR/评论）
- ./scripts/daily_review.sh --dry
- MAX_REVIEWS_PER_RUN（0 表示不限制）

文件说明
- config/settings.env：运行配置
- config/repos.txt：GitLab 仓白名单（支持分支）
- config/lark_user_map.tsv：Git 与 Lark 用户映射表
- scripts/daily_review.sh：创建每日拉取请求并触发 Codex 审查
- scripts/init_repos.sh：首次建仓与同步（不创建 PR / 评论）
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
- GitHub 仓库若不存在会自动新建（需 gh 有组织建仓权限）
