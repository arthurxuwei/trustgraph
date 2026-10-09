# TrustGraph 2.7.5 → 2.10.10 上线步骤（含 UI 0.3.11 → 2.2.5）

目标主机：`i-wz93dhbsy21ndlm4v0nf`（10.10.1.193），compose 目录 `/root/tg/bundle`。
没有 SSH，所有脚本都在本机用 `rc.sh` 通过云助手送过去执行：

```bash
cd /Users/freedom/aml/trustgraph-2.10/ops/upgrade-2.10.10
bash rc.sh i-wz93dhbsy21ndlm4v0nf 01-prep.sh 3600
```

**每一步都由人在 Claude Code 里用 `!` 前缀执行**（例如 `! bash rc.sh ...`）。auto mode 不允许 Claude 直接操作生产，Claude 只负责解读输出、决定能不能进入下一步。

只有第 3 步会停机，约 5 分钟。本次不准备回滚。

## 这次换了什么

| 服务 | 之前 | 之后 |
|---|---|---|
| 所有 flow 镜像服务（control、api-gateway、ingest、rag、triples、vector-store、rows、embeddings、text-completion） | `trustgraph-flow:2.7.5`，control 用 `2.7.5-oss` | 统一用 `trustgraph-flow:2.10.10-oss`（宿主机本地构建） |
| document-decoder | `trustgraph-unstructured:2.7.5` + `universal-decoder` | `trustgraph-docling:2.10.10` + `docling-decoder`，资源限额 2 核 / 4G |
| trustgraph-ui | `trustgraph-ui:0.3.11` | `trustgraph-ui:2.2.5`（官方镜像，fork 的提交上游已合并） |
| cassandra / pulsar / bookie / zookeeper / qdrant | 不动 | 不动 |

overlay 镜像在官方 2.10.10 上叠了三个补丁（fork 分支 `upgrade/v2.10.10-oss`）：

1. librarian 支持阿里云 OSS：生产 9/24 已切到 OSS，没有它 librarian 起不来。
2. chunk 实体写 `tg:chunkCount`：chunker 跑在 ingest 里，所以 ingest 也必须换成这个镜像。2.7.5 时期 ingest 一直用的官方镜像，这个补丁从未生效过。
3. 网关恢复 `{"error": ...}` 统一错误格式：2.10 的 flow、iam、config、prompt、text-completion 等接口出错时会返回 200 和空的 `{}`。AML 的 `assertFlow`、上游自己的登录接口都靠这个字段判断失败。

端口不变：gateway 原来就显式写了 `--port 8088`（2.10 默认改成了 8888，这里不受影响），UI 仍是 8888。AML 后端、MCP server 的配置都不用改。

## 已排查、不需要处理的

- **keyspace 改名（#1053）**：生产所有 keyspace 都是合法标识符，改名规则对它们没有影响。
- **启动参数**：gateway、processor-group 的生产参数已用 2.10 的解析器逐个验证通过。所有 processor 类在 2.10 都还在。
- **REST 接口**：除了错误格式（已打补丁），其他改动都是新增可选字段。
- **Pulsar**：topic、订阅名、参数都没变，积压的消息不会丢。
- **监控指标改名**：grafana、prometheus 已于 9 月移除，不受影响。

## 步骤

### 第 1 步：准备（不停机）`01-prep.sh`，超时给 3600

宿主机访问不了 Docker Hub。公共镜像站也走不通：daocloud 不在白名单里，直接拒绝 `trustgraph/*`；hub.rat.dev 会一直卡住。所以分两段：

1. **在本机把镜像中转到 ACR**（实例 `aml`，命名空间 `aml`），本机能通过代理访问 Docker Hub：
   ```bash
   brew install crane
   R=$(aliyun cr GetAuthorizationToken --region cn-shenzhen --InstanceId cri-cd8eod8vqw45uiis)
   echo "$R" | jq -r .AuthorizationToken | crane auth login aml-registry.cn-shenzhen.cr.aliyuncs.com \
     -u "$(echo "$R" | jq -r .TempUsername)" --password-stdin
   for i in trustgraph-flow:2.10.10 trustgraph-docling:2.10.10 trustgraph-ui:2.2.5; do
     crane copy --platform linux/amd64 docker.io/trustgraph/$i aml-registry.cn-shenzhen.cr.aliyuncs.com/aml/$i
   done
   ```
   本机上传速度大约 0.4MB/s，docling 镜像压缩后有 1.3G，要几十分钟。
2. **宿主机从 ACR 内网拉取**：ACR 不允许匿名拉取，要先生成一个临时令牌（1 小时有效），在脚本开头 `export ACR_USER`、`ACR_TOKEN`，再送过去执行。脚本拉完会自动登出，凭据不会留在宿主机上。拉完镜像后，从 GitHub codeload 按固定 commit 下载源码，构建 `trustgraph-flow:2.10.10-oss`，pip 走阿里云镜像源。codeload 和 PyPI 镜像源 10-09 实测都能访问。

- 磁盘当前剩 27G，这一步预计占用 6~7G。
- 构建最后会自检：overlay 的文件和基础镜像目录结构对不上就直接报错。

### 第 2 步：改配置（不停机）`02-config.sh`

改动前先把 compose 文件和 launch 目录备份为 `*.bak-pre-2.10-<时间>`。只改文件，不重启。

