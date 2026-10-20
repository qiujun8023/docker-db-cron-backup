# docker-db-cron-backup

`docker-db-cron-backup` 是运行在 Docker 中的数据库定时备份服务，支持 MySQL 和 PostgreSQL。服务根据 cron 表达式导出数据库，将备份文件上传到 AWS S3 或 S3 兼容对象存储，用于灾备恢复。

每种数据库对应一个镜像 tag，镜像支持 `linux/amd64` 与 `linux/arm64`：

| tag | 基础镜像 | 备份工具 | 备份格式 |
| --- | --- | --- | --- |
| `ghcr.io/qiujun8023/db-cron-backup:mysql` | `mysql:8.4` | `mysqldump` | SQL + gzip（`.sql.gz`） |
| `ghcr.io/qiujun8023/db-cron-backup:postgres` | `postgres:18` | `pg_dump`、`pg_dumpall` | `pg_dump` custom 格式（`.dump`） |

两个镜像都包含 AWS CLI、gzip、flock 和 BusyBox `crond`，配置方式相同。

## 备份流程

每次任务执行以下流程：

1. 读取数据库列表，排除系统库。
2. 没有业务数据库时记录成功状态并结束任务。
3. PostgreSQL 先导出集群级的角色和表空间定义。
4. 逐个导出数据库到容器临时目录，并校验文件完整性。
5. 上传文件到 S3，并使用 `HeadObject` 核对对象大小。
6. 清理临时文件并记录任务状态。

单个数据库失败后，其余数据库继续执行；存在任何失败时，本次任务最终状态为失败。备份保留周期由存储桶生命周期规则管理。

| | MySQL | PostgreSQL |
| --- | --- | --- |
| 排除的库 | `information_schema`、`mysql`、`performance_schema`、`sys` | `template0`、`template1`、`postgres` |
| 导出内容 | 表、视图、触发器、事件和存储过程 | 数据库内全部对象，含属主和权限 |
| 完整性校验 | `gzip -t` | `pg_restore` 完整读取一遍归档 |
| 集群级对象 | 不导出 | 角色和表空间，不含角色密码 |

通过 `DB_DATABASES` 显式指定时，可以备份 PostgreSQL 的 `postgres` 库。

## 对象结构

```text
[<S3_PREFIX>/]<数据库名>/<YYYYMMDDHHmmss>.sql.gz    # MySQL
[<S3_PREFIX>/]<数据库名>/<YYYYMMDDHHmmss>.dump      # PostgreSQL
[<S3_PREFIX>/]_globals/<YYYYMMDDHHmmss>.sql.gz     # PostgreSQL 角色和表空间
```

当 `S3_PREFIX=db-01` 时：

```text
db-backups/
└── db-01/
    ├── _globals/
    │   └── 20260917030000.sql.gz
    ├── app/
    │   └── 20260917030000.dump
    └── analytics/
        └── 20260917030000.dump
```

`S3_PREFIX` 支持 `production/db-01` 形式的多级前缀。文件名时间使用容器的 `TZ`。名为 `_globals` 的数据库不受支持。

## 部署

运行环境为 Ubuntu 上的 Docker Compose。参考 [compose.example.yml](compose.example.yml)，并确保备份容器可以通过 `DB_HOST` 访问数据库。

启动或更新服务：

```bash
docker compose pull db-backup
docker compose up -d db-backup
```

立即执行一次备份：

```bash
docker compose exec db-backup backup.sh
```

查看日志：

```bash
docker compose logs -f db-backup
```

导出文件上传前存放在容器的 `/tmp`，容器可写层需要能够容纳最大的单个数据库备份文件。

## 恢复

### MySQL

```bash
aws s3 cp s3://<bucket>/<S3_PREFIX>/app/20260917030000.sql.gz - \
  | gzip -dc \
  | mysql -h <host> -u root -p
```

备份包含 `CREATE DATABASE` 和 `USE` 语句，会恢复到同名数据库。

### PostgreSQL

恢复使用的 `pg_restore` 版本不能低于备份时的 `pg_dump` 版本，当前为 18。

新集群先恢复角色。角色密码不在备份中，恢复后需要重新设置：

```bash
aws s3 cp s3://<bucket>/<S3_PREFIX>/_globals/20260917030000.sql.gz - \
  | gzip -dc \
  | psql -h <host> -U postgres -d postgres
psql -h <host> -U postgres -c "ALTER ROLE <角色> PASSWORD '<密码>'"
```

再恢复数据库。`--create` 会按备份中的名称和属主创建数据库，`--jobs` 并行恢复：

```bash
aws s3 cp s3://<bucket>/<S3_PREFIX>/app/20260917030000.dump app.dump
pg_restore -h <host> -U postgres --create --dbname=postgres --jobs=4 app.dump
```

