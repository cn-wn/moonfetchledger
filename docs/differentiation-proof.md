# 可复现的差异：丢失检查点后的坏块恢复

MoonFetchLedger 为已有下载客户端补充独立可信的区块基准、实际存储审计和
稀疏恢复。目标用户是维护数据集、离线资源包等版本化文件的 MoonBit 应用：
文件曾经下载完成，后来出现同长度损坏，同时本地进度元数据已经丢失。

## 真实上游调用与新增能力

运行：

    moon run --target native examples/webdav

该演示实际使用已发布的 q2316367743/webdav 0.1.0、套接字和公开 USGS 数据，
没有替换上游下载实现。所有结果都有代码断言，CI 会运行整条流程。

| 步骤 | 验证的行为 |
| --- | --- |
| 原客户端下载 | put_file / download_to_path 完成 28008 字节上传和原始下载；全文 GET 次数为 1。 |
| 模拟损坏与元数据丢失 | 删除演示目录里的本地 .mfl；修改偏移 16387 的一个字节，长度保持 28008。发布方参考独立保留。 |
| 调用原版续传 API | download_to_path_resume 发出 bytes=28008- 与 If-Range；合法的 416 / bytes */28008 响应使其按总长成功返回，但文件仍然损坏。 |
| 普通文件采纳 | host.adopt 因全文件摘要不符拒绝；不会凭长度把坏文件标为可信。 |
| 独立区块审计 | audit_with_reference 根据经过独立摘要认证的完整区块参考，发现唯一坏块 [16384,20480)，确认其余 23912 字节；不创建本地检查点。 |
| 新建恢复账本 | adopt_with_reference 回读相同区块，只把实际匹配的块写入新检查点；内容文件和发布方参考字节不变，网络请求计数不增加。 |
| 委托原客户端修复 | 既有 webdav.Source.receive 调用上游 get_file，仅获取该 4096 字节坏块；保留 23912 字节，并通过全文件摘要校验。全文 GET 次数仍为 1。 |
| 关闭源站 | 再次打开完整会话无需请求；现有暂停、编码拒绝、非连续缺口和导出验证也继续通过。 |

终端会打印 upstream boundary 和 difference proof 两条证据日志，并断言额外
修复范围只有 [16384,20480)。这展示了按长度续传之外增加的完整性语义。
原版续传的行为符合其连续前缀契约；这里比较的是公开 API 边界。

## 新增公开 API 与可信输入

BlockReference / StorageIndexer.block_reference 在全文件校验后发布完整 MFL1
区块记录；BlockReference.from_bytes 先核验独立字节摘要，再严格解析并检查
记录完整性。每个恢复会话重新检查实际存储。host.write_block_reference /
load_block_reference 提供有字节上限的原生文件工作流；audit_with_reference
只读巡检；adopt_with_reference 新建稀疏检查点。普通 host.adopt 契约保持不变。

参考的摘要必须经独立可信渠道取得。不能给任意本地坏检查点现场算个摘要，
就称它可信；只有全文件摘要也不能推导出每块正确摘要。没有可信区块参考时，
项目仍然拒绝把任意坏文件采纳成可信覆盖。既有检查点、未知临时文件和额外
文件内容一律保留并拒绝覆盖、截断。完整覆盖仍须通过全文件摘要。

## 对比依据与限制

- [上游续传源码快照](https://github.com/q2316367743/webdav/blob/43b2ecaf8e0a1bac8676c3d2f0e01e2a43abf5de/src/client/download_resume.mbt)
  明确包含按本地长度追加、200 重写以及 416 总长相等时返回的路径。
- [上游公开 API](https://github.com/q2316367743/webdav/blob/43b2ecaf8e0a1bac8676c3d2f0e01e2a43abf5de/src/client/pkg.generated.mbti)
  与实际依赖 0.1.0 的本地接口一起复核。下载、认证、进度和 Range 请求继续
  复用上游；这些共有能力不作为独有贡献。
- [生态对比](ecosystem.md) 记录 modelhub 的范围与未集成事实。2026-10-19
  复核两仓库公开 HEAD，仍为此前记录的快照；这不构成全生态功能缺失证明。
- 演示只覆盖有限的 PUT/GET/OPTIONS 测试端点；没有商业服务器兼容性、性能
  优势、签名体系或生态唯一性的声明。参考签名和浏览器存储适配仍属规划。
- [区块参考契约](block-reference.md)、[WebDAV 边界](webdav.md)、
  [验证记录](validation.md) 与生成接口是具体能力的核验入口。
