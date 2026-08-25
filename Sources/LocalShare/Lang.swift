import Foundation

// i18n 核心：把所有用户可见文案做成「编进二进制的 Swift 字符串表」，不依赖任何资源 bundle
// （戒律的精神见 CLAUDE.md / docs/ARCHITECTURE.md §0）——与 MarkedJS.source、permSummary 同一思路，三条启动
// 路径（headless / CLI / GUI）都无须定位文件。当前支持 简体中文(zh) + English(en)。
//
// 两个解析域彼此独立：
//   · 原生 app —— 语言来自设置（跟随系统 / 中文 / English），见 AppState.lang / Lang.current；
//   · 网页 —— 逐请求由浏览器的 Accept-Language 头决定，见 FileServer.handle，绝不读 app 设置。
//
// 文案分两类：静态文案走 `L`（枚举键 + switch 返回 (zh, en)，编译器保证穷尽、无强解包）；
// 带插值/复数的走 `LStr`（按 lang 分支返回拼好的串，中英语序/复数各表各的）；
// 网页里由 JS 在浏览器侧拼接的文案走 `Lang.i18nJSON`（注入一个带 {占位符} 的字典，JS 只做 replace）。

enum Lang: String {
    case zh   // 简体中文（基准语言）
    case en   // English

    // 用于 HTML 的 <html lang="…">。
    var htmlLang: String { self == .zh ? "zh-Hans" : "en" }

    // 当前原生界面语言的便捷快照：供拿不到 AppState 的菜单/命令构造处（App.swift / Updater.swift）读取。
    // 权威来源仍是 AppState.langPref；由 AppState.init 与 setLangPref 同步更新。菜单无须会话中途
    // 响应式重建（macOS 懒重建即可），故一个静态快照足矣。
    @MainActor static var current: Lang = .zh

    // 把持久化偏好解析成具体语言：.system 时看系统首选语言。
    static func resolve(_ pref: LangPref) -> Lang {
        switch pref {
        case .zh: return .zh
        case .en: return .en
        case .system: return systemDefault
        }
    }

    // 跟随系统：取首个以 zh / en 开头的首选语言；都没有则回基准 zh。
    static var systemDefault: Lang {
        for tag in Locale.preferredLanguages {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh") { return .zh }
            if lower.hasPrefix("en") { return .en }
        }
        return .zh
    }

    // 逐请求语言：解析 "zh-CN,zh;q=0.9,en;q=0.8"——按 q 值（缺省 1.0）降序、同 q 保留出现顺序，
    // 取首个映射到 zh / en 的；头缺失或无可识别项 → 基准 zh。
    static func fromAcceptLanguage(_ header: String?) -> Lang {
        guard let header, !header.isEmpty else { return .zh }
        var best: Lang? = nil
        var bestQ = -1.0
        for part in header.split(separator: ",") {
            let segs = part.split(separator: ";")
            guard let first = segs.first else { continue }
            let tag = first.trimmingCharacters(in: .whitespaces).lowercased()
            let lang: Lang? = tag.hasPrefix("zh") ? .zh : (tag.hasPrefix("en") ? .en : nil)
            guard let lang else { continue }
            var q = 1.0
            for s in segs.dropFirst() {
                let kv = s.trimmingCharacters(in: .whitespaces)
                if kv.hasPrefix("q=") { q = Double(kv.dropFirst(2)) ?? 1.0 }
            }
            guard q > 0 else { continue }   // q=0 即「明确不接受该语言」（RFC 9110），跳过
            if q > bestQ { bestQ = q; best = lang }   // 严格大于：同 q 保留先出现者
        }
        return best ?? .zh
    }
}

// 原生 app 的持久化语言偏好（含「跟随系统」）。对应设置页 3 个分段，照搬 AppState.AppearancePref。
enum LangPref: String { case system, zh, en }

// MARK: - 静态文案表

// 每个键经 switch 返回 (zh, en)：编译器强制穷尽、无 Optional、无强解包；新增文案即加一个 case。
// 调用点写作 `L.settings(lang)`（callAsFunction）。
enum L: CaseIterable {
    // 通用动作 / 标签
    case settings, back, refresh, stop, clear, rebroadcast, replace, replaceFile
    case discardChanges, applyRestart, resetDefault, reshare, viewAll, clearAll
    case cancel, clearAllConfirm
    case install, reinstall, uninstall, installed, alwaysOn

    // 空状态 / 拖拽
    case dropToShare, dropHint, dropZoneTitle, dropZoneSub, pickAnyButton

    // 分享屏
    case shareFileTitle   // 文件票据二级页标题（与「传递文本」并列）
    case received, changePerm, broadcastStopped, selectSource
    case sharingKicker, sharingFolderKicker
    case scanCaptionMultiple, scanCaptionFile, scanCaptionFolder
    case revealShareItems, revealInFinder, viewing

    // 未接入网络
    case noNetwork, noNetworkHint

    // 设置 —— 小节标题
    case sectionNetwork, sectionPermission, sectionAppearance, sectionLanguage, sectionMain
    case sectionUpdate, sectionCLI, sectionRecent
    case shareSettings, shareHistory, currentColon

