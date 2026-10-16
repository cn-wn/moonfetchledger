**1、项目名称：** MoonFetchLedger——面向现有下载客户端的区块完整性审计与修复层。

**2、项目简介：** 面向 MoonBit 文件分发、数据采集和离线部署开发者，解决文件长度正确但内容受损、非连续区块缺失、检查点与磁盘状态不一致的问题。重新核验实际存储，保留有效区块，仅修复缺口，完成时以可信 SHA-256 校验整文件。

**3、项目方向与通用性：** 开发工具与基础库。可复用账本核心支持 Wasm、Wasm-GC、JavaScript、原生目标；原生适配层提供磁盘工作流及 WebDAV 集成。适用于具备已知长度、强 ETag 和可信摘要的单文件制品；WebDAV 适配保留上游 2147483647 字节限制。

**4、至少三个完整使用场景：**

- **既有 WebDAV 文件修复：** 原客户端下载完整文件→可信摘要校验并建立账本→后续离线审计发现同长度文件中的坏块→通过原客户端区间 API 只重取坏块→整文件验证后导出使用。
- **弱网与非连续缺口恢复：** 应用分块接收并保存确认记录→中断或部分区块损坏→重启回读并保留有效区块→暂停后继续修复剩余缺口→校验完整制品交付业务程序。
- **离线部署：** 源站不可用→审计保留文件→完整校验本地可信备份→只复制缺失或损坏区块并回读确认→校验后导出到新路径，保留原有恢复现场。

**5、核心功能与当前成果：** 已实现稀疏覆盖账本、对象绑定租约、写后回读确认、严格检查点、离线审计、本地采纳/修复、验证后导出、中断检查点恢复，以及已发布 WebDAV 客户端的实际集成。真实 USGS 数据演示验证：28008 字节文件中一个字节损坏，保留 23912 字节并只修复一个区块；另覆盖编码响应拒绝、非连续坏块跨暂停修复和源站关闭后的零下载重用。签名发布元数据及浏览器存储适配属于后续计划。

**6、原创、移植或参考关系：** 在现有 MoonBit 生态项目上构建的功能扩展，账本与修复逻辑独立实现，非 WebDAV 或 modelhub 的移植/分叉。承认断点续传、认证、进度、缓存等已有能力，不作为独有贡献。

**7、上游来源及许可证：** 实际依赖 [q2316367743/webdav](https://github.com/q2316367743/webdav) 与 [moonhttp](https://github.com/q2316367743/moonhttp)（均 Apache-2.0），复用下载、条件区间请求和传输接口，增加完整性与恢复层。[modelhub](https://github.com/QUHONGYE-gif/moonkit-modelhub) 为对比参考，尚未集成。项目采用 Apache-2.0；[详细 API 对比、来源与边界](https://github.com/cn-wn/moonfetchledger/blob/main/docs/ecosystem.md)可核验。

**8、GitHub 仓库与提交：** [cn-wn/moonfetchledger](https://github.com/cn-wn/moonfetchledger)，[提交记录](https://github.com/cn-wn/moonfetchledger/commits/main/)含不少于 10 次实质功能提交，覆盖实现、测试和文档，无空提交或重复提交。复现：`moon update` 后运行 `moon run --target native examples/webdav`；完整验证入口为 `moon run scripts/verify.mbtx`。