- compose 中所有 flow 镜像换成 overlay；decoder 换成 docling；UI 换成 2.2.5。
- override 里追加 document-decoder 的资源限额。
- **launch.yaml 补上 concurrency**：2.10 每个 processor 只有一个工作池，所有 flow、所有工作区共用，默认只有 1 个 worker。2.7.5 是每个 flow 各有一个消费者，生产有十几个工作区。不补的话，triples 查询、向量查询、写入都会退化成串行。补的值见脚本，已经写过的值不覆盖。
- launch.yaml 是用 `yaml.safe_dump` 整份重写的，**手写注释会丢失**，key 的引号风格也会变，但内容等价。原文件在 `launch.bak-pre-2.10-<时间>.tgz` 里。
- 最后打印 diff，并用 `docker compose config -q` 校验。**先看一眼 diff 再进入第 3 步。**

### 第 3 步：切换（停机约 5 分钟）`03-cutover.sh`，超时给 900

尽量挑低峰时段。切换期间 AML 的知识库同步和图谱查询会报 TG 不可用，恢复后会自动重试。

1. 停掉所有 TG 应用服务，有状态的服务保持运行。
2. **删除并重建 rows 表**：2.10 的 rows 主键多了 `row_id`（#1055），旧表无法 ALTER，写入会直接报错。10-09 探查时 17 个 keyspace 的 rows 表全是空的。脚本删除前会逐个复查，发现有数据就中止。
3. 先启动 control：2.10 的 processor 启动时都要调用 config-svc 新增的 `getkeys-all-ws`，所以 control 必须先起来。
4. 再启动其余服务。

### 第 4 步：验证 `04-verify.sh`（只读，可以反复跑）

脚本检查这些项目，全部通过才算完成：

- [ ] 所有 `bundle-*` 容器 running，镜像是新的，`restarts` 不再增长
- [ ] 各容器近 10 分钟没有持续出现的 Traceback（刚启动时偶尔的连接重试可以忽略）
- [ ] `ReceiverPool started with N workers` 里的 N 与 launch.yaml 一致，不是 1
- [ ] 用错误密码登录返回 **401** 和 `{"error": "auth failure"}`（返回 200 说明 gateway 没用上 overlay）
- [ ] UI 的 8888 端口返回 200
- [ ] docling-decoder 已经启动，没有报错
- [ ] rag、ingest 日志里没有提示词模板找不到或加载失败的报错

然后在 AML 侧手工验证：

- [ ] **上传**：在测试空间（如 kaujtest）上传一个 docx 和一个带文字层的 PDF，文档状态走到完成，`docker logs bundle-document-decoder-1` 里能看到 docling 处理记录
- [ ] **OCR 路径**：再传一个带图片区域的 PDF（比如带印章或照片页的），decoder 不能崩。docling 对所有 PDF 都开着 OCR，模型应该已经预装在镜像里，这一步用来确认运行时不会再去外网下载
- [ ] **大文件回读**：打开一份 5MB 以上的已有材料，确认 OSS 读取正常
- [ ] **抽取**：新材料的知识图谱抽取完成，实体中心能看到图谱
- [ ] **chunkCount**：在该空间跑 SPARQL `SELECT ?c ?n WHERE { GRAPH <urn:graph:source> { ?c <https://trustgraph.ai/ns/chunkCount> ?n } } LIMIT 5`，应该有结果（只有新入库的文档才有）
- [ ] **新建空间**：在 AML 新建一个工作区，本体发布、flow 创建成功（这一步走 `assertFlow` 的错误判断）
- [ ] **问答**：law、fiat、web3 各问一个已知问题，CaseGraph 和 `/agent` 都要能答；fiat、web3 的 MCP 工具能调通
- [ ] **TG UI**（tg.hkaml.xyz）：能登录，Explorer 能加载，flow 下拉框有选项（0.3.11 的下拉框永远是空的）
- [ ] 观察 SLS 里 aml-backend 30 分钟，没有新增的 `KG_TRUSTGRAPH_*` 错误

### 第 5 步：清理 `05-cleanup.sh`

AML 侧验证都通过后，删掉 2.7.5 的旧镜像和镜像站的别名 tag（unstructured 一个就 7.8G）。只按名字删镜像，不碰数据卷。

## 未核实的风险

- **2.10 是否调用了生产配置里没有的提示词模板**：现有空间的模板是 2.7.5 时期写入的，TemplateSeed 和 WorkspaceInit 只补缺失的键、不覆盖已有的。如果 2.10 的 graph-rag、agent 或抽取用到了新的模板 id，会在第一次调用时报错。核对代码的那一步没能完成，靠第 4 步的问答、抽取验证和日志检查来兜底。

## 升级后行为上的变化（已知，接受）

- **graph-rag 查询范围（#1159）**：不传 `graph` 时，从只查默认图变成查所有图，`urn:graph:source` 里的溯源边也可能进入候选。问答质量要在第 4 步的问答检查里留意。
- **字面量宾语索引（#1041）**：只对新写入的数据生效。老数据按字面量宾语查（比如 SPARQL 里 `?s ?p "某值"`）仍然查不到，需要重新抽取才能补上。
- **向量按属性过滤（#1136）**：新写入的点才带 `doc_id`、`rdf_type`。老数据在按属性过滤的查询里会被漏掉，不带过滤的查询不受影响。
- **docling 的 `--languages` 参数**：代码里实际没有接到 OCR 上。扫描件仍按现有流程，先在本地 OCR 再上传。
- **prompt 模板（#1092）**：改为加载全部 `template.*` 键，`template-index` 不再使用。10-09 抽查了 add、coconut_test、codex_law_*、default、ff、fiat 这几个空间，都是同一套标准模板，没有残留的旧模板。如果升级后某个空间的 prompt 服务报配置加载失败，先查这个空间的 `template.*` 里有没有坏掉的 JSON。