目标集群没有对应角色时，加 `--no-owner --no-acl`，由连接用户持有全部对象。只恢复部分对象时，可以用 `pg_restore --list` 生成清单，编辑后通过 `--use-list` 指定。

## 配置

| 变量 | 必需 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `DB_HOST` | 是 | - | 数据库主机名 |
| `DB_PORT` | 否 | MySQL `3306`，PostgreSQL `5432` | 数据库端口 |
| `DB_USER` | 是 | - | 备份账号 |
| `DB_PASSWORD` | 是 | - | 备份账号密码 |
| `DB_SSL_MODE` | 否 | `preferred` | `disabled`、`preferred`、`required`、`verify-ca` 或 `verify-full` |
| `DB_DATABASES` | 否 | 自动发现 | 逗号分隔的数据库列表 |
| `S3_ENDPOINT` | 否 | AWS S3 | S3 兼容服务地址；设置后使用 path-style 访问 |
| `S3_REGION` | 否 | `us-east-1` | S3 区域 |
| `S3_BUCKET` | 是 | - | 目标存储桶 |
| `S3_PREFIX` | 否 | - | 对象键前缀，例如 `db-01` 或 `production/db-01` |
| `AWS_ACCESS_KEY_ID` | 是 | - | S3 Access Key |
| `AWS_SECRET_ACCESS_KEY` | 是 | - | S3 Secret Key |
| `BACKUP_CRON` | 否 | `0 3 * * *` | 5 段 cron 表达式，按 `TZ` 计算 |
| `TZ` | 否 | `UTC` | 调度和文件名时区 |
| `COMPRESSION_LEVEL` | 否 | `6` | 压缩等级，范围 1-9 |
| `HEALTHCHECK_MAX_AGE_SECONDS` | 否 | `129600` | 最近成功备份的最大允许时间，默认 36 小时 |

数据库类型由镜像 tag 决定。`DB_SSL_MODE` 映射到 MySQL 的 `--ssl-mode`（`verify-full` 对应 `VERIFY_IDENTITY`）和 PostgreSQL 的 `sslmode`。

## 数据库账号

### MySQL

备份账号需要读取业务数据库的表、视图、触发器、事件和存储过程：

```sql
CREATE USER 'backup'@'%' IDENTIFIED BY '<随机密码>';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW_ROUTINE ON *.* TO 'backup'@'%';
```

备份命令使用 `--single-transaction`、`--no-tablespaces` 和 `--set-gtid-purged=OFF`。

### PostgreSQL

PostgreSQL 14 及以上版本使用内置角色 `pg_read_all_data`：

```sql
CREATE ROLE backup LOGIN PASSWORD '<随机密码>';
GRANT pg_read_all_data TO backup;
```

账号需要能连接 `postgres` 库以读取数据库列表，`pg_hba.conf` 需要允许备份容器访问。角色定义使用 `pg_dumpall --globals-only --no-role-passwords` 导出，不需要超级用户。

## S3 权限

备份身份需要以下权限，其中 `<bucket>` 替换为目标存储桶：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ["arn:aws:s3:::<bucket>"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::<bucket>/*"]
    }
  ]
}
```

对象过期由存储桶生命周期规则处理。

## 健康检查

任务状态保存在容器的 `/var/lib/db-backup`：

- 最近一次任务失败时，容器状态为 `unhealthy`。
- 最近一次成功备份超过 `HEALTHCHECK_MAX_AGE_SECONDS` 时，容器状态为 `unhealthy`。
- 后续任务成功后，容器状态恢复为 `healthy`。

容器重建后健康状态重新计时。

## 开发

```text
scripts/
├── backup.sh            # 公共流程：配置校验、锁、列库、上传与校验、状态记录
├── entrypoint.sh        # 写入 crontab 并启动 crond
├── healthcheck.sh
└── engines/
    ├── mysql.sh         # 列库、导出、校验
    └── postgres.sh
```

新增数据库类型时，在 `scripts/engines/` 实现 `engine_require_commands`、`engine_configure`、`engine_is_system_database`、`engine_list_databases` 和 `engine_dump`，并在 `Dockerfile` 中增加同名 target。

## CI

GitHub Actions 执行 ShellCheck、脚本测试、MySQL 8.4 和 PostgreSQL 18 的备份恢复测试以及 `linux/amd64`、`linux/arm64` 镜像构建。`master` 构建成功后，每种数据库发布两个 tag：

```text
ghcr.io/qiujun8023/db-cron-backup:mysql
ghcr.io/qiujun8023/db-cron-backup:mysql-<commit>
ghcr.io/qiujun8023/db-cron-backup:postgres
ghcr.io/qiujun8023/db-cron-backup:postgres-<commit>
```

`<commit>` 为 7 位提交哈希，用于固定版本或回滚。
