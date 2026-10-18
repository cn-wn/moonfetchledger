# 生态对比与实际扩展关系（2026-10-19 复核）

## 定位与重叠项

MoonFetchLedger 的独立贡献限定为：**为已有下载客户端补充可信文件采纳、
磁盘区块回读审计、稀疏检查点恢复及坏块选择性修复。**
普通断点续传、Range 请求、认证、下载进度、缓存重用已经存在于 MoonBit
生态，不能作为本项目独有能力。早期原生 HTTP CLI 保留为可选参考适配器，
它与已有下载器有功能重叠，不作为差异化贡献。不能用新的名称或 CLI 界面
证明差异化；下面的公开接口、实际依赖和可运行集成才是依据。

| 项目 | 已有用途、公开 API 与范围 | 与本项目的关系 |
| --- | --- | --- |
| [q2316367743/webdav](https://github.com/q2316367743/webdav) | WebDAV 上传下载、目录、属性与锁；`get_file(range=...)`、`download_to_path`、`download_to_path_resume`。公开续传实现以本地长度为连续前缀，使用 Range/可选 If-Range，支持 200 全文重写和完成长度检查。 | **已实际接入。** 直接复用原客户端的原始下载、条件区间 GET、路径编码、认证和传输接口，不重写 WebDAV 协议。新增层独立承担回读账本、同长度文件损坏检测、非连续缺口恢复与修复确认。 |
| [QUHONGYE-gif/modelhub](https://github.com/QUHONGYE-gif/moonkit-modelhub) | HuggingFace 仓库/版本解析、下载、认证、缓存布局、离线重用；`download_resumable`、`hf_hub_download`、`snapshot_download`。所查续传路径按 `.incomplete` 文件长度追加。 | **比较参考，未集成。** 不实现其 Hub API、快照/refs/blobs 布局或镜像管理，不宣称兼容其内部缓存。不能因为拥有通用本地文件 API 就声称已经扩展 modelhub。 |
| MoonFetchLedger | `Session.prepare_chunk/commit_written`、`restore/reconcile_block`、`host.adopt/audit/repair_from_local/export_verified`、`host.receive_from`、`webdav.Source.receive`。 | 以可信摘要及先前确认的区块记录为前提，重新核验实际存储，保留有效覆盖，仅修复缺口，并在完成时检查全文件摘要。无需把文件长度当作完整性证据。 |

以上是对所列 API 和实现路径的比较，不能据此断言上游所有包都不存在相近
完整性能力；也不声称本项目提供生态唯一性、性能优势或广泛服务器兼容性。

## 已实现的 WebDAV 组合

`moon.mod` 声明 `q2316367743/webdav@0.1.0` 和
`q2316367743/moonhttp@0.5.0`；共同异步依赖使用 `moonbitlang/async@0.22.4`。
没有复制、分叉或修改上游实现。

1. `examples/webdav` 使用上游 `put_file`、`options`、`download_to_path`
   上传、查询并下载真实 USGS 数据。完整文件通过可信 SHA-256 后由 `host.adopt`
   建立账本；既有任意坏文件不能冒充可信采纳输入。
2. 修改文件中间一个字节而不改变长度；`host.audit` 不联网、不改写内容或
   检查点，报告坏块 `[8192,12288)`，其余 23912 字节仍有效。
3. `webdav.Source` 调用上游 `get_file(range=..., conditions=If-Match)`，
   只获取所需区块。私有响应保护层实现上游开放 `Transport`，实际网络仍委托
   `HttpConnTransport`；在上游缓冲前验证编码/元数据，并限制读取大小。
   这是必要的安全边界，因为 `GetResult` 本身未暴露 Content-Encoding。
4. 区块进入共享的 `host.receive_from`：响应验证、偏移写入、同步回读、确认、
   检查点保存及全文件摘要校验。不是另写一套恢复流程。
5. 演示还验证不支持的编码被拒绝、两个非连续坏块跨暂停/重建 Source 修复、
   验证后导出，以及源站关闭后的零下载重用。

复现：`moon run --target native examples/webdav`。
新增[差异证据](differentiation-proof.md)直接调用上游原版续传 API，复现同长度坏文件
在合法 416 总长响应下返回的连续前缀边界，再以独立可信完整区块参考审计、
重建丢失的本地检查点，保留 23912 字节并仅修复一个坏块。参考元数据必须独立
可信；普通采纳仍拒绝任意坏文件。上游继续承担下载与传输，不替换其实现。
样例服务端仅实现单文件 PUT/GET/OPTIONS，用真实套接字和已发布客户端验证
组合流程；它不是完整 RFC 4918 服务器，未验证特定商业服务器。
[完整契约和边界](webdav.md)，[验证记录](validation.md)。

## 来源快照、许可证与不确定性

2026-10-19 重新查询两个仓库的公开 HEAD，均仍为下列快照；实际依赖版本的
续传源码与公开接口也已复核。此处不把同长度的完成判断推广为上游全部 API
均缺少完整性能力，比较范围限定为明确列出的调用路径和当前组合实现。

- WebDAV 检索快照：
  [43b2ecaf](https://github.com/q2316367743/webdav/tree/43b2ecaf8e0a1bac8676c3d2f0e01e2a43abf5de)
  （公开最新提交时间 2026-10-13）；Apache-2.0。比较依据：
  [续传实现](https://github.com/q2316367743/webdav/blob/43b2ecaf8e0a1bac8676c3d2f0e01e2a43abf5de/src/client/download_resume.mbt)、
  [下载 API](https://github.com/q2316367743/webdav/blob/43b2ecaf8e0a1bac8676c3d2f0e01e2a43abf5de/src/client/pkg.generated.mbti)。
  实际构建使用注册表发布版本 0.1.0，其接口也经本地严格编译和运行确认；
  不把文档中的功能阶段编号当作已发布版本号。
- modelhub 检索快照：
  [ca8e991a](https://github.com/QUHONGYE-gif/moonkit-modelhub/tree/ca8e991a6bc57a44b2ec53c651d0920594b07f20)
  （公开最新提交时间 2026-09-17）；Apache-2.0。比较依据：
  [download_resumable 实现](https://github.com/QUHONGYE-gif/moonkit-modelhub/blob/ca8e991a6bc57a44b2ec53c651d0920594b07f20/modelhub.mbt)、
  [公开 API](https://github.com/QUHONGYE-gif/moonkit-modelhub/blob/ca8e991a6bc57a44b2ec53c651d0920594b07f20/pkg.generated.mbti)。
  `QUHONGYE-gif/modelhub` 是模块名，实际 GitHub 仓库名是 `moonkit-modelhub`。
- 查阅渠道包括 GitHub 源码/生成接口、Mooncakes 注册表（`moon update`、
  `moon tree`）和本地已下载依赖。关键词：`webdav`、`modelhub`、`download`、
  `resume`、`resumable`、`range`、`checkpoint`、`audit`、`integrity`。
- 本次重点复核审核指出的两个项目，不是对全生态的穷尽证明。新增、私有、
  未发布或未被索引的实现以及后续版本变化仍可能影响边界判断。
- 代码、数据和依赖来源见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
  项目属于在已有 MoonBit 客户端上构建的功能扩展，账本逻辑独立实现；
  非 WebDAV/modelhub 的移植或分叉。签名元数据、浏览器存储和 modelhub
  专用适配均未实现，不能作为当前集成成果申报。
