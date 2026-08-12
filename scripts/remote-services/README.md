# 可选后端服务

三个服务都是**可选的**：不部署它们，应用照常运行——分析结果和向量都落在本机文件里，Java 只用本地语法检查与基础补全。部署之后，多台机器上的客户端共用同一份缓存与向量库。

| 服务 | 作用 | 不可用时 |
| --- | --- | --- |
| Redis | 分析结果、提交详情、用量计数的热缓存，Electron 版与原生版共用一份 | 每次调用都有超时上限，失败即熔断，回落到本机文件 |
| PostgreSQL + pgvector | 跨对话检索用的向量库（640 维），多端共享的持久存储 | 暂停该层两分钟，检索退回本机向量缓存 |
| Eclipse JDT LS | Java 补全服务 | 退回本地语法检查与基础补全 |

安全前提：三者都只监听 `127.0.0.1`，客户端一律通过 SSH 本地端口转发访问。**不要在防火墙上放行 6379 / 5432 / 9092。**

## 1. Redis 与 pgvector

需要一台装了 Docker 的 Debian/Ubuntu 服务器：

```bash
scp -r scripts/remote-services ubuntu@example.com:/tmp/leetcode-services
ssh ubuntu@example.com
cd /tmp/leetcode-services

cp .env.example .env
$EDITOR .env          # 填 REDIS_PASSWORD / POSTGRES_USER / POSTGRES_PASSWORD
chmod 600 .env

docker compose up -d
docker compose ps
```

验证：

```bash
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" ping          # PONG
docker compose exec postgres psql -U "$POSTGRES_USER" -d leetcode_rag \
  -c "SELECT extname FROM pg_extension WHERE extname = 'vector';"      # vector
```

在客户端建隧道（保持后台运行）：

```bash
ssh -f -N -L 6379:127.0.0.1:6379 -L 5432:127.0.0.1:5432 ubuntu@example.com
```

然后在应用里打开 **设置 → 数据与缓存**，分别填 Redis 与向量数据库的地址（`127.0.0.1` + 对应端口）、账号与密码，点「测试连接」保存。密码存进系统钥匙串，不写进仓库。

表结构由应用自动创建，`init-pgvector.sql` 只是让首次部署一步到位并附带近邻索引。

## 2. Java 补全服务

见 [`../remote-lsp`](../remote-lsp)：

```bash
scp -r scripts/remote-lsp ubuntu@example.com:/tmp/leetcode-lsp
ssh ubuntu@example.com
cd /tmp/leetcode-lsp
sudo bash install.sh
sudo systemctl status leetcode-lsp
curl http://127.0.0.1:9092/health
```

客户端把连接信息写进仓库根目录的 `.env.local`（不会被 Git 跟踪，也不要把私钥内容写进去）：

```dotenv
LEETCODE_LSP_SSH_HOST=example.com
LEETCODE_LSP_SSH_USER=ubuntu
LEETCODE_LSP_SSH_PORT=22
LEETCODE_LSP_TARGET_PORT=9092
LEETCODE_LSP_SSH_IDENTITY_FILE=/absolute/path/to/ssh_private_key
```

```bash
chmod 600 /absolute/path/to/ssh_private_key
ssh -o BatchMode=yes ubuntu@example.com true
```

## 3. 运维

```bash
docker compose logs -f --tail 100      # 看日志
docker compose pull && docker compose up -d   # 升级镜像
docker compose down                    # 停服务（数据保留在具名卷里）
```

备份向量库：

```bash
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" leetcode_rag | gzip > rag-$(date +%F).sql.gz
```

Redis 里全是可重建的缓存，不需要备份；清空它只会让下一次分析重新算一遍：

```bash
docker compose exec redis redis-cli -a "$REDIS_PASSWORD" --scan --pattern 'lca:*' | \
  xargs -r docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" del
```