    // 设置 —— 网络
    case thisMachine, portOk, portOccupied, portInvalid, portOkHint
    case bindOnlyTitle, bindOnlyDescMulti, bindOnlyDescSingle

    // 设置 —— 端口校验（静态部分；被占用一项带数字走 LStr）
    case portEmptyMsg, portNotNumberMsg, portTooLowMsg, portTooHighMsg

    // 设置 —— 访问权限
    case permReadName, permReadDesc, permUploadName
    case permUploadDescOn, permUploadDescOff
    case accessCodeTitle, accessCodeDesc, accessCodeLabel
    case permInfoWritable, permInfoReadonly, plaintextWarning

    // 设置 —— 外观
    case appearanceFollow, appearanceLight, appearanceDark

    // 设置 —— 语言
    case langFollow

    // 设置 —— 主界面
    case showRecentsTitle, showRecentsDesc, resetWindowTitle, resetWindowDesc

    // 设置 —— 更新
    case autoUpdate, autoUpdateDescOn, autoUpdateDescOff
    case manualUpdate, manualUpdateDescOn, manualUpdateDescOff

    // 设置 —— 命令行工具
    case cliHintAvailable, cliHintUnavailable

    // 历史
    case noHistory, live

    // 帮助
    case cantConnect, cantConnectTitle, help1, help2, help3, helpPlaintext

    // 菜单（App.swift / Updater.swift）
    case showLocalShare, quit, checkForUpdates

    // 组件 help / 标签
    case clearShareHelp, idle, copy, openInBrowser
    case revealFileHelp, openFolderHelp, copyPathHelp, expandWide, exitWide, expandAddress, collapseAddress

    // 文件选择面板
    case pickFolderMsg, pickFileMsg, pickAnyMsg, sharePrompt

    // 单文件存根「其他」类回退名
    case fileKind

    // 传递文本（v1）
    case shareTextButton, textEditorPlaceholder, textShareAction, textUpdateAction
    case sharingTextKicker, scanCaptionText, editTextButton
    // 传递文本二级页（收/发合一）
    case transferText, sendTextKicker, scanCaptionTransfer, textIdleHint, retract
    case rememberTextTitle, rememberTextDesc, deleteEntry

    // 传递文本（v2·手机→Mac 收文本）
    case recvInboxTitle, recvInboxDesc, persistRecvTitle, persistRecvDesc
    case receivedTextsTitle, inboxWaiting
    case scanCaptionSend, clearReceivedConfirm, copyTextAction

    // —— 网页（由 Swift 直接拼进 HTML 的静态文案）——
    case webUpload, webDropHere, webBackToParent, webEmptyFolder
    case webNoMatch, webNoMatchSub, webSearchFolder, webClear
    case webSortLabel, webSortDefault, webSortNameAsc, webSortNameDesc
    case webSortTimeDesc, webSortTimeAsc
    case webFilterAll, webFilterDir, webProvidedBy
    case webViewRaw, webLoading, webSearchJSON, webFilterRows
    case webText, webTextHint, webCopy, webViewRawText
    case webSendTitle, webSendEyebrow, webSendSub, webSendHead, webSendPlaceholder, webSendButton
    case webAccessCodeTitle, webAccessCodeEyebrow, webAccessCodeSub
    case webAccessCodePlaceholder, webAccessCodeSubmit, webAccessCodeInvalid, webAccessCodeLimited

    // —— 网页错误页 / 上传 JSON ——
    case webForbiddenTitle, webForbiddenBody, webFileNotFound, webReadFailed
    case upDisabled, upOverLimit, upPathDenied, upDirMissing, upWriteFailed, upNoFiles
    case recvDisabled, recvOverLimit, recvEmpty

    // —— CLI / headless 终端诊断（按系统语言，见 Lang.systemDefault）——
    case cliPortRange, cliHeadlessNeedsPath, cliPortHeadlessOnly, cliAppNotFound
    case hsEnvMissing, hsNoLan, hsScanHint

    // —— 权限派生（permSummary，原生 + 网页共用）——
    case permWritable, permReadonly
    case eyebrowWritable, eyebrowReadonly
    case chipDownloadable, chipReadonly, chipCanUpload, chipCanEdit, chipCanDelete, chipCanReceiveText
    case permWriteUpload, permWriteEdit, permWriteDelete

    func callAsFunction(_ lang: Lang) -> String {
        let p = pair
        return lang == .zh ? p.0 : p.1
    }

