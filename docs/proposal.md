**1、项目名称：** MoonFetchLedger——基于 MoonBit 的通用文件增量更新与完整性恢复库。

**2、项目简介及审核后改进：** 针对上次指出的“局限于单文件损坏修复，缺少跨版本复用、可信元数据分发和完整更新流程”，已新增目标区块索引、滚动/强摘要匹配、签名发布描述、持久化版本接受以及发布到验证交付的实际 CLI 工作流。

**3、方向及通用性：** 基础库与开发工具，服务数据集、模型权重、离线资源包维护者。核心支持 Wasm、Wasm-GC、JavaScript 和原生目标，磁盘及网络工作流使用原生平台。继续复用既有 WebDAV 客户端传输，新增层负责更新决策、内容校验与恢复。

**4、至少三个完整使用场景：**

- **跨版本更新：** 发布者生成目标索引和签名描述→客户端验证发布者、版本与有效期→从旧文件任意偏移复用匹配区块→仅下载缺口→全文校验后导出新版并保留旧版。
- **残缺副本联合交付：** 提供多个不完整旧文件→只读预览联合复用量与缺口→在总扫描/哈希预算内重建→补齐剩余区块→验证并导出完整文件。
- **私有资源恢复：** 认证签名元数据→以绑定目标地址的临时凭据下载→暂停或凭据失效后保留已确认进度→更换凭据后跨进程恢复→验证交付。
- **离线损坏修复：** 文件同长度损坏、检查点丢失→依据独立可信区块参考重建有效覆盖→通过既有客户端或可信本地备份修复坏块→全文验证。

**5、核心成果及计划：** 上述新增能力均已实现，并接通多旧文件、扫描预算与签名更新入口。另提供独立下游模块验证公开 API 接入，提供本地打包/解包后检查入口。自动密钥分发轮换、目录同步、共享区块缓存、原地安装仍未实现；当前不发布到 Mooncakes。

**6、项目性质：** 参考成熟方法、在 MoonBit 生态上独立实现的功能扩展，采用 Apache-2.0；非 WebDAV、modelhub 或 zsync 的移植/分叉。不以普通续传作为独有能力，不宣称生态唯一或性能优势。

**7、参考来源及许可证：** [zsync](https://github.com/cph6/zsync)（Artistic-2.0）提供滚动校验/强摘要匹配思路，未复制实现且不兼容 `.zsync`；实际复用 [webdav](https://github.com/q2316367743/webdav)、[moonhttp](https://github.com/q2316367743/moonhttp)、[mbt-ed25519](https://github.com/hustcer/mbt-ed25519)（均 Apache-2.0）。modelhub 仅作对比，未集成。完整来源见 `THIRD_PARTY_NOTICES.md`。

**8、仓库及验证：** [cn-wn/moonfetchledger](https://github.com/cn-wn/moonfetchledger)，[主分支历史](https://github.com/cn-wn/moonfetchledger/commits/main/)含不少于 10 次实质提交，无空提交或重复凑数。执行 `moon run --deny-warn scripts/verify.mbtx`；[审核意见与可运行证据](https://github.com/cn-wn/moonfetchledger/blob/main/docs/differentiation-proof.md)、[交付检查说明](https://github.com/cn-wn/moonfetchledger/blob/main/docs/acceptance.md)明确当前成果及限制。
