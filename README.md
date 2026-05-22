# AI 代码审计（每周/每日）

本仓库包含脚本与配置，用于对 GitHub 镜像仓库执行每日/每周 Codex Code Review usage
（官方用量口径），并发送 Lark 报告。

仓库地址：https://github.com/pw-OpenCapsule/codex-review

> 当前仓库包含内部仓库清单、人员映射、飞书通知配置和历史凭据痕迹，默认应保持 private。
> 不建议直接切换为 public；如需公开，先按下方“公开前检查”完成脱敏和历史清理。

## 公开前检查

当前状态：**不适合直接 public**。

主要原因：
- `config/settings.env` 是运行环境配置，可能包含真实 GitLab/Lark/summary API 凭据或内部域名。
- `config/repos.txt` 包含内部项目路径、分支和项目命名信息。
- `config/lark_user_map.tsv` 包含员工邮箱、飞书 open_id 和显示名，属于人员信息。
- Git 历史中出现过 Lark webhook、GitLab token、内部 GitLab 域名等敏感信息；即使当前文件脱敏，public 后历史仍可被检索。
- README、脚本和模板里包含内部流程、Lark/GitLab/GitHub 镜像约定，公开前需要确认是否可以外部披露。

公开前至少需要完成：
- 轮换已进入 Git 历史的 GitLab token、Lark webhook、summary API token 等所有相关凭据。
- 将真实配置移出版本库，改用 `.env` 或部署环境变量；仓库只保留 `.env.example` / `settings.env.example`。
- 从版本库移除或脱敏 `config/repos.txt` 与 `config/lark_user_map.tsv`，只保留示例文件。
- 清理 Git 历史中的敏感内容；必要时重建一个干净 public 仓库，而不是直接把当前仓库改成 public。
- 检查 GitHub Actions、cron、部署机脚本和本地 clone 的 remote，确认它们指向新的 private 仓库地址。

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
4) （可选）运行 scripts/sync_gogs_repos.sh（从 Gogs 同步仓库列表）
5) 运行 scripts/daily_review.sh
6) 运行 scripts/send_lark_report.sh

定时任务示例（东京）
- 每日运行（daily/weekly 混合）：0 8 * * * /opt/codex-review/scripts/daily_review.sh && /opt/codex-review/scripts/send_lark_report.sh
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

报告内容润色（可选）
- 使用 CODEX_SUMMARY_API 将 review 内容转为中文摘要（无链接、适合 Lark 阅读）
- CODEX_SUMMARY_TOKEN：调用摘要 API 的 token（直接填 token，不需要 Bearer）
- CODEX_SUMMARY_MODEL：摘要模型（默认 gpt-4o-mini）
- SUMMARY_RETRY_COUNT：summary 调用失败的重试次数（默认 3）
- SUMMARY_RETRY_DELAY_SECONDS：summary 重试间隔秒数（默认 2）
- LARK_USER_MAP：Git 与 Lark 用户映射表（默认 config/lark_user_map.tsv）
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
- CODEX_SUMMARY_API, CODEX_SUMMARY_TOKEN, CODEX_SUMMARY_MODEL
- LARK_MESSAGE_TYPE（post 或 interactive）
- REVIEW_RANGE（yesterday 或 incremental，默认 yesterday；周更建议 incremental）
- DAILY_REVIEW_RANGE（默认 yesterday）
- WEEKLY_REVIEW_RANGE（默认 incremental）
- WEEKLY_REVIEW_DOW（可选，1-7，周一=1；仅 weekly 使用）
- LOG_YESTERDAY_COMMITS（默认 1，打印昨日提交摘要）
- YESTERDAY_LOG_LIMIT（默认 20，最多打印多少条）
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
- scripts/daily_review.sh：按 daily/weekly 配置创建拉取请求并触发 Codex 审查
- scripts/init_repos.sh：首次建仓与同步（不创建 PR / 评论）
- scripts/sync_gogs_repos.sh：从 Gogs 拉取仓库列表并写入 config/repos.txt
- scripts/send_lark_report.sh：发送 Lark 报告
- templates/AGENTS.md：放在每个镜像仓库根目录

白名单格式
- group/project@branch [daily|weekly]
- 不写分支时默认使用 DEFAULT_BRANCH

GitLab 鉴权格式
- GITLAB_AUTH 形如 user:token

同步说明
- SYNC_FROM_GITLAB=1 时，会从 GitLab 拉取指定分支并推送到 GitHub 镜像

镜像仓库要求
- GitHub 仓库若不存在会自动新建（需 gh 有组织建仓权限）