    private var pair: (String, String) {
        switch self {
        case .settings:        return ("设置", "Settings")
        case .back:            return ("返回", "Back")
        case .refresh:         return ("刷新网络", "Refresh")
        case .stop:            return ("停止", "Stop")
        case .clear:           return ("清除", "Clear")
        case .rebroadcast:     return ("重新广播", "Restart")
        case .replace:         return ("更换", "Replace")
        case .replaceFile:     return ("更换文件", "Replace File")
        case .discardChanges:  return ("放弃修改", "Discard")
        case .applyRestart:    return ("应用并重启", "Apply & Restart")
        case .resetDefault:    return ("恢复默认", "Reset")
        case .reshare:         return ("重新分享", "Reshare")
        case .viewAll:         return ("查看全部", "View All")
        case .clearAll:        return ("清空", "Clear")
        case .cancel:          return ("取消", "Cancel")
        case .clearAllConfirm: return ("清空全部分享历史？", "Clear all share history?")
        case .install:         return ("安装", "Install")
        case .reinstall:       return ("重新安装", "Reinstall")
        case .uninstall:       return ("卸载", "Uninstall")
        case .installed:       return ("已安装", "Installed")
        case .alwaysOn:        return ("始终开启", "Always on")

        case .dropToShare:     return ("松开即可分享", "Release to share")
        case .dropHint:        return ("文件夹 / 多项 → 列表浏览 · 单个文件 → 扫码直接打开",
                                       "Folder / multiple → browse list · single file → open directly")
        case .dropZoneTitle:   return ("拖拽文件或文件夹到这里", "Drag files or folders here")
        case .dropZoneSub:     return ("同一 Wi-Fi 下的设备即可扫码访问", "Devices on the same Wi-Fi can scan to access")
        case .pickAnyButton:   return ("选择文件或文件夹", "Choose Files or Folders")

        case .shareFileTitle:  return ("分享文件", "Share Files")
        case .received:        return ("新收到", "Received")
        case .changePerm:      return ("改权限 ›", "Permissions ›")
        case .broadcastStopped: return ("已停止广播", "Broadcast stopped")
        case .selectSource:    return ("选择信号源", "Choose source")
        case .sharingKicker:       return ("正在分享", "Sharing")
        case .sharingFolderKicker: return ("正在分享文件夹", "Sharing folder")
        case .scanCaptionMultiple: return ("扫码浏览已选项目 · 同一 Wi-Fi", "Scan to browse selected items · same Wi-Fi")
        case .scanCaptionFile:     return ("扫码查看 · 同一 Wi-Fi", "Scan to view · same Wi-Fi")
        case .scanCaptionFolder:   return ("扫码浏览全部文件 · 同一 Wi-Fi", "Scan to browse all files · same Wi-Fi")
        case .revealShareItems: return ("在 Finder 中显示分享项", "Show shared items in Finder")
        case .revealInFinder:  return ("在 Finder 中显示", "Show in Finder")
        case .viewing:         return ("正在浏览", "Viewing")

        case .noNetwork:       return ("未接入局域网", "Not on a network")
        case .noNetworkHint:   return ("先把这台 Mac 接入与目标设备相同的\nWi-Fi / 有线网络，再点下方刷新。",
                                       "Connect this Mac to the same Wi-Fi /\nwired network as the target device, then refresh.")

        case .sectionNetwork:    return ("网络", "Network")
        case .sectionPermission: return ("访问权限", "Access")
        case .sectionAppearance: return ("外观", "Appearance")
        case .sectionLanguage:   return ("语言", "Language")
        case .sectionMain:       return ("主界面", "Main Screen")
        case .sectionUpdate:     return ("更新", "Updates")
        case .sectionCLI:        return ("命令行工具", "Command Line")
        case .sectionRecent:     return ("最近分享", "Recent")
        case .shareSettings:     return ("分享设置", "Settings")
        case .shareHistory:      return ("分享历史", "History")
        case .currentColon:      return ("当前：", "Current: ")

        case .thisMachine:     return ("本机", "Local")
        case .portOk:          return ("可用", "Available")
        case .portOccupied:    return ("被占用", "In use")
        case .portInvalid:     return ("无效", "Invalid")
        case .portOkHint:      return ("端口可用 · 修改后会重启服务，已分发的链接需更新。",
                                       "Port available · changing it restarts the server; shared links must be updated.")
        case .bindOnlyTitle:   return ("仅当前网络可见", "Current network only")
        case .bindOnlyDescMulti:  return ("只在选中的信号源上开放，电脑连着的其它网络访问不到",
                                          "Open only on the selected source; other connected networks can't reach it")
        case .bindOnlyDescSingle: return ("只在当前网络开放，日后接入别的网络时也访问不到",
                                          "Open only on the current network; future networks won't reach it either")

        case .portEmptyMsg:     return ("请输入端口号", "Enter a port number")
        case .portNotNumberMsg: return ("端口需为数字", "Port must be a number")
        case .portTooLowMsg:    return ("需 ≥ 1024 · 1023 以下为系统保留端口", "Must be ≥ 1024 · ports below 1024 are reserved")
        case .portTooHighMsg:   return ("超出范围 · 端口最大为 65535", "Out of range · max port is 65535")

        case .permReadName:    return ("读取与下载", "Read & Download")
        case .permReadDesc:    return ("允许查看和下载文件", "Allow viewing and downloading files")
        case .permUploadName:  return ("允许上传", "Allow Upload")
        case .permUploadDescOn:  return ("访客可把文件传进这个文件夹", "Visitors can upload files into this folder")
        case .permUploadDescOff: return ("仅分享单个文件夹时可用", "Only available when sharing a single folder")
        case .accessCodeTitle: return ("使用访问码", "Use Access Code")
        case .accessCodeDesc: return ("在另一台电脑输入网址和短码；二维码仍可直接打开",
                                      "Enter an address and short code on another computer; QR links still open directly")
        case .accessCodeLabel: return ("访问码", "Access code")
        case .permInfoWritable:  return ("已开启上传 · 访客可向这个文件夹写入文件，请只把二维码交给信任的人。",
                                         "Upload on · visitors can write to this folder. Only share the QR code with people you trust.")
        case .permInfoReadonly:  return ("当前为只读分享 · 访客只能查看和下载。",
                                         "Read-only share · visitors can only view and download.")
        case .plaintextWarning:  return ("同一网络下传输不加密 · 公共 Wi-Fi（咖啡馆 / 机场等）下同网的人可能看到内容，敏感文件别在这种网络分享。",
                                         "Traffic isn't encrypted on the LAN · on public Wi-Fi (cafés, airports) others on the network may see the content. Don't share sensitive files there.")

        case .appearanceFollow: return ("跟随系统", "System")
        case .appearanceLight:  return ("浅色", "Light")
        case .appearanceDark:   return ("深色", "Dark")

        case .langFollow:       return ("跟随系统", "System")

        case .showRecentsTitle: return ("展示最近分享", "Show Recent Shares")
        case .showRecentsDesc:  return ("关闭后主界面不再列出最近分享", "When off, the main screen won't list recent shares")
        case .resetWindowTitle: return ("恢复默认窗口尺寸", "Reset Window Size")
        case .resetWindowDesc:  return ("把窗口还原成默认大小", "Restore the window to its default size")

        case .autoUpdate:        return ("自动更新", "Automatic Updates")
        case .autoUpdateDescOn:  return ("关闭后不自动检查、不弹提示；仍可手动检查",
                                         "When off, no automatic checks or prompts; manual checks still work")
        case .autoUpdateDescOff: return ("开发构建未启用更新，正式版生效", "Updates are disabled in dev builds; active in release")
        case .manualUpdate:      return ("手动检查更新", "Manual Update Check")
        case .manualUpdateDescOn: return ("立刻检查是否有新版，有更新时按提示安装",
                                          "Check for a new version now and install when prompted")
        case .manualUpdateDescOff: return ("开发构建未启用更新，正式版可手动检查",
                                           "Updates are disabled in dev builds; active in release")

        case .cliHintAvailable:   return ("在终端用 localshare 分享文件", "Use localshare in the terminal to share files")
        case .cliHintUnavailable: return ("以 app 包运行时可安装", "Installable when run as an app bundle")

        case .noHistory:       return ("暂无分享历史", "No share history yet")
        case .live:            return ("进行中", "Live")

        case .cantConnect:      return ("连不上?", "Can't connect?")
        case .cantConnectTitle: return ("连不上？逐条排查", "Can't connect? Check these")
        case .help1:           return ("确认两台设备连的是同一个 Wi-Fi / 网络。", "Make sure both devices are on the same Wi-Fi / network.")
        case .help2:           return ("首次启动若弹出防火墙提示，请点「允许」。", "If a firewall prompt appears on first launch, click Allow.")
        case .help3:           return ("公司 / 公共 Wi-Fi 常开「设备隔离」，会阻止互访，换个网络试试。",
                                       "Corporate / public Wi-Fi often isolates devices, blocking access. Try another network.")
        case .helpPlaintext:   return ("传输不加密：公共 Wi-Fi 下同网的人可能看到内容，敏感文件别在这种网络分享。",
                                       "Traffic isn't encrypted: on public Wi-Fi others may see the content. Don't share sensitive files there.")

        case .showLocalShare:  return ("显示 LocalShare", "Show LocalShare")
        case .quit:            return ("退出", "Quit")
        case .checkForUpdates: return ("检查更新…", "Check for Updates…")

        case .clearShareHelp:  return ("清除当前分享 · 回到初始", "Clear the current share · back to start")
        case .idle:            return ("待命", "Idle")
        case .copy:            return ("复制", "Copy")
        case .openInBrowser:   return ("在浏览器打开", "Open in browser")
        case .revealFileHelp:  return ("在 Finder 中显示该文件", "Show this file in Finder")
        case .openFolderHelp:  return ("在 Finder 中打开该文件夹", "Open this folder in Finder")
        case .copyPathHelp:    return ("拷贝完整路径", "Copy full path")
        case .expandWide:      return ("切换到宽屏", "Use wide layout")
        case .exitWide:        return ("退出宽屏", "Exit wide layout")
        case .expandAddress:   return ("展开完整地址", "Show full address")
        case .collapseAddress: return ("收起地址", "Collapse address")

        case .pickFolderMsg:   return ("选择要广播到局域网的文件夹", "Choose a folder to broadcast on the LAN")
        case .pickFileMsg:     return ("选择要单独分享的文件（扫码直接打开它）", "Choose a single file to share (scan opens it directly)")
        case .pickAnyMsg:      return ("选择文件或文件夹，可多选", "Choose files or folders (multiple allowed)")
        case .sharePrompt:     return ("分享", "Share")

        case .fileKind:        return ("文件", "File")

        case .shareTextButton:      return ("分享文本", "Share Text")   // 空态入口 + 编辑弹层标题共用
        case .textEditorPlaceholder: return ("在此粘贴或输入要分享的文本", "Paste or type the text to share")
        case .textShareAction:      return ("分享", "Share")
        case .textUpdateAction:     return ("更新", "Update")
        case .sharingTextKicker:    return ("正在分享文本", "Sharing text")
        case .scanCaptionText:      return ("扫码查看文本 · 同一 Wi-Fi", "Scan to view text · same Wi-Fi")
        case .editTextButton:       return ("编辑文本", "Edit Text")
        case .transferText:         return ("传递文本", "Transfer Text")
        case .sendTextKicker:       return ("发送文本", "Send text")
        case .scanCaptionTransfer:  return ("扫码读取或发送文本 · 同一 Wi-Fi", "Scan to read or send text · same Wi-Fi")
        case .textIdleHint:         return ("发送一段文本，或开启接收，扫码即可",
                                           "Send some text or turn on receiving, then scan")
        case .retract:              return ("撤回", "Retract")
        case .rememberTextTitle:    return ("记住分享的文本", "Remember Shared Text")
        case .rememberTextDesc:     return ("重启后回填上次内容供再次分享；关闭则退出即忘",
                                           "Refills the last text after restart for reuse; off forgets it on quit")
        case .deleteEntry:          return ("删除", "Delete")

        case .recvInboxTitle:       return ("允许收文本", "Allow Receiving Text")
        case .recvInboxDesc:        return ("对方扫码后可把一段文本发到这台 Mac", "After scanning, the other device can send text to this Mac")
        case .persistRecvTitle:     return ("记住收到的文本", "Remember Received Text")
        case .persistRecvDesc:      return ("重启后保留收件箱内容；关闭则退出即忘",
                                           "Keeps the inbox after restart; off forgets it on quit")
        case .receivedTextsTitle:   return ("收到的文本", "Received Text")
        case .inboxWaiting:         return ("等待对方发来文本…", "Waiting for text from the other device…")
        case .scanCaptionSend:      return ("扫码把文本发到这台 Mac · 同一 Wi-Fi", "Scan to send text to this Mac · same Wi-Fi")
        case .clearReceivedConfirm: return ("清空收到的全部文本？", "Clear all received text?")
        case .copyTextAction:       return ("复制", "Copy")

        case .webUpload:       return ("上传", "Upload")
        case .webDropHere:     return ("松手上传到这里", "Drop here to upload")
        case .webBackToParent: return ("返回上一级", "Up one level")
        case .webEmptyFolder:  return ("这个文件夹是空的", "This folder is empty")
        case .webNoMatch:      return ("未找到匹配的文件", "No matching files")
        case .webNoMatchSub:   return ("试试其他关键词", "Try a different keyword")
        case .webSearchFolder: return ("搜索此文件夹…", "Search this folder…")
        case .webClear:        return ("清除", "Clear")
        case .webSortLabel:    return ("排序", "Sort")
        case .webSortDefault:  return ("默认顺序", "Default order")
        case .webSortNameAsc:  return ("名称 · A → Z", "Name · A → Z")
        case .webSortNameDesc: return ("名称 · Z → A", "Name · Z → A")
        case .webSortTimeDesc: return ("时间 · 新 → 旧", "Date · New → Old")
        case .webSortTimeAsc:  return ("时间 · 旧 → 新", "Date · Old → New")
        case .webFilterAll:    return ("全部", "All")
        case .webFilterDir:    return ("目录", "Folders")
        case .webProvidedBy:   return ("由 <b>LocalShare</b> 提供", "Served by <b>LocalShare</b>")
        case .webViewRaw:      return ("查看原文", "View source")
        case .webLoading:      return ("正在加载…", "Loading…")
        case .webSearchJSON:   return ("搜索键或值…", "Search keys or values…")
        case .webFilterRows:   return ("筛选行…", "Filter rows…")
        case .webText:         return ("文本", "Text")
        case .webTextHint:     return ("分享者发来的一段文本", "A snippet shared from the host")
        case .webCopy:         return ("复制", "Copy")
        case .webViewRawText:  return ("查看原始文本", "View raw text")
        case .webSendTitle:    return ("发送文本到电脑", "Send Text to Computer")
        case .webSendEyebrow:  return ("局域网 · 发送到电脑", "LAN · send to computer")
        case .webSendSub:      return ("输入文本，点发送即可投递到这台 Mac。", "Type some text and send it to this Mac.")
        case .webSendHead:     return ("发文本给电脑", "Send text to the computer")
        case .webSendPlaceholder: return ("在此输入要发送到电脑的文本…", "Type text to send to the computer…")
        case .webSendButton:   return ("发送", "Send")
        case .webAccessCodeTitle: return ("输入访问码", "Enter Access Code")
        case .webAccessCodeEyebrow: return ("LocalShare · 电脑访问", "LocalShare · computer access")
        case .webAccessCodeSub: return ("输入分享者电脑上显示的短码。", "Enter the short code shown on the sharing computer.")
        case .webAccessCodePlaceholder: return ("例如 K7M-PQ2", "For example K7M-PQ2")
        case .webAccessCodeSubmit: return ("进入分享", "Open Share")
        case .webAccessCodeInvalid: return ("访问码不正确，请重新输入。", "That access code is incorrect. Try again.")
        case .webAccessCodeLimited: return ("尝试次数过多，请稍后再试。", "Too many attempts. Try again later.")

        case .webForbiddenTitle: return ("无法访问", "No access")
        case .webForbiddenBody:  return ("请通过电脑上显示的二维码扫码进入。", "Scan the QR code shown on the computer to enter.")
        case .webFileNotFound:   return ("文件不存在", "File not found")
        case .webReadFailed:     return ("读取失败", "Read failed")
        case .upDisabled:        return ("上传未开启", "Upload not enabled")
        case .upOverLimit:       return ("超过 500MB 上限", "Exceeds 500 MB limit")
        case .upPathDenied:      return ("路径不允许", "Path not allowed")
        case .upDirMissing:      return ("目录不存在", "Directory not found")
        case .upWriteFailed:     return ("写入失败", "Write failed")
        case .upNoFiles:         return ("没有可保存的文件", "No files to save")
        case .recvDisabled:      return ("收文本未开启", "Receiving text not enabled")
        case .recvOverLimit:     return ("超过 64KB 上限", "Exceeds 64 KB limit")
        case .recvEmpty:         return ("文本为空", "Text is empty")

        case .cliPortRange:         return ("--port 需要 1–65535 的端口号", "--port requires a port number 1–65535")
        case .cliHeadlessNeedsPath: return ("--headless 需要至少一个文件或文件夹路径", "--headless requires at least one file or folder path")
        case .cliPortHeadlessOnly:  return ("--port 仅在 --headless 模式下有效", "--port is only valid in --headless mode")
        case .cliAppNotFound:       return ("未找到 LocalShare.app，请先把它放进「应用程序」文件夹。",
                                            "LocalShare.app not found. Put it in the Applications folder first.")
        case .hsEnvMissing:         return ("LS_FOLDER / LS_FOLDERS 未设置", "LS_FOLDER / LS_FOLDERS not set")
        case .hsNoLan:              return ("未发现局域网地址，其它设备可能无法访问，请确认已连接 WiFi。",
                                            "No LAN address found; other devices may be unable to connect. Make sure WiFi is connected.")
        case .hsScanHint:           return ("同一 WiFi 下扫码访问 · 按 Ctrl-C 停止分享",
                                            "Scan to access on the same WiFi · press Ctrl-C to stop")

        case .permWritable:      return ("可读写", "Read-write")
        case .permReadonly:      return ("只读", "Read-only")
        case .eyebrowWritable:   return ("局域网 · 可读写分享", "LAN · read-write share")
        case .eyebrowReadonly:   return ("局域网 · 只读分享", "LAN · read-only share")
        case .chipDownloadable:  return ("可下载", "Downloadable")
        case .chipReadonly:      return ("只读", "Read-only")
        case .chipCanUpload:     return ("可上传", "Can upload")
        case .chipCanEdit:       return ("可编辑", "Can edit")
        case .chipCanDelete:     return ("可删除", "Can delete")
        case .chipCanReceiveText: return ("可收文本", "Can receive text")
        case .permWriteUpload:   return ("上传", "Upload")
        case .permWriteEdit:     return ("编辑", "Edit")
        case .permWriteDelete:   return ("删除", "Delete")
        }
    }
}

