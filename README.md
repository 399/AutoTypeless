# AutoTypeless

AutoTypeless 是一个 macOS 账号切换工具，用于管理本人已登录的多个 Typeless 账号。

它不会保存账号密码，而是保存 Typeless 已登录状态的本地会话快照。切换账号时，AutoTypeless 会退出 Typeless、恢复目标账号的会话文件、重新启动 Typeless，并在失败时尝试回滚。

## 功能

- 保存和管理多个已登录账号
- 添加、更新、重命名、删除及重新识别账号
- 从主窗口或状态栏直接切换账号
- 切换失败时恢复原会话
- 可选关闭窗口后常驻状态栏
- 默认关闭窗口即退出
- 不包含会员额度查询功能

## 系统要求

- macOS 13 或更高版本
- 已安装 Typeless
- Swift 6（从源码构建时）

## 从源码构建

```bash
swift test --disable-sandbox
swift build -c release --disable-sandbox
zsh scripts/package-dmg.sh
```

生成的安装包位于 `dist/` 目录。

## 使用说明

1. 先在 Typeless 中登录一个账号。
2. 打开 AutoTypeless，添加当前账号。
3. 在 Typeless 中退出并登录另一个账号，再次添加。
4. 以后可在 AutoTypeless 主窗口或状态栏中切换。

切换期间请不要手动启动或操作 Typeless，以免会话文件发生冲突。

## 数据与隐私

AutoTypeless 会在本机读取并复制 Typeless 的以下会话文件：

- `user-data.json`
- `app-storage.json`

账号快照和恢复点仅保存在当前用户的本地应用支持目录中，不会提交到本仓库，也不会由本项目上传到远程服务。项目不会保存账号密码。

建议在公开分发前自行审阅源码，并妥善保护本机账号快照。不要把真实会话文件、测试用户目录、Cookie、Token 或数据库提交到 Git。

## 免责声明

AutoTypeless 是独立的非官方工具，与 Typeless 官方无隶属或合作关系。请仅用于管理本人拥有和有权使用的账号，并自行承担使用及账号数据备份责任。

## 版本

当前稳定版：0.8.5（Build 23）
