# docker-db-cron-backup

按 cron 定时导出 MySQL 或 PostgreSQL，上传到 AWS S3 或 S3 兼容对象存储，用于灾备恢复。每种数据库一个镜像 tag，支持 `linux/amd64` 和 `linux/arm64`：

| 数据库 | 镜像 | 备份文件 |
| --- | --- | --- |
| MySQL | `ghcr.io/qiujun8023/db-cron-backup:mysql` | `mysqldump` 生成的 SQL，gzip 压缩，`.sql.gz` |
| PostgreSQL | `ghcr.io/qiujun8023/db-cron-backup:postgres` | `pg_dump` custom 格式，`.dump` |

`master` 每次构建还会发布 `:<数据库>-<7 位提交哈希>`，生产环境出问题时用它回退到上一版镜像。

## 部署

参考 [compose.example.yml](compose.example.yml)，备份容器要能通过 `DB_HOST` 访问数据库。切换数据库只需要改镜像 tag 和端口，其余配置写法相同。

```bash
docker compose pull db-backup
docker compose up -d db-backup
docker compose exec db-backup backup.sh    # 立即备份一次
docker compose logs -f db-backup
```

备份先写到容器的 `/tmp`，校验通过后才上传，所以容器可写层要能放下最大的单个库的备份文件。

### 数据库账号

只授予读权限，备份账号泄露时不会影响数据。

MySQL：

```sql
CREATE USER 'backup'@'%' IDENTIFIED BY '<随机密码>';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, SHOW_ROUTINE ON *.* TO 'backup'@'%';
```

PostgreSQL 14 及以上：

```sql
CREATE ROLE backup LOGIN PASSWORD '<随机密码>';
GRANT pg_read_all_data TO backup;
```

PostgreSQL 账号还要能连接 `postgres` 库，用来读取库列表和导出角色定义，`pg_hba.conf` 需要放行备份容器。

### S3 权限

备份身份只能读写对象，不能删除。备份过期交给存储桶生命周期规则处理，这样凭据泄露后也无法删掉已有备份。把 `<bucket>` 替换为目标存储桶：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::<bucket>"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::<bucket>/*"]
    }
  ]
}
```

## 配置

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DB_HOST` | 必填 | 数据库主机名 |
| `DB_PORT` | MySQL `3306`，PostgreSQL `5432` | |
| `DB_USER` | 必填 | |
| `DB_PASSWORD` | 必填 | |
| `DB_SSL_MODE` | `preferred` | `disabled`、`preferred`、`required`、`verify-ca` 或 `verify-full` |
| `DB_DATABASES` | 自动发现 | 逗号分隔的库名，指定后不再自动发现 |
| `S3_ENDPOINT` | AWS S3 | S3 兼容服务地址，设置后使用 path-style 访问 |
| `S3_REGION` | `us-east-1` | |
| `S3_BUCKET` | 必填 | |
| `S3_PREFIX` | 空 | 对象键前缀，可以有多级，如 `production/db-01` |
| `AWS_ACCESS_KEY_ID` | 必填 | |
| `AWS_SECRET_ACCESS_KEY` | 必填 | |
| `BACKUP_CRON` | `0 3 * * *` | 5 段 cron 表达式，按 `TZ` 计算 |
| `TZ` | `UTC` | 调度和文件名使用的时区 |
| `COMPRESSION_LEVEL` | `6` | 压缩等级 1-9 |
| `HEALTHCHECK_MAX_AGE_SECONDS` | `129600` | 距上次成功备份超过这个时长，容器变为 unhealthy，默认 36 小时 |

## 备份内容

自动发现时跳过系统库：MySQL 跳过 `information_schema`、`mysql`、`performance_schema` 和 `sys`，PostgreSQL 跳过 `template0`、`template1` 和 `postgres`。PostgreSQL 的 `postgres` 库通常是空的，如果里面有业务数据，要用 `DB_DATABASES` 显式列出。没有业务库时任务按成功结束，空节点也能保持 healthy。

| | MySQL | PostgreSQL |
| --- | --- | --- |
| 每个库 | 表、视图、触发器、事件和存储过程 | 库内全部对象，包括属主和权限 |
| 集群级 | 不导出 | 角色和表空间定义，不含角色密码 |
| 上传前校验 | `gzip -t` | 用 `pg_restore` 完整读一遍归档 |

PostgreSQL 的角色定义存在集群级别，单库备份里没有。恢复到新集群时如果缺少角色，对象属主无法还原，所以额外导出角色定义。导出时加了 `--no-role-passwords`，这样不需要超级用户权限。

每个文件上传后都会用 `HeadObject` 核对大小。单个库失败不影响其他库继续备份，但这次任务会记为失败。

对象键按库分目录，时间使用 `TZ`：

```text
<S3_PREFIX>/
├── _globals/20260917030000.sql.gz    # 仅 PostgreSQL
├── app/20260917030000.dump
└── analytics/20260917030000.dump
```

`_globals` 目录专门存放角色定义，所以名为 `_globals` 的库会被拒绝备份。

## 恢复

### MySQL

备份里带有 `CREATE DATABASE` 和 `USE` 语句，会恢复到同名库：

```bash
aws s3 cp s3://<bucket>/<prefix>/app/20260917030000.sql.gz - | gzip -dc | mysql -h <host> -u root -p
```

### PostgreSQL

`pg_restore` 的主版本不能低于备份时的 `pg_dump`，否则无法读取归档。镜像里 `pg_dump` 的版本可以这样查：

```bash
docker run --rm --entrypoint pg_dump ghcr.io/qiujun8023/db-cron-backup:postgres --version
```

恢复到新集群时，先恢复角色，再重新设置密码：

```bash
aws s3 cp s3://<bucket>/<prefix>/_globals/20260917030000.sql.gz - | gzip -dc | psql -h <host> -U postgres -d postgres
psql -h <host> -U postgres -c "ALTER ROLE <角色> PASSWORD '<密码>'"
```

然后恢复数据库。`--create` 会按备份里的库名和属主建库，`--jobs` 指定并行数。并行恢复需要读本地文件，所以先下载：

```bash
aws s3 cp s3://<bucket>/<prefix>/app/20260917030000.dump app.dump
pg_restore -h <host> -U postgres --create --dbname=postgres --jobs=4 app.dump
```

如果目标集群里没有对应的角色，加上 `--no-owner --no-acl`，所有对象都归连接用户。只想恢复部分对象时，先用 `pg_restore --list app.dump > list` 导出清单，编辑后通过 `--use-list list` 指定。

## 健康检查

容器的 healthcheck 读取 `/var/lib/db-backup` 下的任务状态。以下任一情况会变为 unhealthy：

- 最近一次任务失败。
- 距上次成功备份已超过 `HEALTHCHECK_MAX_AGE_SECONDS`。

之后有一次任务成功，就会恢复 healthy。状态文件不持久化，容器重建后重新计时。