// MARK: - 带插值 / 复数的文案

// 语序、复数、数字位置中英各异，故不入 key→value 表，由函数按 lang 拼装。
enum LStr {
    // "3 项" / "3 items"（目录元信息、计数、describeShared 共用）
    static func itemCount(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "\(n) 项" : "\(n) item\(n == 1 ? "" : "s")"
    }

    // "5 个文件" / "5 files"
    static func fileCount(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "\(n) 个文件" : "\(n) file\(n == 1 ? "" : "s")"
    }

    // "2 个文件夹" / "2 folders"
    static func folderCount(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "\(n) 个文件夹" : "\(n) folder\(n == 1 ? "" : "s")"
    }

    // 历史多选记录名："3 个项目" / "3 items"
    static func multiItemName(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "\(n) 个项目" : "\(n) item\(n == 1 ? "" : "s")"
    }

    // 文本字数（文本历史条目的副标识）："128 字" / "128 chars"
    static func charCount(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "\(n) 字" : "\(n) char\(n == 1 ? "" : "s")"
    }

    // 收件箱已收条数（收文本 ticket 副标识 / 卡片计数）："已收到 3 条" / "3 received"
    static func receivedCount(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "已收到 \(n) 条" : "\(n) received"
    }

    // 收件箱未读角标："2 条新" / "2 new"
    static func unreadCount(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "\(n) 条新" : "\(n) new"
    }

