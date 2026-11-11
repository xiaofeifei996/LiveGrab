# LiveGrab

iOS 直播（HLS / m3u8）录制工具，未签名 IPA 由 GitHub Actions 构建。

## 功能

- 输入赛事页面链接，内置 WKWebView 跑页面 JS 自动解析出 `.m3u8` 流地址
- 也可直接粘贴 m3u8 直链
- 循环拉取切片并按序写入单个 `.ts`（不转码，画质无损）
- 支持设定录制时长上限、后台录制
- 录完可播放 / 转 MP4 / 存相册，文件同时出现在「文件」App 里

## 构建

推送到 `main` 或手动触发 `Build LiveGrab IPA`，产物在 Actions artifact 中（未签名，需自签后安装）。
