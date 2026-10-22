# Agent Guide

本文件说明 `docker-db-cron-backup` 仓库的当前实现和开发规则。面向使用者的说明见 [README.md](README.md)。

## 项目实现

- 项目运行在 Ubuntu 的 Docker Compose 环境，镜像支持 `linux/amd64` 和 `linux/arm64`。
- 支持 MySQL 和 PostgreSQL。`Dockerfile` 的 `mysql` target 基于 `mysql:9.7`，`postgres` target 基于 `postgres:18`，数据库类型由镜像内的 `DB_ENGINE` 决定。
- `scripts/backup.sh` 负责公共流程，`scripts/engines/<engine>.sh` 实现列库、导出和完整性校验。连接配置统一使用 `DB_*` 变量。新增数据库类型时实现 `engine_require_commands`、`engine_configure`、`engine_is_system_database`、`engine_list_databases`、`engine_dump`（可选 `engine_dump_globals`），并在 `Dockerfile` 增加同名 target。
- MySQL 使用 `mysqldump` 生成 `.sql.gz`；PostgreSQL 使用 `pg_dump` custom 格式生成 `.dump`，并用 `pg_dumpall --globals-only --no-role-passwords` 导出角色到 `_globals`。
- BusyBox `crond` 根据 `BACKUP_CRON` 运行备份任务。脚本安装在镜像的 `/opt/db-backup`。
- 备份在容器临时目录生成，完成完整性校验和 S3 上传校验后清理。
- 成功连接数据库但没有业务数据库时，任务以成功状态结束。
- 对象键格式为 `[<S3_PREFIX>/]<数据库名>/<YYYYMMDDHHmmss>.<扩展名>`。
- 备份保留周期由对象存储生命周期规则管理。
- `/var/lib/db-backup` 保存任务状态，供 Docker Healthcheck 使用。
- `master` 分支通过 CI 后发布 `ghcr.io/qiujun8023/db-cron-backup:<engine>` 和 `:<engine>-<7 位提交哈希>`。

新增或修改配置时，同步更新 [README.md](README.md)、[compose.example.yml](compose.example.yml) 和相关测试。

## 常用校验

```bash
shellcheck -x scripts/*.sh scripts/engines/*.sh tests/*.sh
bash -n scripts/*.sh scripts/engines/*.sh tests/*.sh
bash tests/run.sh
bash tests/integration.sh mysql
bash tests/integration.sh postgres
actionlint .github/workflows/ci.yml .github/workflows/docker-publish.yml
```

集成测试使用真实的 MySQL 9.7 和 PostgreSQL 18 验证导出、恢复、cron 调度和健康检查，S3 命令由测试脚本模拟。Dockerfile、基础镜像或构建流程变化后，需要完成两个引擎的集成测试和双架构构建。

## 提交规则

- 未经用户明确要求或明确同意，不得执行 `git commit` 或 `git push`。
- 默认在 `master` 分支开发，提交前确认 `git status --short` 只包含本次任务相关文件。
- 提交信息使用中文，格式为 `<type>(<scope>): <中文摘要>`。
- type 使用 `feat`、`fix`、`refactor`、`docs`、`test`、`build`、`ci` 或 `chore`。
- scope 使用 `backup`、`scheduler`、`docker`、`ci`、`docs` 等实际模块名。
- 提交信息不包含 AI 署名、生成标识、协作者 trailer 或工具标记。

## 操作边界

- 保留用户已有改动，忽略与当前任务无关的工作区变化。
- 仓库内容不包含数据库密码、S3 密钥、`.env`、真实备份文件或镜像归档。
- S3 备份身份仅使用备份和校验所需权限，对象删除由存储桶生命周期执行。
- SSH 部署、生产容器重启和生产备份需要用户明确授权。
- 验证结果应注明实际执行过的测试范围。