    // 在线访客明细右栏的人数："3 人" / "3 people"
    static func viewerCountLabel(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "\(n) 人" : "\(n) \(n == 1 ? "person" : "people")"
    }

    // 在线访客摘要：反查到设备名才领衔具名，否则统一计数。
    static func viewerSummary(name: String?, count n: Int, _ lang: Lang) -> String {
        if let name, !name.isEmpty {
            if lang == .zh {
                return n <= 1 ? "\(name) 正在浏览" : "\(name) 等 \(n) 人正在浏览"
            } else {
                return n <= 1 ? "\(name) is viewing" : "\(name) and \(n - 1) other\(n - 1 == 1 ? "" : "s") viewing"
            }
        }
        return lang == .zh ? "\(n) 人正在浏览" : "\(n) viewing"
    }

    // 「开始浏览」至今的粗粒度时长。
    static func elapsed(_ since: Date, _ lang: Lang) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return lang == .zh ? "刚刚" : "just now" }
        if s < 3600 { let m = s / 60; return lang == .zh ? "\(m) 分钟前" : "\(m) min ago" }
        if s < 86400 { let h = s / 3600; return lang == .zh ? "\(h) 小时前" : "\(h) hr ago" }
        let d = s / 86400; return lang == .zh ? "\(d) 天前" : "\(d) day\(d == 1 ? "" : "s") ago"
    }

    // 友好日期：今天/昨天 + 时刻，更早给月日。
    static func friendlyDate(_ date: Date, _ lang: Lang) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if lang == .zh {
            if cal.isDateInToday(date) { f.dateFormat = "今天 HH:mm" }
            else if cal.isDateInYesterday(date) { f.dateFormat = "昨天 HH:mm" }
            else { f.dateFormat = "M月d日" }
        } else {
            f.locale = Locale(identifier: "en_US")
            if cal.isDateInToday(date) { f.dateFormat = "'Today' HH:mm" }
            else if cal.isDateInYesterday(date) { f.dateFormat = "'Yesterday' HH:mm" }
            else { f.dateFormat = "MMM d" }
        }
        return f.string(from: date)
    }

    // 端口建议按钮："改用 :8000" / "Use :8000"
    static func changeToPort(_ p: in_port_t, _ lang: Lang) -> String {
        lang == .zh ? "改用 :\(p)" : "Use :\(p)"
    }

    // 端口被占用："端口 8000 已被其他程序占用" / "Port 8000 is in use by another program"
    static func portOccupied(_ v: String, _ lang: Lang) -> String {
        lang == .zh ? "端口 \(v) 已被其他程序占用" : "Port \(v) is in use by another program"
    }

    // 启动失败："启动服务失败：<原因>" / "Failed to start server: <reason>"
    static func startFailed(_ reason: String, _ lang: Lang) -> String {
        lang == .zh ? "启动服务失败：\(reason)" : "Failed to start server: \(reason)"
    }

    // 网卡不可用回退提示。
    static func ifaceUnavailable(_ lang: Lang) -> String {
        lang == .zh ? "选定网卡暂不可用，已临时对全部网络开放。"
                    : "The selected interface is unavailable; temporarily opened to all networks."
    }

    // 端口占用自动回退："端口 9000 不可用，已自动改用 8000。"
    static func portFallback(requested: in_port_t, actual: in_port_t, _ lang: Lang) -> String {
        lang == .zh ? "端口 \(requested) 不可用，已自动改用 \(actual)。"
                    : "Port \(requested) is unavailable; switched to \(actual)."
    }

    // 分享文件全失效。
    static func shareGone(_ lang: Lang) -> String {
        lang == .zh ? "该分享的文件已不存在，已从历史移除。"
                    : "The shared files no longer exist; removed from history."
    }

    // 部分项缺失："有 2 项已不存在，已自动跳过。"
    static func someItemsGone(_ n: Int, _ lang: Lang) -> String {
        lang == .zh ? "有 \(n) 项已不存在，已自动跳过。"
                    : "\(n) item\(n == 1 ? "" : "s") no longer exist and were skipped."
    }

    // 命令行工具安装/卸载失败。
    static func cliTaskFailed(install: Bool, reason: String, _ lang: Lang) -> String {
        if lang == .zh {
            return "\(install ? "安装" : "卸载")命令行工具失败：\(reason)"
        }
        return "Failed to \(install ? "install" : "uninstall") the command-line tool: \(reason)"
    }

    // MARK: CLI / headless 终端诊断（带插值）

    static func cliUnknownOption(_ opt: String, _ lang: Lang) -> String {
        lang == .zh ? "未知选项 \(opt)" : "Unknown option \(opt)"
    }

    static func cliLaunchFailed(_ reason: String, _ lang: Lang) -> String {
        lang == .zh ? "唤起 LocalShare 失败：\(reason)" : "Failed to launch LocalShare: \(reason)"
    }

    static func cliPathMissing(_ path: String, _ lang: Lang) -> String {
        lang == .zh ? "路径不存在：\(path)" : "Path not found: \(path)"
    }

    static func hsStartFailed(_ reason: String, _ lang: Lang) -> String {
        lang == .zh ? "启动失败: \(reason)" : "Failed to start: \(reason)"
    }

    // 非法监听地址（LS_BIND 误用兜底；GUI 地址恒来自 getifaddrs，不会触发）。
    static func invalidBindAddress(_ addr: String, _ lang: Lang) -> String {
        lang == .zh ? "非法监听地址：\(addr)" : "Invalid listen address: \(addr)"
    }

    // `localshare --help` 用法文本。
    static func cliUsage(_ lang: Lang) -> String {
        if lang == .zh {
            return """
            用法：localshare [选项] <路径> …

              localshare a.html b.pdf       在 LocalShare 窗口里分享这些文件
              localshare --headless ./dir   不开窗口，在终端打印链接和二维码

            选项：
              --headless     前台运行，不打开窗口（Ctrl-C 停止）
              --port <端口>  headless 模式的监听端口（默认 8080，占用时自动回退）
              --version      打印版本号
              -h, --help     打印本帮助
            """
        }
        return """
        Usage: localshare [options] <path> …

          localshare a.html b.pdf       share these files in the LocalShare window
          localshare --headless ./dir   no window; print the link and QR code in the terminal

        Options:
          --headless     run in the foreground without a window (Ctrl-C to stop)
          --port <port>  listening port for headless mode (default 8080, auto-falls back if taken)
          --version      print the version
          -h, --help     print this help
        """
    }

    // MARK: 网页 JS 字典

    // 注入页面的 LS_I18N：JS 在浏览器侧按计数拼接的文案，带 {占位符}，JS 只做 replace，语序逻辑留在此。
    // 两个生成页（DirectoryListing / PreviewPage）都 emit `<script>var LS_I18N=…</script>`。
    static func i18nJSON(_ lang: Lang) -> String {
        let entries: [(String, String, String)] = [
            // 列表页
            ("viewersN",     "{n} 人正在浏览",            "{n} viewing"),
            ("countItems",   "{n} 项",                   "{n} items"),
            ("countFiltered","{shown} / {total} 项",      "{shown} / {total} items"),
            ("sort",         "排序",                     "Sort"),
            ("upOverLimit",  "{name} · 超过 500MB 上限",  "{name} · over 500 MB limit"),
            ("upFailed",     "{name} · 上传失败",         "{name} · upload failed"),
            // 预览壳 / 各 viewer
            ("viewRaw",      "查看原文",                 "View source"),
            ("loadFailed",   "加载失败",                 "Load failed"),
            // 文本页复制按钮（按钮「复制」初始文案由服务端 L.webCopy 渲染、JS 捕获后复原，故此处只需「已复制」）
            ("copied",       "已复制",                   "Copied"),
            // 发文本给电脑（v2 手机端表单）
            ("sent",         "已发送",                   "Sent"),
            ("sendFailed",   "发送失败",                 "Send failed"),
            ("sendOverLimit","超过 64KB 上限",            "over 64 KB limit"),
            ("sendStale",    "链接已失效，请重新扫码",     "Link expired — rescan the QR code"),
            ("sendNetwork",  "网络错误，请重试",          "Network error — try again"),
            ("sentHistory",  "已发送",                   "Sent"),
            ("clearHistory", "清空",                     "Clear"),
            ("parseFailed",  "解析失败",                 "Parse failed"),
            ("parsing",      "正在解析…",                "Parsing…"),
            // JSON viewer
            ("jsonArray",    "数组 · {n} 项",             "Array · {n} items"),
            ("jsonObject",   "对象 · {n} 键",             "Object · {n} keys"),
            ("typeString",   "字符串",                   "string"),
            ("typeNumber",   "数字",                     "number"),
            ("typeBool",     "布尔",                     "boolean"),
            ("jsonChars",    "… ({n} 字符)",              "… ({n} chars)"),
            ("expandFull",   "点击展开全文",             "Click to expand"),
            ("moreItems",    "再显示 {n} 项（剩 {r}）",    "Show {n} more ({r} left)"),
            ("jsonMatches",  "{n} 处匹配",                "{n} matches"),
            ("noMatch",      "未找到匹配",               "No matches"),
            // CSV viewer
            ("csvRowsCols",  "{rows} 行 × {cols} 列",      "{rows} rows × {cols} cols"),
            ("rowsZero",     "0 行",                     "0 rows"),
            ("moreRows",     "再显示 {n} 行（剩 {r}）",    "Show {n} more rows ({r} left)"),
            ("noRows",       "未找到匹配的行",           "No matching rows"),
            ("noDataRows",   "这个文件没有数据行",        "This file has no data rows"),
            ("emptyFile",    "这个文件是空的",           "This file is empty"),
        ]
        let parts = entries.map { k, zh, en in
            "\"\(k)\":\"\(jsEscape(lang == .zh ? zh : en))\""
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    // 把任意字符串转义成可安全内联进 <script> 的 JS 字符串内容（不含外层引号）。i18nJSON 与 TextViewer
    // 共用这一份——「挡 </script> 截断」是安全关键逻辑，不能两处各写一份漂移。转义：\ " < （< 挡 </script>）、
    // 换行/回车/行分隔符 U+2028/U+2029（裸现于 JS 串里会破坏语法）、其余控制符走 \uXXXX。逐 unicode 标量遍历，
    // \ 天然先于后续引入的转义序列处理，无链式 replace 的二次反斜杠化问题。
    static func jsEscape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "<": out += "\\u003c"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out
    }
}
