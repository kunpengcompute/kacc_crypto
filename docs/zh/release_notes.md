# 版本说明书

## 版本配套说明

### 产品版本信息

<a name="table62675726"></a>

<table><tbody><tr id="row41561572"><th class="firstcol" valign="top" width="42.17%" id="mcps1.1.3.1.1"><p id="p11044137"><a name="p11044137"></a><a name="p11044137"></a>产品名称</p>
</th>
<td class="cellrowborder" valign="top" width="57.830000000000005%" headers="mcps1.1.3.1.1 "><p id="p1597721693713"><a name="p1597721693713"></a><a name="p1597721693713"></a>Kunpeng BoostKit</p>
</td>
</tr>
<tr id="row24726251"><th class="firstcol" valign="top" width="42.17%" id="mcps1.1.3.2.1"><p id="p56669300"><a name="p56669300"></a><a name="p56669300"></a>产品版本</p>
</th>
<td class="cellrowborder" valign="top" width="57.830000000000005%" headers="mcps1.1.3.2.1 "><p id="p11923034"><a name="p11923034"></a><a name="p11923034"></a><span id="text14311218114"><a name="text14311218114"></a><a name="text14311218114"></a>26.2.RC1</span></p>
</td>
</tr>
<tr id="row1930811171892"><th class="firstcol" valign="top" width="42.17%" id="mcps1.1.3.3.1"><p id="p2030912172097"><a name="p2030912172097"></a><a name="p2030912172097"></a>软件名称</p>
</th>
<td class="cellrowborder" valign="top" width="57.830000000000005%" headers="mcps1.1.3.3.1 "><p id="p1730912179911"><a name="p1730912179911"></a><a name="p1730912179911"></a><span id="text17191017111119"><a name="text17191017111119"></a><a name="text17191017111119"></a>KACC_Crypto</span></p>
</td>
</tr>
<tr id="row19308111718"><th class="firstcol" valign="top" width="42.17%" id="mcps1.1.3.3.1"><p id="p2030912172097"><a name="p2030912172097"></a><a name="p2030912172097"></a>软件版本</p>
</th>
<td class="cellrowborder" valign="top" width="57.830000000000005%" headers="mcps1.1.3.3.1 "><p id="p1730912179911"><a name="p1730912179911"></a><a name="p1730912179911"></a><span id="text17191017111119"><a name="text17191017111119"></a><a name="text17191017111119"></a>dev</span></p>
</td>
</tr>
</tbody>
</table>

### 硬件版本配套说明

| 项目 | 说明 |
| --- | --- |
| 服务器和处理器 | 鲲鹏950处理器 |
| 架构 | AArch64 |
| 加速能力 | SVE2 AES、SVE2、PMULL、ARMv8 AES |
| 外部加速设备 | 无外部加速卡要求 |

### 与操作系统配套说明

| 软件版本 | 操作系统 | 依赖版本 |
| --- | --- | --- |
| `dev` | AArch64 Linux | OpenSSL 3.0.16源码树、GCC/Clang、make、perl |

> ![icon note](public_sys-resources/icon-note.gif) **说明：**
>
>- 具体可用范围以接入脚本能否匹配目标OpenSSL源码锚点、以及目标机器是否支持对应指令能力为准。
>- 未列入本表的OpenSSL版本和操作系统需要单独验证。

## 版本使用注意事项

- AES-XTS当前热路径按SVE vector length为256bit的机器调优，非256bit VL机器需要单独验证。
- AES-GCM只在8192B及以上大窗口进入SVE2路径，小包按设计保留ARMv8/NEON路径。
- AES-GCM provider上下文中会缓存`pairtab[1024]`，用于降低大块请求中的GHASH预计算重复开销。
- RSA当前以独立benchmark方式验证RSA2048/RSA4096 private CRT数学运算，不是OpenSSL对外RSA API的透明分发。
- 接入脚本通过源码锚点修改OpenSSL文件，目标OpenSSL版本差异较大时可能需要调整锚点。

## dev

### 更新说明

**新增特性**

| 模块 | 更新说明 |
| --- | --- |
| AES-XTS | 新增AArch64 SVE2 AES-XTS stream实现，覆盖AES-128/192/256 XTS加解密。 |
| AES-GCM | 新增SVE2 AES-CTR + GHASH大窗口融合计算路径，支持AES-128/192/256 GCM加解密。 |
| RSA | 新增SVE2 x8 Montgomery multiply、square、gather kernel，并提供RSA2048/RSA4096 benchmark。 |

**修改特性**

| 模块 | 更新说明 |
| --- | --- |
| AES-GCM | SVE2 GCM API改为消费预计算`pairtab`，并在provider context中管理缓存生命周期。 |
| AES-GCM | 增加AES-128/AES-256 decrypt 16KB级预取kernel选择。 |
| RSA | RSA benchmark主体参数化，支持RSA2048和RSA4096两种key size。 |
| RSA | `apply_and_test_rsa.sh`增加`RSA_BENCH_BITS=2048\|4096`参数。 |
| RSA | `apply_and_test_rsa.sh`增加`RSA_BENCH_LINK=auto\|static\|shared`和 `OPENSSL_LIB`，支持链接OpenSSL动态库。 |

**删除特性**

无。

### 已解决的问题

无。

### 遗留问题

| 问题编号 | 问题描述 | 影响范围 | 规避措施 |
| --- | --- | --- | --- |
| NA-001 | AES-XTS热路径不是通用可变VL实现。 | 非256bit SVE VL机器。 | 非验证环境保持原生路径或补充VL专用实现。 |
| NA-002 | RSA目前通过独立benchmark验证。 | 应用通过OpenSSL RSA API调用的场景。 | 后续增加OpenSSL内部分发或批处理接口后再作为透明优化启用。 |
| NA-003 | 接入脚本依赖OpenSSL源码锚点。 | 与验证版本差异较大的OpenSSL源码树。 | 使用匹配版本或按脚本报错锚点手动适配。 |

## 版本配套文档

### dev版本配套文档

| 文档名称 | 说明 |
| --- | --- |
| 《快速入门》 | 快速完成源码获取、OpenSSL构建、优化代码接入和基础验证。 |
| 《安装指南》 | 描述环境要求、AES-XTS、AES-GCM和RSA优化算法的接入步骤、编译步骤和测试步骤。 |
| 《用户指南》 | 描述AES-XTS、AES-GCM和RSA优化的使用入口、参数和验证方法。 |
| 《版本说明书》 | 描述KACC_Crypto版本配套、能力范围、注意事项和遗留问题。 |

### 获取文档的方法

您可以通过访问[开源仓](https://gitcode.com/boostkit/kacc_crypto)浏览和获取相关文档。
